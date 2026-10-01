import Foundation
import Yams

/// The rules a repository keeps for everyone who reviews it:
/// `.prbar/rules/` on its default branch, the same layout as the user's own
/// rules directory. They decide between the user's rules and the prbar.yaml
/// settings, and only for repositories the user trusts
/// (`trustRepoRules`), since what they decide is posted under the user's
/// name. Read from the default branch, never the PR's head, so a PR can't
/// change how it is itself reviewed.
struct RepoRuleFiles: Sendable, Hashable {
    /// The tree's oid: equal oids, equal rules.
    var tree: String
    /// Paths relative to `.prbar/rules`: `select/10-x.yaml`, `lists.yaml`.
    var files: [String: String]
    /// Files GitHub returned without their text (too large). Their rules
    /// would silently be missing, so they refuse the whole directory.
    var truncated: [String] = []

    /// Compiled like the user's directory. Paths in errors and history are
    /// `owner/repo:.prbar/rules/...`, so they say whose rules they are.
    func compile(repo: String) throws -> Rules? {
        if !truncated.isEmpty {
            throw RuleDirectory.Error.unreadable(
                path: "\(repo):.prbar/rules", reason: "too large to read: \(truncated.sorted().joined(separator: ", "))")
        }
        return try RuleDirectory.compile(files, root: "\(repo):.prbar/rules")
    }
}

struct RepoRulesResponse: Decodable {
    struct Entry: Decodable {
        struct Object: Decodable {
            let text: String?
            let isTruncated: Bool?
            let entries: [Entry]?
        }
        let name: String
        let type: String
        let object: Object?
    }
    struct Tree: Decodable {
        let oid: String?
        let entries: [Entry]?
    }
    struct Repository: Decodable {
        let object: Tree?
    }
    struct DataBlock: Decodable {
        let repository: Repository?
    }
    let data: DataBlock

    /// Nil when the repository has no `.prbar/rules` directory.
    var files: RepoRuleFiles? {
        guard let tree = data.repository?.object, let oid = tree.oid else { return nil }
        var files: [String: String] = [:]
        var truncated: [String] = []
        func take(_ path: String, _ object: Entry.Object?) {
            if object?.isTruncated == true {
                truncated.append(path)
            } else if let text = object?.text {
                files[path] = text
            }
        }
        for entry in tree.entries ?? [] {
            take(entry.name, entry.object)
            for child in entry.object?.entries ?? [] {
                take("\(entry.name)/\(child.name)", child.object)
            }
        }
        return RepoRuleFiles(tree: oid, files: files, truncated: truncated)
    }
}
