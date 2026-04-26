import SwiftUI

struct GeneralSettings: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sequentialFocusMode") private var sequentialFocusMode = true
    @AppStorage("badgeShowReadyToMerge")    private var badgeReadyToMerge    = true
    @AppStorage("badgeShowReviewRequested") private var badgeReviewRequested = true
    @AppStorage("badgeShowCIFailed")        private var badgeCIFailed        = true

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

            Section {
                Toggle("Advance to next ready PR after action", isOn: $sequentialFocusMode)
            } header: {
                Text("Review focus")
            } footer: {
                Text("After Approve / Comment / Request changes, the detail pane jumps to the next ready review-requested PR instead of returning to the list. Reduces context switching when working through a batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ready-to-merge PRs",   isOn: $badgeReadyToMerge)
                Toggle("Pending review requests", isOn: $badgeReviewRequested)
                Toggle("Authored PRs with red CI", isOn: $badgeCIFailed)
            } header: {
                Text("Menu bar badge")
            } footer: {
                Text("Show a count next to the menu-bar icon when there's something actionable. Toggle each source independently; turn them all off to hide the badge entirely.")
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
