import SwiftUI

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 520, height: 360)
        .scenePadding()
    }
}

#Preview {
    SettingsRoot()
}
