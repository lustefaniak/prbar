import AppKit
import SwiftUI

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            ReviewDefaultsSettings()
                .tabItem { Label("Review defaults", systemImage: "slider.horizontal.3") }
            RepositoriesSettings()
                .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            ReviewHistoryView()
                .tabItem { Label("Review History", systemImage: "clock.arrow.circlepath") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 880, idealWidth: 920, maxWidth: .infinity, minHeight: 640, idealHeight: 720, maxHeight: .infinity)
        .scenePadding()
        .background(ResizableWindow())
    }
}

/// SwiftUI's Settings window is fixed-size; the Rules tab needs room for
/// an editor beside its trace. Makes the window resizable and remembers
/// its frame across launches.
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.setFrameAutosaveName("PRBarSettings")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    SettingsRoot()
}
