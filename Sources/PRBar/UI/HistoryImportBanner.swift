import SwiftUI

/// Says that older history is still being copied in (with progress), or
/// that the copy failed and will be retried on the next launch. Shown
/// above the history lists; renders nothing otherwise.
struct HistoryImportBanner: View {
    let status: HistoryImportStatus?
    /// Extra line for views whose numbers depend on the full history.
    var note: String? = nil

    var body: some View {
        switch status {
        case nil:
            EmptyView()
        case .running(let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Importing history from the previous version…")
                        .font(.caption.weight(.medium))
                    Spacer()
                    if progress.total > 0 {
                        Text(verbatim: "\(progress.done.formatted()) of \(progress.total.formatted())")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                }
                Text(note.map { "Older entries appear when it finishes. \($0)" }
                     ?? "Older entries appear when it finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .failed(let message):
            Label {
                Text("Couldn't import older history (\(message)). PRBar will try again on the next launch.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .padding(10)
        }
    }
}
