import Foundation

/// Loads bundled prompts and the AI output schema from the .app's
/// Resources/. In Phase 2+ we'll add a layer that prefers user-customized
/// versions in `~/Library/Application Support/io.synq.prbar/prompts/`,
/// falling back to bundle defaults — for now we always read the bundle.
enum PromptLibrary {
    enum Error: Swift.Error, LocalizedError, Sendable {
        case resourceNotFound(String)
        case decodeFailed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .resourceNotFound(let n):
                return "Bundled resource not found: \(n)"
            case .decodeFailed(let n, let err):
                return "Failed to read \(n): \(err)"
            }
        }
    }

    /// The base review prompt. Combine with a per-language override (if any)
    /// to produce the final system prompt.
    static func systemBase() throws -> String {
        try loadString("system-base", ext: "md", subdir: "prompts")
    }

    /// Per-language override prompt for the dominant language in the diff.
    /// Returns nil when we don't have a template for that language — caller
    /// should just use systemBase alone.
    static func languageOverride(for language: Language) -> String? {
        guard let name = language.promptResourceName else { return nil }
        return try? loadString(name, ext: "md", subdir: "prompts")
    }

    /// The JSON Schema we hand to `claude --json-schema`. Returned as Data so
    /// it can be passed straight to the subprocess on stdin or as a file.
    static func outputSchema() throws -> Data {
        try loadData("review", ext: "json", subdir: "schemas")
    }

    /// Convenience: builds a complete system prompt by concatenating the
    /// base prompt and the per-language override (if any), separated by a
    /// blank line.
    static func systemPrompt(for language: Language) throws -> String {
        let base = try systemBase()
        if let override = languageOverride(for: language), !override.isEmpty {
            return base + "\n\n" + override
        }
        return base
    }

    // MARK: - private

    private static func loadString(_ name: String, ext: String, subdir: String) throws -> String {
        let data = try loadData(name, ext: ext, subdir: subdir)
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.decodeFailed("\(subdir)/\(name).\(ext)", underlying: "not valid UTF-8")
        }
        return s
    }

    private static func loadData(_ name: String, ext: String, subdir: String) throws -> Data {
        let bundle = Bundle.main
        // Try with subdirectory first (XcodeGen preserves directory structure).
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdir) {
            return try Data(contentsOf: url)
        }
        // Fallback: flattened (Xcode sometimes flattens, especially in test bundles).
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        throw Error.resourceNotFound("\(subdir)/\(name).\(ext)")
    }
}

/// Languages we ship a per-language prompt override for. Detected from the
/// majority file extension in a Subdiff (Phase 2c).
enum Language: String, Sendable, Hashable, CaseIterable {
    case go
    case typescript
    case swift
    case unknown

    /// Maps a file extension (without dot) to a Language. Returns .unknown
    /// for anything we don't have a template for.
    static func from(fileExtension ext: String) -> Language {
        switch ext.lowercased() {
        case "go":
            return .go
        case "ts", "tsx", "js", "jsx", "mjs", "cjs":
            return .typescript
        case "swift":
            return .swift
        default:
            return .unknown
        }
    }

    var promptResourceName: String? {
        switch self {
        case .go:         return "golang"
        case .typescript: return "typescript"
        case .swift:      return "swift"
        case .unknown:    return nil
        }
    }
}
