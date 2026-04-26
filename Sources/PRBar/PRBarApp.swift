import SwiftUI

@main
struct PRBarApp: App {
    @State private var poller: PRPoller
    @State private var notifier: Notifier

    init() {
        let n = Notifier()
        let p = PRPoller.live()
        p.notifier = n
        _notifier = State(initialValue: n)
        _poller = State(initialValue: p)
        Task { await n.requestAuthorization() }
    }

    var body: some Scene {
        MenuBarExtra("PRBar", systemImage: "text.bubble") {
            PopoverView()
                .environment(poller)
                .environment(notifier)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot()
        }
    }
}
