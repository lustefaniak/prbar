import SwiftUI

struct PopoverView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    @State private var prs: [InboxPR] = []
    @State private var fetchError: String?
    @State private var isFetching = false
    @State private var lastFetchedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            ToolAvailabilityView()

            Divider()

            inboxSection

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
                .task { launchAtLogin = LaunchAtLogin.isEnabled }

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("PRBar")
                .font(.headline)
            Spacer()
            Text("Phase 1a")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inbox")
                    .font(.subheadline.bold())
                if !prs.isEmpty {
                    Text("\(prs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let lastFetchedAt {
                    Text(lastFetchedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: fetch) {
                    if isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isFetching)
            }

            if let fetchError {
                Text(fetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else if prs.isEmpty {
                Text(isFetching ? "Fetching…" : "No PRs (or never fetched). Click ⟳.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prs.prefix(10)) { pr in
                    PRRowSummary(pr: pr)
                }
                if prs.count > 10 {
                    Text("…and \(prs.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fetch() {
        isFetching = true
        fetchError = nil
        Task {
            do {
                let client = try GHClient()
                let fetched = try await client.fetchInbox()
                self.prs = fetched
                self.lastFetchedAt = Date()
            } catch {
                self.fetchError = error.localizedDescription
            }
            self.isFetching = false
        }
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
}
