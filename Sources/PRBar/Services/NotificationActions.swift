import AppKit
import Foundation
import UserNotifications

/// Identifiers for `UNNotificationCategory` registrations and the action
/// buttons attached to them. Kept in one place so `UNNotificationDeliverer`
/// (which sets `categoryIdentifier`) and `NotificationActionRouter` (which
/// switches on `actionIdentifier`) can't drift.
enum NotificationCategoryID {
    static let mergeReady = "merge_ready"
    static let reviewsReady = "reviews_ready"
    static let ciAlert = "ci_alert"
}

enum NotificationActionID {
    static let mergeAll = "merge_all"
    static let open = "open"
}

/// userInfo keys carried on every PRBar notification so the action router
/// can resolve which PRs the banner referred to.
enum NotificationUserInfoKey {
    static let nodeIds = "prNodeIds"
    static let urls = "prURLs"
    static let primaryURL = "url"
}

/// Routes notification taps and action-button presses back into app
/// services. Set as `UNUserNotificationCenter.current().delegate` once at
/// launch.
///
/// Why a separate NSObject: `UNUserNotificationCenterDelegate` is an
/// `@objc` protocol whose callbacks fire on a background queue, and
/// `@MainActor`-isolated services (`PRPoller`) must be touched on the
/// main actor — so the router hops to MainActor before dispatching.
@MainActor
final class NotificationActionRouter: NSObject {
    private weak var poller: PRPoller?

    init(poller: PRPoller) {
        self.poller = poller
        super.init()
    }

    /// Registers the merge_ready / reviews_ready / ci_alert categories
    /// with their action buttons. Idempotent — calling more than once
    /// just replaces the registration.
    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let mergeAll = UNNotificationAction(
            identifier: NotificationActionID.mergeAll,
            title: "Merge all",
            options: [.foreground]
        )
        let open = UNNotificationAction(
            identifier: NotificationActionID.open,
            title: "Open",
            options: [.foreground]
        )

        let mergeReady = UNNotificationCategory(
            identifier: NotificationCategoryID.mergeReady,
            actions: [mergeAll, open],
            intentIdentifiers: [],
            options: []
        )
        let reviewsReady = UNNotificationCategory(
            identifier: NotificationCategoryID.reviewsReady,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        let ciAlert = UNNotificationCategory(
            identifier: NotificationCategoryID.ciAlert,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([mergeReady, reviewsReady, ciAlert])
    }

    func install(on center: UNUserNotificationCenter = .current()) {
        center.delegate = self
        Self.registerCategories(on: center)
    }

    // MARK: - action handlers (MainActor-isolated)

    fileprivate struct Payload: Sendable {
        let nodeIds: [String]
        let urls: [String]
        let primaryURL: String?

        init(userInfo: [AnyHashable: Any]) {
            self.nodeIds = (userInfo[NotificationUserInfoKey.nodeIds] as? [String]) ?? []
            self.urls = (userInfo[NotificationUserInfoKey.urls] as? [String]) ?? []
            self.primaryURL = userInfo[NotificationUserInfoKey.primaryURL] as? String
        }
    }

    fileprivate func handle(actionIdentifier: String, payload: Payload) {
        switch actionIdentifier {
        case NotificationActionID.mergeAll:
            mergeAllReadyPRs(payload: payload)
        case NotificationActionID.open,
             UNNotificationDefaultActionIdentifier:
            openPrimaryURL(payload: payload)
        default:
            break
        }
    }

    private func mergeAllReadyPRs(payload: Payload) {
        guard let poller else { return }
        guard !payload.nodeIds.isEmpty else {
            openPrimaryURL(payload: payload)
            return
        }
        let byId = Dictionary(uniqueKeysWithValues: poller.prs.map { ($0.nodeId, $0) })
        for id in payload.nodeIds {
            guard let pr = byId[id] else { continue }
            guard EventDeriver.isReadyToMerge(pr) else { continue }
            // Prefer squash (matches the row's default primary action);
            // fall back to whatever the repo allows.
            let method = preferredMergeMethod(for: pr) ?? .squash
            poller.mergePR(pr, method: method)
        }
    }

    private func preferredMergeMethod(for pr: InboxPR) -> MergeMethod? {
        for candidate in [MergeMethod.squash, .merge, .rebase] where pr.allowedMergeMethods.contains(candidate) {
            return candidate
        }
        return nil
    }

    private func openPrimaryURL(payload: Payload) {
        let raw = payload.primaryURL ?? payload.urls.first
        guard let raw, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension NotificationActionRouter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // PRBar is a menu-bar agent (LSUIElement=true), so "in the
        // foreground" is the common case — show the banner and play
        // the sound regardless.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let payload = Payload(userInfo: response.notification.request.content.userInfo)
        // Hand the dispatched work to the main actor; the system gives
        // us a brief window after the handler returns, which is enough
        // to fire mergePR / NSWorkspace.open synchronously on main.
        Task { @MainActor in
            self.handle(actionIdentifier: actionId, payload: payload)
        }
        completionHandler()
    }
}
