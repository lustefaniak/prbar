import SwiftUI

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            RepositoriesSettings()
                .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }
            ReviewHistoryView()
                .tabItem { Label("Review History", systemImage: "clock.arrow.circlepath") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 880, idealWidth: 920, minHeight: 640, idealHeight: 720)
        .scenePadding()
    }
}

#Preview {
    SettingsRoot()
}
