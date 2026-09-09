import Foundation

/// Parsed command line. Kept a value so the arg grammar is unit-testable
/// without spawning the binary.
struct Invocation: Equatable {
    struct Target: Equatable {
        let owner: String
        let repo: String
        let number: Int
    }

    let target: Target
    var force: Bool = false
    var providerOverride: ProviderID?
    var configPath: String?

    /// Where to write the full review. `-` means stdout. Nil discards
    /// everything but the summary line in the terminal event.
    var reviewJsonPath: String?

    init?(args: [String]) {
        var positional: String?
        var force = false
        var provider: ProviderID?
        var configPath: String?
        var reviewJsonPath: String?

        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            switch arg {
            case "--force":
                force = true
            case "--provider":
                i += 1
                guard i < args.endIndex, let p = ProviderID(rawValue: args[i]) else { return nil }
                provider = p
            case "--config":
                i += 1
                guard i < args.endIndex else { return nil }
                configPath = args[i]
            case "--review-json":
                i += 1
                guard i < args.endIndex else { return nil }
                reviewJsonPath = args[i]
            default:
                guard !arg.hasPrefix("-"), positional == nil else { return nil }
                positional = arg
            }
            i += 1
        }

        guard let positional, let target = Self.parseTarget(positional) else { return nil }
        self.target = target
        self.force = force
        self.providerOverride = provider
        self.configPath = configPath
        self.reviewJsonPath = reviewJsonPath
    }

    /// Accepts a PR URL (`https://github.com/o/r/pull/12`, trailing path
    /// and query tolerated) or the shorthand `o/r#12`.
    static func parseTarget(_ raw: String) -> Target? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = trimmed.firstIndex(of: "#") {
            let slug = trimmed[trimmed.startIndex..<hash].split(separator: "/")
            guard slug.count == 2,
                  let number = Int(trimmed[trimmed.index(after: hash)...])
            else { return nil }
            return Target(owner: String(slug[0]), repo: String(slug[1]), number: number)
        }
        let parts = trimmed
            .split(separator: "?", maxSplits: 1).first?
            .split(separator: "/")
            .map(String.init) ?? []
        guard let pullIdx = parts.firstIndex(of: "pull"),
              pullIdx >= 2, pullIdx + 1 < parts.count,
              let number = Int(parts[pullIdx + 1])
        else { return nil }
        return Target(owner: parts[pullIdx - 2], repo: parts[pullIdx - 1], number: number)
    }
}
