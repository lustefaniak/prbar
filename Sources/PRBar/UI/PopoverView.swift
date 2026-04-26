import SwiftUI

struct PopoverView: View {
    @Environment(PRPoller.self) private var poller

    @State private var toolResults: [ToolProbeResult] = []
    private let probedTools = ["gh", "claude", "git"]

    private var missingTools: [ToolProbeResult] {
        toolResults.filter { !$0.available }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !missingTools.isEmpty {
                missingToolsBanner
            }

            inboxSection

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 460)
        .task { await probeTools() }
        .task { poller.pollNow() }   // refresh whenever the popover opens
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("PRBar")
                .font(.headline)
            Spacer()
            Text("Phase 1b")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
        }
    }

    private var missingToolsBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing CLIs: \(missingTools.map(\.tool).joined(separator: ", "))")
                    .font(.caption)
                Text("Install them and refresh — see Diagnostics in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inbox")
                    .font(.subheadline.bold())
                if !poller.prs.isEmpty {
                    Text("\(poller.prs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let lastFetchedAt = poller.lastFetchedAt {
                    Text(lastFetchedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Last successful fetch")
                }
                Button(action: { poller.pollNow() }) {
                    if poller.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(poller.isFetching)
                .help("Refresh now")
            }

            if let error = poller.lastError, poller.prs.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else if poller.prs.isEmpty {
                Text(poller.isFetching ? "Fetching…" : "No PRs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(poller.prs.prefix(10)) { pr in
                    PRRowSummary(pr: pr)
                }
                if poller.prs.count > 10 {
                    Text("…and \(poller.prs.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = poller.lastError {
                    Text("Last fetch failed: \(error)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func probeTools() async {
        let names = probedTools
        let probed = await Task.detached(priority: .userInitiated) {
            names.map(ToolProbe.probe)
        }.value
        self.toolResults = probed
    }
}

private struct PRRowSummary: View {
    let pr: InboxPR

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            roleBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(pr.nameWithOwner) #\(pr.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if pr.isDraft {
                        Text("draft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    rollupBadge
                    reviewBadge
                }
            }
            Spacer()
        }
        .help("\(pr.nameWithOwner) #\(pr.number) — \(pr.title)\nmergeable: \(pr.mergeStateStatus); review: \(pr.reviewDecision ?? "—")")
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch pr.role {
        case .authored:
            Image(systemName: "person.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .reviewRequested:
            Image(systemName: "eye.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .both:
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.purple)
                .font(.caption)
        case .other:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var rollupBadge: some View {
        switch pr.checkRollupState {
        case "SUCCESS":
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "FAILURE", "ERROR":
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "PENDING", "EXPECTED":
            Image(systemName: "circle.dotted")
                .foregroundStyle(.yellow)
                .font(.caption2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch pr.reviewDecision {
        case "APPROVED":
            Image(systemName: "hand.thumbsup.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "CHANGES_REQUESTED":
            Image(systemName: "hand.thumbsdown.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "REVIEW_REQUIRED":
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption2)
        default:
            EmptyView()
        }
    }
}

#Preview {
    PopoverView()
        .environment(PRPoller(fetcher: { [] }))
}
