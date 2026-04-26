import SwiftUI

/// Placeholder for the History tab. Phase 2+ will start logging actions
/// (merge, approve, comment, request-changes) into a persisted ActionLog
/// and surface them here.
struct HistoryView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No actions yet")
                .font(.subheadline)
            Text("Merges, approvals, and AI auto-actions you take in PRBar will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
