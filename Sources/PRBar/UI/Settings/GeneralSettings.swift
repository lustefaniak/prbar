import SwiftUI

struct GeneralSettings: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(enabled: newValue)
                    }
                    .task {
                        // Reflect the actual system state when the pane opens.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            } header: {
                Text("Startup")
            } footer: {
                Text("Registered via SMAppService. Removing the app from /Applications can break this — re-toggle if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    GeneralSettings()
        .frame(width: 520, height: 360)
}
