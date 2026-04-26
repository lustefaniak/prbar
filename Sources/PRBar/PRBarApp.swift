import SwiftUI

@main
struct PRBarApp: App {
    var body: some Scene {
        MenuBarExtra("PRBar", systemImage: "text.bubble") {
            PopoverView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot()
        }
    }
}
