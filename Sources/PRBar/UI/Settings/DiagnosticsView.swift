import SwiftUI

struct DiagnosticsView: View {
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
        }
        .formStyle(.grouped)
    }
}

#Preview {
    DiagnosticsView()
        .frame(width: 520, height: 360)
}
