import SwiftUI

/// Wraps `PRDetailView` for the standalone full-size `Window` scene.
/// The popover stays the right tool for triage at-a-glance; this window
/// handles large diffs / long annotations comfortably without fighting
/// the 560×640 menu-bar popover frame.
///
/// Resolves the PR by `nodeId` against `PRPoller.prs` so the window
/// stays live as the inbox refreshes — if the PR drops out (merged,
/// closed, or filtered) we fall through to a graceful empty state
/// rather than crashing on a stale snapshot.
struct PRDetailWindowView: View {
    let nodeId: String

    @Environment(PRPoller.self) private var poller
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let pr = poller.prs.first(where: { $0.nodeId == nodeId }) {
                PRDetailView(
                    pr: pr,
                    onBack: { dismissWindow(id: PRDetailWindowID.id) },
                    inWindow: true
                )
                .padding(16)
            } else {
                empty
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle(navTitle)
    }

    private var navTitle: String {
        guard let pr = poller.prs.first(where: { $0.nodeId == nodeId }) else {
            return "PR Detail"
        }
        return "\(pr.nameWithOwner) #\(pr.numberString) — \(pr.title)"
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.diamond")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("PR no longer in inbox")
                .font(.headline)
            Text("It may have been merged, closed, or filtered out by a repo rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismissWindow(id: PRDetailWindowID.id) }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum PRDetailWindowID {
    static let id = "pr-detail"
}
