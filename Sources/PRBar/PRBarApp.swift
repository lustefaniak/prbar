import SwiftUI

@main
struct PRBarApp: App {
    @State private var poller: PRPoller
    @State private var notifier: Notifier
    @State private var queue: ReviewQueueWorker
    @State private var diffStore: DiffStore

    init() {
        let n = Notifier()
        let p = PRPoller.live()
        let q = ReviewQueueWorker.live()
        let d = DiffStore.sharing(q)
        p.notifier = n
        _notifier = State(initialValue: n)
        _poller = State(initialValue: p)
        _queue = State(initialValue: q)
        _diffStore = State(initialValue: d)
        Task { await n.requestAuthorization() }
    }

    var body: some Scene {
        MenuBarExtra("PRBar", systemImage: "text.bubble") {
            PopoverView()
                .environment(poller)
                .environment(notifier)
                .environment(queue)
                .environment(diffStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot()
        }
    }
}
