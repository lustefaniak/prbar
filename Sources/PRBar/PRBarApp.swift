import SwiftUI

@main
struct PRBarApp: App {
    @State private var poller = PRPoller.live()

    var body: some Scene {
        MenuBarExtra("PRBar", systemImage: "text.bubble") {
            PopoverView()
                .environment(poller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot()
        }
    }
}
