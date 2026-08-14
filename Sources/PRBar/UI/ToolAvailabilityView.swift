import SwiftUI

struct ToolAvailabilityView: View {
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
                HStack(spacing: 8) {
                    Image(systemName: result.available ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.available ? .green : .red)
                    Text(result.tool)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(result.statusText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(result.helpText)
                }
            }
        }
        .task { probe() }
    }

    private func probe() {
        isProbing = true
        let names = tools
        Task {
            let next = await Task.detached(priority: .userInitiated) {
                names.map { ToolProbe.probe($0) }
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
        if let f = failure { return "--version exited \(f.exitCode)" }
        if path != nil { return "no --version output" }
        return "not found"
    }

    var helpText: String {
        guard let p = path else {
            return "Searched: /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.claude/local/bin, /usr/bin"
        }
        guard let f = failure else { return p }
        return [p, f.stderrLine].compactMap { $0 }.joined(separator: "\n")
    }
}
