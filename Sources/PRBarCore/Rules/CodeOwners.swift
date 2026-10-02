import CELSwift
import Foundation

/// A CODEOWNERS file, matched the way GitHub does: the last line whose
/// pattern matches a path names its owners, and a matching line with no
/// owners leaves the path unowned.
struct CodeOwners: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        var pattern: String
        /// `@login`, `@org/team` or an email, as written.
        var owners: [String]
        var line: Int
    }

    var lines: [Line]

    /// GitHub reads the first of these that exists, on the PR's base branch.
    static let locations = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]

    init(_ text: String) {
        var lines: [Line] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var content = Substring(raw)
            if let hash = content.firstIndex(of: "#") { content = content[..<hash] }
            let words = content.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            guard let pattern = words.first else { continue }
            lines.append(Line(pattern: pattern, owners: Array(words.dropFirst()), line: index + 1))
        }
        self.lines = lines
    }

    /// The line that decides `path`'s owners, nil when none matches.
    func rule(for path: String) -> Line? {
        lines.last { Self.matches($0.pattern, path) }
    }

    /// gitignore-style, as far as CODEOWNERS uses it: `*` and `?` stay
    /// within a directory, `**` crosses them, a leading or inner `/`
    /// anchors at the root, a pattern naming a directory owns everything
    /// under it, and `dir/*` owns only the files directly in `dir`.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: regex(pattern)) else { return false }
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var candidates = [path]
        // A directory pattern matches the file through one of its folders.
        if !pattern.hasSuffix("/*") {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                candidates.append(parts.joined(separator: "/") + "/")
                parts = parts.dropLast()
            }
        }
        return candidates.contains { candidate in
            regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }
    }

    static func regex(_ pattern: String) -> String {
        var body = pattern
        let directoryOnly = body.hasSuffix("/")
        if directoryOnly { body.removeLast() }
        let anchored = body.hasPrefix("/") || body.dropLast().contains("/")
        if body.hasPrefix("/") { body.removeFirst() }
        var out = ""
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                // `**/` is any number of folders, `**` elsewhere anything.
                if i + 2 < chars.count, chars[i + 2] == "/" {
                    out += "(?:.*/)?"
                    i += 3
                } else {
                    out += ".*"
                    i += 2
                }
                continue
            }
            switch c {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "\\", "{", "}", "[", "]": out += "\\\(c)"
            default: out.append(c)
            }
            i += 1
        }
        let prefix = anchored ? "^" : "^(?:.*/)?"
        return prefix + out + (directoryOnly ? "/$" : "/?$")
    }

    /// Every changed file with its owners. `members` expands a team
    /// (`org/team`) to logins; owners that are emails can't name a login
    /// and are left out.
    func owners(of paths: [String], members: [String: [String]]) -> [FileOwnersFacts] {
        paths.map { path in
            guard let rule = rule(for: path) else { return FileOwnersFacts(path: path, owners: [], teams: [], pattern: nil) }
            var logins: [String] = []
            var teams: [String] = []
            for owner in rule.owners where owner.hasPrefix("@") {
                let name = String(owner.dropFirst())
                if name.contains("/") {
                    teams.append(name)
                    logins += members[name.lowercased()] ?? []
                } else {
                    logins.append(name)
                }
            }
            var seen = Set<String>()
            logins = logins.filter { seen.insert($0.lowercased()).inserted }
            return FileOwnersFacts(path: path, owners: logins, teams: teams, pattern: rule.pattern)
        }
    }

    /// The teams the lines matching `paths` name, `org/team` lowercased.
    func teams(for paths: [String]) -> Set<String> {
        var out = Set<String>()
        for path in paths {
            for owner in rule(for: path)?.owners ?? [] where owner.hasPrefix("@") && owner.contains("/") {
                out.insert(String(owner.dropFirst()).lowercased())
            }
        }
        return out
    }
}

/// One changed file's code owners, for `pr.codeowners`.
struct FileOwnersFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.FileOwners"

    var path: String
    /// Logins: the users the deciding line names, and the members of the
    /// teams it names. Empty when no line owns the file.
    var owners: [String]
    /// The teams that line names, `org/team`.
    var teams: [String]
    /// The deciding line's pattern, nil when none matched.
    var pattern: String?
}
