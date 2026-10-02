import Foundation
import Yams

/// Turns the `repos:` entries of an old prbar.yaml into a `configure`
/// rule, and their `excluded` / `trustRepoRules` into the `repositories:`
/// lists, then checks that every repository it knows of resolves to the
/// same settings both ways before anything is written.
enum RulesConvert {
    struct Result: Sendable {
        /// prbar.yaml without `repos:`, with `repositories:`.
        var configText: String
        /// Relative to the rules directory.
        var rulePath: String
        var ruleText: String
        var config: PRBarConfig
        /// How many entries were converted.
        var entries: Int
        /// The repositories compared.
        var checked: [String]
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case nothingToConvert
        case exists(String)
        case differs([String])
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .nothingToConvert: return "prbar.yaml has no `repos:` to convert"
            case .exists(let path): return "\(path) already exists; move it aside to convert again"
            case .differs(let lines):
                return "the converted rules would change the settings of some repositories, so nothing was written:\n" + lines.joined(separator: "\n")
            case .invalid(let reason): return reason
            }
        }
    }

    static let rulePath = "configure/50-repos.yaml"

    /// - Parameters:
    ///   - rules: the rules directory's files, by relative path; the
    ///     converted rule is checked together with them.
    ///   - repositories: names to check besides those the globs suggest:
    ///     what is in the inbox and the history.
    static func convert(
        configText: String, path: String, rules: [String: String], rulesRoot: String,
        repositories: Set<String>, date: Date = Date()
    ) throws -> Result {
        guard let root = try Yams.compose(yaml: configText), let mapping = root.mapping else {
            throw Error.invalid("\(path) is not a YAML mapping")
        }
        guard let reposNode = mapping["repos"], let sequence = reposNode.sequence, !sequence.isEmpty else {
            throw Error.nothingToConvert
        }
        if rules[rulePath] != nil { throw Error.exists(rulePath) }
        let entries = try YAMLDecoder().decode([RepoConfig].self, from: reposNode)
        let defaultTrust = mapping["defaults"]?.mapping?["trustRepoRules"]?.bool ?? false

        // The rest of the file, read as it is now.
        var rest = mapping
        rest["repos"] = nil
        if var defaults = rest["defaults"]?.mapping {
            defaults["trustRepoRules"] = nil
            rest["defaults"] = .mapping(defaults)
        }
        let restText = try Yams.serialize(node: .mapping(rest))
        var config = try ConfigFile.decode(restText, path: path).config
        config.repositories.hide = firstMatchList(entries, default: false) { $0.excluded }
        config.repositories.trustRules = firstMatchList(entries, default: defaultTrust) { $0.trustRepoRules ?? defaultTrust }

        let ruleText = policy(entries, date: date)
        var files = rules
        files[rulePath] = ruleText
        config.compiledRules = try RuleDirectory.compile(files, root: rulesRoot)

        let names = repositories.union(entries.flatMap { $0.repoGlobs.compactMap(sample) }).sorted()
        var differences: [String] = []
        for name in names {
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let old = entries.first { $0.matches(nameWithOwner: name) } ?? .default
            let new = config.rule(owner: parts[0], repo: parts[1])
            if let difference = difference(old: old, new: new, defaultTrust: defaultTrust) {
                differences.append("  \(name): \(difference)")
            }
        }
        guard differences.isEmpty else { throw Error.differs(differences) }

        var written = config
        written.compiledRules = nil
        return Result(
            configText: try ConfigFile.encode(written), rulePath: rulePath, ruleText: ruleText,
            config: config, entries: entries.count, checked: names)
    }

    /// What differs between an old entry and what the rules now give, or
    /// nil when nothing does.
    private static func difference(old: RepoConfig, new: RepoConfig, defaultTrust: Bool) -> String? {
        if old.excluded != new.excluded { return "excluded \(old.excluded) → \(new.excluded)" }
        let oldTrust = old.trustRepoRules ?? defaultTrust
        let newTrust = new.trustRepoRules ?? false
        if oldTrust != newTrust { return "trusts its rules \(oldTrust) → \(newTrust)" }
        func settings(_ config: RepoConfig) -> RepoConfig {
            var config = config
            config.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            config.repoGlobs = []
            config.excluded = false
            config.trustRepoRules = nil
            return config
        }
        let a = settings(old)
        let b = settings(new)
        guard a != b else { return nil }
        return "settings differ:\n    was: \(describe(a))\n    now: \(describe(b))"
    }

    private static func describe(_ config: RepoConfig) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[RepoConfig.omitIDUserInfoKey] = true
        return (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(config)"
    }

    /// A glob list, read later-wins, that holds for exactly the
    /// repositories whose first matching entry says `value`, or `default`
    /// when none matches. Patterns that can't be told apart this way are
    /// caught by the comparison afterwards.
    static func firstMatchList(_ entries: [RepoConfig], default: Bool, value: (RepoConfig) -> Bool) -> [String] {
        guard `default` || entries.contains(where: value) else { return [] }
        var list = `default` ? ["*/*"] : []
        for entry in entries.reversed() {
            let holds = value(entry)
            for glob in entry.repoGlobs where !glob.hasPrefix("!") {
                list.append(holds ? glob : "!" + glob)
            }
        }
        // A negation takes something away only from an earlier pattern that
        // matches what it names.
        var kept: [String] = []
        for pattern in list {
            if pattern.hasPrefix("!") {
                let name = sample(String(pattern.dropFirst())) ?? String(pattern.dropFirst())
                guard kept.contains(where: { !$0.hasPrefix("!") && GlobMatcher.match($0, name) }) else { continue }
            }
            kept.append(pattern)
        }
        return kept
    }

    /// A repository name a glob matches, to check it: `*` read as `x`.
    private static func sample(_ glob: String) -> String? {
        guard !glob.hasPrefix("!") else { return nil }
        let name = glob.replacingOccurrences(of: "**", with: "x").replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: "?", with: "x")
        return name.contains("/") ? name : nil
    }

    // MARK: - the policy

    static func policy(_ entries: [RepoConfig], date: Date) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        var lines = [
            "# yaml-language-server: $schema=\(RuleSchema.url(.configure))",
            "#",
            "# Converted on \(day) from the repos: entries of prbar.yaml, in their order:",
            "# the first one that matches a repository sets its settings, and what it",
            "# doesn't set comes from the defaults in prbar.yaml.",
            "name: repos",
            "rule:",
            "  match:",
        ]
        var ids: Set<String> = []
        for entry in entries {
            var id = ruleID(entry.repoGlobs)
            var n = 2
            while ids.contains(id) {
                id = ruleID(entry.repoGlobs) + "-\(n)"
                n += 1
            }
            ids.insert(id)
            let globs = entry.repoGlobs.map(cel).joined(separator: ", ")
            lines.append("    - condition: '" + "glob(repo.full_name, [\(globs)])".replacingOccurrences(of: "'", with: "''") + "'")
            lines.append("      output:")
            lines.append(contentsOf: outputLines(RuleConfiguration(entry, rule: id), indent: 8))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func ruleID(_ globs: [String]) -> String {
        let base = globs.first { !$0.hasPrefix("!") } ?? "repos"
        let id = String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let trimmed = id.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return trimmed.isEmpty ? "repos" : trimmed
    }

    /// The output's fields as YAML, in the order the schema lists them.
    static func outputLines(_ output: RuleConfiguration, indent: Int) -> [String] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(output),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return lines(object, fields: RuleOutputs.configure, indent: indent)
    }

    private static func lines(_ object: [String: Any], fields: [RuleOutputs.Field], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        for field in fields {
            guard let value = object[field.name], !(value is NSNull) else { continue }
            switch (field.kind, value) {
            case (.object(let subfields), let nested as [String: Any]):
                let inner = lines(nested, fields: subfields, indent: indent + 2)
                out.append(pad + field.name + (inner.isEmpty ? ": {}" : ":"))
                out.append(contentsOf: inner)
            case (.severity, let name as String):
                out.append(pad + field.name + ": " + name)
            default:
                out.append(pad + field.name + ": " + scalar(value, field.kind))
            }
        }
        return out
    }

    private static func scalar(_ value: Any, _ kind: RuleOutputs.Kind) -> String {
        switch (kind, value) {
        case (.bool, let b as Bool): return b ? "true" : "false"
        case (.int, let n as Int): return String(n)
        case (.number, let n as NSNumber): return String(n.doubleValue)
        case (.strings, let list as [String]): return "[" + list.map(yaml).joined(separator: ", ") + "]"
        case (.stringMap, let map as [String: String]):
            return "{" + map.keys.sorted().map { yaml($0) + ": " + yaml(map[$0] ?? "") }.joined(separator: ", ") + "}"
        case (_, let s as String): return yaml(s)
        default: return yaml("\(value)")
        }
    }

    /// A plain YAML scalar where that reads back as the same string, else
    /// a double-quoted one: JSON's escaping is valid there.
    private static func yaml(_ text: String) -> String {
        let plain = !text.isEmpty
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_./".unicodeScalars.contains($0) }
            && !["true", "false", "yes", "no", "on", "off", "null", "y", "n"].contains(text.lowercased())
            && Double(text) == nil && Int(text) == nil
            && !text.hasPrefix("-") && !text.hasPrefix(".")
        if plain { return text }
        return quoted(text)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func cel(_ text: String) -> String { quoted(text) }
}

