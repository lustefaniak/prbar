import Foundation

/// Decides which AI providers' missing CLI is worth flagging, given the
/// user's provider configuration. A user who runs a single backend
/// (e.g. claude only) doesn't need "codex not installed" noise — this is
/// the shared predicate behind the General Settings picker labels and the
/// Diagnostics tool-availability list.
enum ProviderRelevance {
    /// `@AppStorage` key for the opt-in suppression toggle. Default off,
    /// so the existing "flag every backend" behaviour is preserved until
    /// the user asks for it.
    static let suppressionStorageKey = "suppressUnusedProviderWarnings"

    /// Providers whose absence should still surface a warning.
    ///
    /// - Suppression off: every provider (unchanged behaviour).
    /// - Suppression on: only providers the config can actually reach —
    ///   the app-wide default unioned with every per-repo
    ///   `providerOverride`. "Auto" keeps **both**, since it runs
    ///   whichever is installed. An unrecognised stored default falls back
    ///   to "warn about everything" rather than silently hiding a real gap.
    static func relevantProviders(
        suppressionEnabled: Bool,
        defaultProviderRaw: String,
        repoOverrides: [ProviderID]
    ) -> Set<ProviderID> {
        guard suppressionEnabled else { return Set(ProviderID.allCases) }

        var relevant = Set(repoOverrides)
        if defaultProviderRaw == ProviderID.autoSentinel {
            relevant.formUnion(ProviderID.allCases)
        } else if let resolved = ProviderID(rawValue: defaultProviderRaw) {
            relevant.insert(resolved)
        } else {
            relevant.formUnion(ProviderID.allCases)
        }
        return relevant
    }

    /// Whether a probed tool's missing-CLI warning should be hidden.
    /// True only for an AI provider that is **absent** and **not** in the
    /// relevant set. Non-provider tools (`gh`, `git`) never map to a
    /// `ProviderID`, and present tools fail the `available` guard, so
    /// neither is ever suppressed — their warnings always stand.
    static func isSuppressed(
        toolName: String,
        available: Bool,
        relevantProviders: Set<ProviderID>
    ) -> Bool {
        guard !available, let provider = ProviderID(rawValue: toolName) else {
            return false
        }
        return !relevantProviders.contains(provider)
    }
}
