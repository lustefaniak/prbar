import Foundation

/// How authored draft PRs should affect the menu-bar badge, author-side
/// notifications (CI failed / ready-to-merge), and the My PRs list.
///
/// `.silence` is the default: drafts still appear in the My PRs list but
/// don't contribute to the badge counter and don't fire CI-failure
/// notifications. `.show` reverts to treating drafts like any other
/// authored PR. `.hide` additionally filters drafts out of the My PRs
/// list entirely (review-requested side is unaffected — that path
/// already hard-excludes drafts elsewhere).
enum MyDraftHandling: String, CaseIterable, Sendable, Hashable {
    case show
    case silence
    case hide

    static let storageKey = "myDraftHandling"
    static let `default`: MyDraftHandling = .silence

    static func current(_ defaults: UserDefaults = .standard) -> MyDraftHandling {
        guard let raw = defaults.string(forKey: storageKey),
              let v = MyDraftHandling(rawValue: raw)
        else { return .default }
        return v
    }

    /// True when drafts should *not* contribute to badge counters or
    /// fire author-side notifications.
    var silencesAuthoredDrafts: Bool {
        self != .show
    }

    /// True when drafts should be filtered out of the My PRs list.
    var hidesFromMyPRs: Bool {
        self == .hide
    }

    var pickerLabel: String {
        switch self {
        case .show:    return "Show normally"
        case .silence: return "Silence (no badge / notify)"
        case .hide:    return "Hide from My PRs"
        }
    }
}
