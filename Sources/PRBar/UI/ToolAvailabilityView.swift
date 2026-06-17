import SwiftUI

struct ToolAvailabilityView: View {
    @Environment(RepoConfigStore.self) private var repoConfigs
    @AppStorage("defaultProviderId") private var defaultProviderRaw = ProviderID.claude.rawValue
    @AppStorage(ProviderRelevance.suppressionStorageKey)
        private var suppressUnusedProviderWarnings = false

    @State private var results: [ToolProbeResult] = []
    @State private var isProbing = false

    private let tools = ["gh", "claude", "codex", "git"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tool availability")
                    .font(.subheadline.bold())
                Spacer()
                Button(action: probe) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isProbing)
            }

            if results.isEmpty && isProbing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            ForEach(results) { result in
                row(for: result)
            }
        }
        .task { probe() }
    }

    @ViewBuilder
    private func row(for result: ToolProbeResult) -> some View {
        let suppressed = isSuppressed(result)
        HStack(spacing: 8) {
            Image(systemName: iconName(available: result.available, suppressed: suppressed))
                .foregroundStyle(iconStyle(available: result.available, suppressed: suppressed))
            Text(result.tool)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Text(suppressed ? "not used" : result.statusText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(suppressed ? Self.suppressedHelp : result.helpText)
        }
    }

    /// A missing AI provider the user has configured away from: keep the
    /// row for completeness but drop the red "not found" warning.
    private func isSuppressed(_ result: ToolProbeResult) -> Bool {
        guard !result.available, let provider = ProviderID(rawValue: result.tool) else {
            return false
        }
        return !relevantProviders.contains(provider)
    }

    private var relevantProviders: Set<ProviderID> {
        ProviderRelevance.relevantProviders(
            suppressionEnabled: suppressUnusedProviderWarnings,
            defaultProviderRaw: defaultProviderRaw,
            repoOverrides: repoConfigs.providerOverrides
        )
    }

    private func iconName(available: Bool, suppressed: Bool) -> String {
        if suppressed { return "minus.circle" }
        return available ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func iconStyle(available: Bool, suppressed: Bool) -> AnyShapeStyle {
        if suppressed { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(available ? Color.green : Color.red)
    }

    private static let suppressedHelp =
        "PRBar isn't configured to use this provider, so its absence isn't flagged."

    private func probe() {
        isProbing = true
        let names = tools
        Task {
            let next = await Task.detached(priority: .userInitiated) {
                names.map(ToolProbe.probe)
            }.value
            await MainActor.run {
                self.results = next
                self.isProbing = false
            }
        }
    }
}

private extension ToolProbeResult {
    var statusText: String {
        if let v = version { return v }
        if path != nil { return "(no --version)" }
        return "not found"
    }

    var helpText: String {
        if let p = path { return p }
        return "Searched: /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local/bin, /usr/bin"
    }
}
