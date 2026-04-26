import SwiftUI

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            RepositoriesSettings()
                .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 700, height: 520)
        .scenePadding()
    }
}

#Preview {
    SettingsRoot()
}