extension RulesConvert {
    struct Written: Codable, Sendable, Equatable {
        var entries: Int
        var checked: [String]
        /// Where the converted rule was written.
        var rulePath: String
        /// The old prbar.yaml, kept beside the new one.
        var backupPath: String
        var ruleText: String
    }

    /// Converts the config at `configURL` into a rule in `rulesURL`, keeping
    /// the old file as `<name>.before-rules`. With `dryRun`, writes nothing.
    static func run(
        configURL: URL, rulesURL: URL, repositories: Set<String>, dryRun: Bool = false, date: Date = Date()
    ) throws -> Written {
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let text = String(data: data, encoding: .utf8)
        else { throw Error.invalid("cannot read \(configURL.path)") }
        let result = try convert(
            configText: text, path: configURL.path, rules: try RuleDirectory.read(rulesURL), rulesRoot: rulesURL.path,
            repositories: repositories, date: date)
        var backup = configURL.deletingLastPathComponent()
            .appendingPathComponent(configURL.lastPathComponent + ".before-rules")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = configURL.deletingLastPathComponent()
                .appendingPathComponent(configURL.lastPathComponent + ".before-rules-\(n)")
            n += 1
        }
        let written = Written(
            entries: result.entries, checked: result.checked,
            rulePath: rulesURL.appendingPathComponent(result.rulePath).path, backupPath: backup.path,
            ruleText: result.ruleText)
        guard !dryRun else { return written }
        try Data(text.utf8).write(to: backup)
        let ruleURL = rulesURL.appendingPathComponent(result.rulePath)
        try FileManager.default.createDirectory(at: ruleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(result.ruleText.utf8).write(to: ruleURL, options: .atomic)
        try ConfigFile.write(result.configText, to: configURL)
        return written
    }

    /// Every repository PRBar has seen: the inbox snapshot and the review
    /// and rule histories. The conversion is checked on each of them.
    static func knownRepositories(stateDirectory: URL) -> Set<String> {
        var names: Set<String> = []
        let history = stateDirectory.appendingPathComponent("history")
        for record in RuleEvaluationLog.rules(in: history).readAll() {
            names.insert(record.repo)
        }
        for record in ReviewHistory(in: history).readAll() {
            names.insert("\(record.owner)/\(record.repo)")
        }
        if let data = FileManager.default.contents(atPath: stateDirectory.appendingPathComponent("inbox.json").path),
           let prs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for pr in prs {
                if let owner = pr["owner"] as? String, let repo = pr["repo"] as? String {
                    names.insert("\(owner)/\(repo)")
                }
            }
        }
        return names.filter { $0.split(separator: "/").count == 2 }
    }
}
