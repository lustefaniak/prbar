import SwiftUI

struct DiagnosticsView: View {
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var cacheBytes: Int64 = 0
    @State private var pruning = false

    var body: some View {
        Form {
            Section {
                ToolAvailabilityView()
            } header: {
                Text("External CLIs")
            } footer: {
                Text("PRBar shells out to these tools. Search order: /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local/bin, /usr/bin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Bare clones") {
                    HStack {
                        Text(formatBytes(cacheBytes))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Refresh") { Task { await refreshCacheSize() } }
                        Button(role: .destructive) {
                            Task { await pruneClones() }
                        } label: {
                            if pruning { ProgressView().controlSize(.small) }
                            else { Text("Prune") }
                        }
                        .disabled(pruning || cacheBytes == 0)
                    }
                }
                .help("Bare clones are reused across reviews. Prune frees disk; the next review will re-clone from scratch.")
            } header: {
                Text("Repository cache")
            } footer: {
                Text("Worktrees are torn down after every review. Stale worktrees from a crashed run are swept on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        guard let mgr = queue.checkoutManager else { cacheBytes = 0; return }
        cacheBytes = await mgr.totalCacheBytes()
    }

    private func pruneClones() async {
        guard let mgr = queue.checkoutManager else { return }
        pruning = true
        defer { pruning = false }
        await mgr.pruneAllBareClones()
        await refreshCacheSize()
    }

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}
