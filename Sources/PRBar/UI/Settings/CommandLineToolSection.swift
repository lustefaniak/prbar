import AppKit
import SwiftUI

/// Settings → General: put `prbar-review` on PATH, and the one line that
/// connects a coding agent to PRBar through it.
struct CommandLineToolSection: View {
    @State private var state = CommandLineTool.state()
    @State private var error: String?

    private static let mcpCommand = "claude mcp add prbar -- prbar-review mcp"

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(statusText)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            HStack {
                switch state {
                case .installed:
                    Button("Remove") { run { try CommandLineTool.uninstall() } }
                case .linkedElsewhere:
                    Button("Link to this copy") { run { try CommandLineTool.install() } }
                case .notInstalled:
                    Button("Install command-line tool") { run { try CommandLineTool.install() } }
                case .otherFile:
                    EmptyView()
                }
            }
            if state == .installed {
                LabeledContent("Claude Code") {
                    HStack(spacing: 6) {
                        Text(Self.mcpCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Command-line tool")
        } footer: {
            Text("Links the prbar-review that ships inside PRBar into ~/.local/bin, so it updates with the app. It talks to this running PRBar: prbar-review status, inbox and history, and prbar-review mcp for coding agents, whose permissions are the agents: block of prbar.yaml.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { state = CommandLineTool.state() }
    }

    private var statusText: String {
        let path = "~/.local/bin/prbar-review"
        switch state {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed at \(path)"
        case .linkedElsewhere(let target): return "\(path) points to another copy: \(target)"
        case .otherFile: return "\(path) is a file PRBar didn't create; remove it to install from here"
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        state = CommandLineTool.state()
    }
}
