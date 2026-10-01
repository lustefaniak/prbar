import Foundation
import Yams

/// Where the rules live: a directory of their own, apart from prbar.yaml,
/// found by convention rather than listed anywhere.
///
/// ```
/// rules/
///   lists.yaml              # named lists: `trusted: [alice, bob]`
///   select/10-skip.yaml     # CEL policies for the select stage
///   decide/10-approve.yaml  # CEL policies for the decide stage
/// ```
///
/// Every `*.yaml` / `*.yml` in a stage directory is a policy; they run in
/// file name order and the first one whose rules match decides, so a
/// numeric prefix sets the order. Settings never writes here.
enum RuleDirectory {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case unreadable(path: String, reason: String)
        /// The policies don't compile; the description positions every
        /// problem in its file.
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path, reason): return "cannot read rules \(path): \(reason)"
            case let .invalid(description): return "rules don't compile:\n\(description)"
            }
        }
    }

    static let stages = ["select", "decide"]

    /// `$PRBAR_RULES`, else `rules/` beside the config file.
    static func url(
        configFile: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["PRBAR_RULES"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        return configFile.deletingLastPathComponent().appendingPathComponent("rules")
    }

    /// The policy files of a stage, in the order they run.
    static func files(_ stage: String, in directory: URL) -> [URL] {
        let dir = directory.appendingPathComponent(stage)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && ($0.hasSuffix(".yaml") || $0.hasSuffix(".yml")) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    static func listsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("lists.yaml")
    }

    /// Reads and compiles the directory. Nil when it holds no policies.
    static func load(_ directory: URL) throws -> Rules? {
        func read(_ url: URL) throws -> Rules.Source {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8)
            else {
                throw Error.unreadable(path: url.path, reason: "not a readable UTF-8 file")
            }
            return Rules.Source(path: url.path, text: text)
        }
        let select = try files("select", in: directory).map(read)
        let decide = try files("decide", in: directory).map(read)
        guard !select.isEmpty || !decide.isEmpty else { return nil }
        let lists = try readLists(listsFile(in: directory))
        do {
            return try Rules.compile(select: select, decide: decide, lists: lists)
        } catch {
            throw Error.invalid(String(describing: error))
        }
    }

    private static func readLists(_ url: URL) throws -> [String: [String]] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.unreadable(path: url.path, reason: "not valid UTF-8")
        }
        do {
            return try YAMLDecoder().decode([String: [String]]?.self, from: text) ?? [:]
        } catch {
            throw Error.unreadable(path: url.path, reason: "expected lists of names, like `trusted: [alice, bob]`: \(error)")
        }
    }

    /// Every file that `load` reads, with its contents, so a watcher
    /// notices a file added, removed or edited.
    static func fingerprint(_ directory: URL) -> [String: Data] {
        var seen: [String: Data] = [:]
        for url in stages.flatMap({ files($0, in: directory) }) + [listsFile(in: directory)] {
            if let data = FileManager.default.contents(atPath: url.path) { seen[url.path] = data }
        }
        return seen
    }
}
