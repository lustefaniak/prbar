import SwiftUI

/// Placeholder for the History tab. Phase 1d will start logging actions
/// (merge, approve, comment, request-changes) into ActionLog and surface
/// them here.
struct HistoryView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No actions yet")
                .font(.subheadline)
            Text("Approvals, merges, and AI auto-actions will appear here once Phase 1d ships.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
