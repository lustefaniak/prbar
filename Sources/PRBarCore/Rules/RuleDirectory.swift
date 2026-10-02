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
/// numeric prefix sets the order. Settings → Rules writes here, one file
/// at a time, and only rules that compile (`APIServer.saveRuleFile`).
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

    static let stages = ["select", "decide", "configure"]

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
        try compile(read(directory), root: directory.path)
    }

    /// The directory's rule files by path relative to it (`select/10-x.yaml`,
    /// `lists.yaml`), with their text.
    static func read(_ directory: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for url in stages.flatMap({ self.files($0, in: directory) }) + [listsFile(in: directory)] {
            guard let data = FileManager.default.contents(atPath: url.path) else {
                if url == listsFile(in: directory) { continue }
                throw Error.unreadable(path: url.path, reason: "not a readable UTF-8 file")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw Error.unreadable(path: url.path, reason: "not a readable UTF-8 file")
            }
            files[String(url.path.dropFirst(directory.path.count + 1))] = text
        }
        return files
    }

    /// Whether `path` names a file the rules read: `lists.yaml`, or a
    /// policy directly in a stage directory.
    static func isRuleFile(_ path: String) -> Bool {
        if path == "lists.yaml" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && stages.contains(String(parts[0])) && !parts[1].hasPrefix(".")
            && (parts[1].hasSuffix(".yaml") || parts[1].hasSuffix(".yml"))
    }

    /// Compiles rule files given by relative path, as `read` returns them.
    /// `root` prefixes each path in errors and in the rules' sources.
    /// Nil when there are no policies.
    static func compile(_ files: [String: String], root: String) throws -> Rules? {
        func sources(_ stage: String) -> [Rules.Source] {
            files.keys
                .filter { isRuleFile($0) && $0.hasPrefix("\(stage)/") }
                .sorted()
                .map { Rules.Source(path: "\(root)/\($0)", text: files[$0] ?? "") }
        }
        let select = sources("select")
        let decide = sources("decide")
        let configure = sources("configure")
        guard !select.isEmpty || !decide.isEmpty || !configure.isEmpty else { return nil }
        var lists: [String: [String]] = [:]
        if let text = files["lists.yaml"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                lists = try YAMLDecoder().decode([String: [String]]?.self, from: text) ?? [:]
            } catch {
                throw Error.unreadable(
                    path: "\(root)/lists.yaml", reason: "expected lists of names, like `trusted: [alice, bob]`: \(error)")
            }
        }
        do {
            return try Rules.compile(select: select, decide: decide, configure: configure, lists: lists)
        } catch {
            throw Error.invalid(String(describing: error))
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
