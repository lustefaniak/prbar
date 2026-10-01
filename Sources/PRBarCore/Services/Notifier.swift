import Foundation
import Observation
#if canImport(OSLog)
import OSLog
#endif

private let notifierLog = Logger(subsystem: "dev.lustefaniak.prbar", category: "notifications")

/// Coalesces NotificationEvents within a settling window and hands them to
/// a `NotificationDeliverer` (macOS notifications in the app). Suppresses delivery
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

    init(deliverer: NotificationDeliverer) {
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

/// How events leave the process. The app delivers macOS notifications
/// (`UNNotificationDeliverer`); tests
/// inject a recording deliverer to assert on what would have been sent.
protocol NotificationDeliverer: Sendable {
    func requestAuthorization() async
    func deliver(_ events: [NotificationEvent]) async
}
