import SwiftUI

struct GeneralSettings: View {
    @Environment(ReviewQueueWorker.self) private var queue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sequentialFocusMode") private var sequentialFocusMode = true
    @AppStorage("badgeShowReadyToMerge")    private var badgeReadyToMerge    = true
    @AppStorage("badgeShowReviewRequested") private var badgeReviewRequested = true
    @AppStorage("badgeShowCIFailed")        private var badgeCIFailed        = true
    @AppStorage("defaultProviderId")        private var defaultProviderRaw   = ProviderID.claude.rawValue

    /// Probed at view-load. Drives "(not installed)" annotations in the
    /// provider picker so users don't pick a backend they don't have.
    @State private var providerAvailability: [ProviderID: Bool] = [:]

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
                Picker("Default review provider", selection: providerBinding) {
                    ForEach(ProviderID.allCases, id: \.self) { p in
                        Text(label(for: p)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("AI provider")
            } footer: {
                Text("App-wide default. A repo's `providerOverride` (Settings → Repositories) wins over this; PRDetailView's \"Re-run with…\" menu can override either for a single run. If a chosen provider isn't installed the review fails with a clear message — see Diagnostics for current status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task { await probeProviderAvailability() }

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

    /// Picker label for one provider — adds "(not installed)" when the
    /// CLI binary isn't on PATH so the user makes an informed choice.
    private func label(for p: ProviderID) -> String {
        if providerAvailability[p] == false {
            return "\(p.displayName) (not installed)"
        }
        return p.displayName
    }

    /// Probe both binaries off the main thread; populate the @State map
    /// so the picker reactively updates.
    private func probeProviderAvailability() async {
        let probed = await Task.detached(priority: .userInitiated) {
            ProviderID.allCases.reduce(into: [ProviderID: Bool]()) { acc, p in
                acc[p] = ExecutableResolver.find(p.binaryName) != nil
            }
        }.value
        await MainActor.run {
            self.providerAvailability = probed
        }
    }

    /// Bridge `defaultProviderRaw` (String for AppStorage) ↔ `ProviderID`.
    /// Setter also pushes the value into the live `ReviewQueueWorker` so
    /// the change applies on the next enqueue without a restart.
    private var providerBinding: Binding<ProviderID> {
        Binding(
            get: { ProviderID(rawValue: defaultProviderRaw) ?? .claude },
            set: { newValue in
                defaultProviderRaw = newValue.rawValue
                queue.defaultProviderId = newValue
            }
        )
    }
}

#Preview {
    GeneralSettings()
        .frame(width: 520, height: 360)
}
