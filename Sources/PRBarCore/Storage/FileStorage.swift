import Foundation

/// A directory of small files keyed by string, for caches that can be
/// rebuilt from GitHub: parsed diffs, CI log tails. Each entry is its own
/// file written atomically, so concurrent readers never see half of one,
/// and expiry is a sweep over modification dates.
struct FileCache: Sendable {
    let directory: URL

    func read(_ key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func write(_ key: String, _ data: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: key), options: .atomic)
        } catch {
            PRBarLog.triage.error("cache write failed \(self.directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Remove entries last written before `cutoff`.
    func prune(olderThan cutoff: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let file = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            if let modified, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Keys are PR node ids, SHAs and job ids joined with `@`; anything
    /// outside a conservative set is replaced so a key can't escape the
    /// directory or collide with a hidden file.
    func url(for key: String) -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_@.")
        var name = String(key.map { allowed.contains($0) ? $0 : "_" })
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return directory.appendingPathComponent(name)
    }
}

/// One Codable value in one JSON file, replaced atomically on every save.
/// For state small enough to rewrite whole: the per-PR review states, the
/// last inbox snapshot.
///
/// `fallback` supplies the value while the file doesn't exist yet. The app
/// uses it to read what the SwiftData store held before state moved to
/// files; the first save then writes the file and the fallback is never
/// consulted again.
struct JSONStateFile<Value: Codable & Sendable>: Sendable {
    let url: URL
    let fallback: (@Sendable () -> Value?)?

    init(url: URL, fallback: (@Sendable () -> Value?)? = nil) {
        self.url = url
        self.fallback = fallback
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return fallback?() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            PRBarLog.triage.error("state write failed \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The per-PR review states the worker keeps across relaunches:
/// `<state>/review-state.json`.
struct ReviewStateFile: ReviewStateCaching {
    let file: JSONStateFile<[String: ReviewState]>

    init(stateDirectory: URL, fallback: (@Sendable () -> [String: ReviewState]?)? = nil) {
        file = JSONStateFile(url: stateDirectory.appendingPathComponent("review-state.json"), fallback: fallback)
    }

    func load() -> [String: ReviewState] { file.load() ?? [:] }
    func save(_ states: [String: ReviewState]) { file.save(states) }
}

/// `$XDG_CACHE_HOME/prbar`, else `~/.cache/prbar`. Everything under it
/// can be deleted at any time.
enum CacheLocation {
    static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".cache")
        return base.appendingPathComponent("prbar")
    }
}
