import Foundation
import Observation
import OSLog
import UserNotifications

private let notifierLog = Logger(subsystem: "dev.lustefaniak.prbar", category: "notifications")

/// Coalesces NotificationEvents within a settling window and delivers them
/// as macOS notifications via UNUserNotificationCenter. Suppresses delivery
/// while the popover is open (so opening the menu-bar icon doesn't trigger
/// the same banner the user is about to see anyway).
@MainActor
@Observable
final class Notifier {
    /// Settling window before pending events get delivered. Reset every time
    /// a new event arrives, so a flurry of changes coalesces into one banner.
    var debounceWindow: Duration = .seconds(60)

    /// Delay before delivering after the popover closes. Short enough that
    /// we don't appear stale, long enough that we don't startle the user
    /// who just clicked away.
    var postPopoverCloseDelay: Duration = .milliseconds(500)

    private(set) var pending: [NotificationEvent] = []
    private(set) var isPopoverVisible: Bool = false

    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    @ObservationIgnored
    private let deliverer: NotificationDeliverer

    init(deliverer: NotificationDeliverer = UNNotificationDeliverer()) {
        self.deliverer = deliverer
    }

    func requestAuthorization() async {
        await deliverer.requestAuthorization()
    }

    /// Mark the popover open/closed. While open, deliveries are paused; a
    /// transition to closed re-arms the timer so any pending events fire
    /// shortly after.
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        if !visible && !pending.isEmpty {
            scheduleFire(after: postPopoverCloseDelay)
        }
    }

    func enqueue(_ events: [NotificationEvent]) {
        guard !events.isEmpty else { return }
        // Dedupe against pending — the same PR can flip back and forth
        // between polls, we don't need to notify twice.
        for ev in events where !pending.contains(ev) {
            pending.append(ev)
        }
        notifierLog.notice("Notifier.enqueue events=\(events.count, privacy: .public) pending=\(self.pending.count, privacy: .public) popoverVisible=\(self.isPopoverVisible, privacy: .public)")
        scheduleFire(after: debounceWindow)
    }

    private func scheduleFire(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        guard !pending.isEmpty else { return }
        if isPopoverVisible {
            // Hold pending until popover closes; setPopoverVisible(false)
            // will reschedule.
            notifierLog.notice("Notifier.fire suppressed (popover visible) pending=\(self.pending.count, privacy: .public)")
            return
        }
        let events = pending
        pending.removeAll()
        notifierLog.notice("Notifier.fire delivering events=\(events.count, privacy: .public)")
        await deliverer.deliver(events)
    }
}

/// Indirection for tests — production uses UNNotificationDeliverer; tests
/// inject a recording deliverer to assert on what would have been sent.
protocol NotificationDeliverer: Sendable {
    func requestAuthorization() async
    func deliver(_ events: [NotificationEvent]) async
}

struct UNNotificationDeliverer: NotificationDeliverer {
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(_ events: [NotificationEvent]) async {
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: events)
        content.body = Self.body(for: events)
        content.sound = .default
        content.categoryIdentifier = Self.category(for: events)
        // Carry every event's nodeId + URL so the action router can
        // resolve "Merge all" against PRPoller.prs and "Open" can fall
        // back to any URL when the primary one isn't openable.
        var userInfo: [String: Any] = [
            NotificationUserInfoKey.nodeIds: events.map(\.prNodeId),
            NotificationUserInfoKey.urls: events.map { $0.prURL.absoluteString }
        ]
        if let url = events.first?.prURL {
            userInfo[NotificationUserInfoKey.primaryURL] = url.absoluteString
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            notifierLog.notice("UN.add success category=\(content.categoryIdentifier, privacy: .public) title=\(content.title, privacy: .public)")
        } catch {
            notifierLog.error("UN.add failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func title(for events: [NotificationEvent]) -> String {
        let mergeReady = events.filter { $0.kind == .readyToMerge }.count
        let newReviews = events.filter { $0.kind == .newReviewRequest }.count
        let ciFailed   = events.filter { $0.kind == .ciFailed }.count

        var parts: [String] = []
        if mergeReady > 0 {
            parts.append("\(mergeReady) ready to merge")
        }
        if newReviews > 0 {
            parts.append("\(newReviews) review\(newReviews > 1 ? "s" : "")")
        }
        if ciFailed > 0 {
            parts.append("\(ciFailed) CI failure\(ciFailed > 1 ? "s" : "")")
        }
        return "PRBar: " + parts.joined(separator: ", ")
    }

    static func body(for events: [NotificationEvent]) -> String {
        if events.count == 1, let event = events.first {
            return "\(event.prRepo) #\(event.prNumber) — \(event.prTitle)"
        }
        return events.prefix(3).map {
            "• \($0.prRepo) #\($0.prNumber) — \($0.prTitle)"
        }.joined(separator: "\n")
        + (events.count > 3 ? "\n…and \(events.count - 3) more" : "")
    }

    static func category(for events: [NotificationEvent]) -> String {
        // Pick the most "actionable" category; merge_ready outranks reviews.
        if events.contains(where: { $0.kind == .readyToMerge }) {
            return "merge_ready"
        }
        if events.contains(where: { $0.kind == .newReviewRequest }) {
            return "reviews_ready"
        }
        return "ci_alert"
    }
}
