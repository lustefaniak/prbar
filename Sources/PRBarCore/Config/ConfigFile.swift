import Foundation
import Yams

/// Reading and writing `prbar.yaml`. JSON is valid YAML, so a `prbar.json`
/// written for earlier CLI versions loads through the same path.
enum ConfigFile {
    struct Loaded: Sendable, Hashable {
        var config: PRBarConfig
        /// Keys the decoder doesn't know. They are ignored, which is right
        /// for forward compatibility and wrong for a typo, so they are
        /// reported instead of dropped in silence.
        var warnings: [String]
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case unreadable(path: String, reason: String)
        case invalid(path: String, reason: String)
        case unsupportedVersion(path: String, version: Int)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path, reason):
                return "cannot read config \(path): \(reason)"
            case let .invalid(path, reason):
                return "invalid config \(path): \(reason)"
            case let .unsupportedVersion(path, version):
                return "config \(path) is version \(version); this PRBar understands up to \(PRBarConfig.currentVersion)"
            }
        }
    }

    static let header = """
    # PRBar configuration, read by the menu-bar app and the prbar-review CLI.
    # Saving from the app's Settings rewrites this file: hand edits are kept,
    # comments are not.
    #
    # A key in a repo rule overrides `defaults` for that repo; a missing key
    # inherits. A key missing from `defaults` means PRBar's shipped default.
    # Details: https://github.com/lustefaniak/prbar/blob/main/docs/configuration.md

    """

    static func decode(_ text: String, path: String = "<config>") throws -> Loaded {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw Error.invalid(path: path, reason: String(describing: error))
        }
        guard let node else { return Loaded(config: PRBarConfig(), warnings: []) }
        guard node.mapping != nil else {
            throw Error.invalid(path: path, reason: "top level must be a mapping")
        }
        let config: PRBarConfig
        do {
            config = try YAMLDecoder().decode(PRBarConfig.self, from: node)
        } catch {
            throw Error.invalid(path: path, reason: describe(error))
        }
        if config.version > PRBarConfig.currentVersion {
            throw Error.unsupportedVersion(path: path, version: config.version)
        }
        return Loaded(config: config, warnings: unknownKeys(in: node))
    }

    static func encode(_ config: PRBarConfig) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.width = -1
        let raw = try encoder.encode(config, userInfo: [RepoConfig.omitIDUserInfoKey: true])
        // Yams writes every Double in scientific notation (`8.5e-1` for a
        // 0.85 confidence floor), which nobody wants to hand-edit. Re-parse
        // and rewrite float scalars as plain decimals.
        guard let node = try Yams.compose(yaml: raw) else { return header + raw }
        let body = try Yams.serialize(node: decimalFloats(node), width: -1, allowUnicode: true)
        return header + body
    }

    private static func decimalFloats(_ node: Node) -> Node {
        switch node {
        case var .scalar(scalar):
            if node.tag.rawValue == Tag.Name.float.rawValue, let value = node.float, value.isFinite {
                scalar.string = "\(value)"
            }
            return .scalar(scalar)
        case let .mapping(mapping):
            return Node(mapping.map { (decimalFloats($0.key), decimalFloats($0.value)) }, mapping.tag, mapping.style)
        case let .sequence(sequence):
            return Node(sequence.map(decimalFloats), sequence.tag, sequence.style)
        case .alias:
            return node
        }
    }

    static func load(url: URL) throws -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Error.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.invalid(path: url.path, reason: "not valid UTF-8")
        }
        return try decode(text, path: url.path)
    }

    /// Write via a temp file and rename, so a reader (the other process,
    /// or this one's watcher) never sees a half-written file.
    static func write(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    // MARK: - unknown keys

    private typealias Schema = [String: Field]

    private indirect enum Field {
        case leaf
        case object(Schema)
        case list(Schema)
    }

    private static func keys<K: CodingKey & CaseIterable>(_: K.Type) -> Schema {
        Dictionary(uniqueKeysWithValues: K.allCases.map { ($0.stringValue, Field.leaf) })
    }

    private static let reviewSettings: Schema = {
        var s = keys(ReviewDefaults.CodingKeys.self).merging(keys(RepoConfig.CodingKeys.self)) { a, _ in a }
        s["autoApprove"] = .object(keys(AutoApproveConfig.CodingKeys.self))
        s["autoDeny"] = .object(keys(AutoDenyConfig.CodingKeys.self))
        s["resolveThreads"] = .object(keys(ResolveThreadsConfig.CodingKeys.self))
        return s
    }()

    private static let schema: Schema = {
        var top = keys(PRBarConfig.CodingKeys.self)
        var defaults = keys(ReviewDefaults.CodingKeys.self)
        var repo = keys(RepoConfig.CodingKeys.self)
        for nested in ["autoApprove", "autoDeny", "resolveThreads"] {
            defaults[nested] = reviewSettings[nested]
            repo[nested] = reviewSettings[nested]
        }
        top["defaults"] = .object(defaults)
        top["repos"] = .list(repo)
        top["agents"] = .object(keys(AgentPolicy.CodingKeys.self))
        return top
    }()

    private static func unknownKeys(in node: Node) -> [String] {
        var found: [String] = []
        walk(node, schema: schema, path: "", into: &found)
        return found
    }

    private static func walk(_ node: Node, schema: Schema, path: String, into found: inout [String]) {
        guard let mapping = node.mapping else { return }
        for (keyNode, value) in mapping {
            guard let key = keyNode.string else { continue }
            let here = path.isEmpty ? key : "\(path).\(key)"
            switch schema[key] {
            case nil:
                found.append("unknown key `\(here)` (line \(keyNode.mark?.line ?? 0)) is ignored")
            case .leaf?:
                break
            case let .object(inner)?:
                walk(value, schema: inner, path: here, into: &found)
            case let .list(inner)?:
                for (index, item) in (value.sequence.map(Array.init) ?? []).enumerated() {
                    walk(item, schema: inner, path: "\(here)[\(index)]", into: &found)
                }
            }
        }
    }

    private static func describe(_ error: Swift.Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        func at(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return path.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch decoding {
        case let .typeMismatch(_, ctx), let .valueNotFound(_, ctx), let .dataCorrupted(ctx):
            return "`\(at(ctx))`: \(ctx.debugDescription)"
        case let .keyNotFound(key, ctx):
            let parent = at(ctx)
            return "`\(parent.isEmpty ? key.stringValue : "\(parent).\(key.stringValue)")` is required"
        @unknown default:
            return String(describing: decoding)
        }
    }
}

/// Where the config file lives. One path for the app and the CLI, so
/// they read the same file by default.
enum ConfigLocation {
    /// `$PRBAR_CONFIG`, else `$XDG_CONFIG_HOME/prbar/prbar.yaml`, else
    /// `~/.config/prbar/prbar.yaml`. XDG rather than Application Support
    /// on macOS too: the file is meant to be edited and shared, and the
    /// CLI looks in the same place on Linux.
    static func userConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let explicit = environment["PRBAR_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("prbar/prbar.yaml")
    }

    /// `$XDG_STATE_HOME/prbar`, else `~/.local/state/prbar`.
    static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
        return base.appendingPathComponent("prbar")
    }

    /// Copy of the last config that loaded cleanly, used when the real
    /// file is broken at startup.
    static func lastGoodURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        stateDirectory(environment: environment, home: home).appendingPathComponent("config.last-good.yaml")
    }
}
