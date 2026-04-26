import SwiftUI

/// Per-subfolder verdict + summary list, shown in `PRDetailView` when an
/// `AggregatedReview` has more than one subreview. Each row is a
/// disclosure group with the subpath, verdict badge, file count, cost,
/// and tool count; expanding shows that subreview's summary.
struct SubreviewBreakdownView: View {
    let outcomes: [SubreviewOutcome]

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-subfolder breakdown")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                row(outcome)
            }
        }
    }

    @ViewBuilder
    private func row(_ outcome: SubreviewOutcome) -> some View {
        let title = outcome.subpath.isEmpty ? "(repo root)" : outcome.subpath
        let isOpen = expanded.contains(title)

        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { expanded.remove(title) } else { expanded.insert(title) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(.caption, design: .monospaced).bold())
                    verdictBadge(outcome.result.verdict)
                    Spacer()
                    if let cost = outcome.result.costUsd, cost > 0 {
                        Text(String(format: "$%.4f", cost))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(outcome.result.isSubscriptionAuth
                                             ? Color.secondary.opacity(0.5)
                                             : .secondary)
                            .help(outcome.result.isSubscriptionAuth
                                  ? "API-equivalent. Running on subscription — not billed."
                                  : "Cost")
                    }
                    if outcome.result.toolCallCount > 0 {
                        Text("\(outcome.result.toolCallCount) tool\(outcome.result.toolCallCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                MarkdownText(raw: outcome.result.summaryMarkdown)
                    .font(.callout)
                    .padding(.leading, 18)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func verdictBadge(_ v: ReviewVerdict) -> some View {
        let (label, color) = appearance(v)
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func appearance(_ v: ReviewVerdict) -> (String, Color) {
        switch v {
        case .approve:        return ("APPROVE", .green)
        case .comment:        return ("COMMENT", .blue)
        case .requestChanges: return ("CHANGES", .red)
        case .abstain:        return ("ABSTAIN", .gray)
        }
    }
}
