import AppKit
import SwiftUI

/// Where review settings live and whether the file is healthy. Settings
/// edits write `prbar.yaml`; hand edits to it show up here within a couple
/// of seconds, and so does a parse error when one breaks it.
struct ConfigFileSection: View {
    @Environment(RepoConfigStore.self) private var store

    var body: some View {
        Section {
            LabeledContent("File") {
                Text(displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Open") { NSWorkspace.shared.open(store.fileURL) }
                    .disabled(!fileExists)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                .disabled(!fileExists)
            }
            if let issue = store.loadIssue {
                Label(issue, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(store.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Configuration file")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: store.fileURL.path)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = store.fileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var footer: String {
        var text = "Review defaults, repository rules and the default provider, model and effort are stored in this file, which the prbar-review CLI reads too. Edits made here rewrite it; edits made to the file are picked up automatically. The file is created on the first change."
        if store.migratedFromLegacy {
            text += " Your earlier settings were copied into it on this launch."
        }
        return text
    }
}
