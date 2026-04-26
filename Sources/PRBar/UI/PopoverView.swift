import SwiftUI

struct PopoverView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("PRBar")
                    .font(.headline)
                Spacer()
                Text("Phase 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }

            Divider()

            ToolAvailabilityView()

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
                .task {
                    launchAtLogin = LaunchAtLogin.isEnabled
                }

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

#Preview {
    PopoverView()
}
