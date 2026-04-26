import SwiftUI

/// Compact glanceable list of all annotations under the AI verdict —
/// one row per annotation: severity dot + path:line + title. Click a
/// row to scroll the inline diff to that hunk and expand its bubble
/// (still TODO; for now click reveals the body inline).
///
/// Sorted worst-severity-first so the things that block merge surface
/// at the top.
struct AnnotationsSummaryView: View {
    let annotations: [DiffAnnotation]

    /// Called when the user wants to jump from this list into the actual
    /// diff. The parent (`PRDetailView`) wires this to set its
    /// `focusedDiffKey` and scroll the inline `DiffView` to the matching
    /// line. nil = "navigation disabled" (e.g. detail view doesn't have a
    /// diff loaded yet).
    var onLocate: ((DiffAnnotation) -> Void)?

    @State private var expanded: Set<Int> = []

    init(annotations: [DiffAnnotation], onLocate: ((DiffAnnotation) -> Void)? = nil) {
        self.annotations = annotations
        self.onLocate = onLocate
    }

    var body: some View {
        if annotations.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Annotations")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(Array(sorted.enumerated()), id: \.offset) { idx, annotation in
                    row(idx: idx, annotation: annotation)
                }
            }
        }
    }

    private var sorted: [DiffAnnotation] {
        annotations.sorted { lhs, rhs in
            if lhs.severity.rank != rhs.severity.rank {
                return lhs.severity.rank > rhs.severity.rank
            }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.lineStart < rhs.lineStart
        }
    }

    @ViewBuilder
    private func row(idx: Int, annotation: DiffAnnotation) -> some View {
        let isOpen = expanded.contains(idx)
        VStack(alignment: .leading, spacing: 2) {
            // Title gets the full row width — long monorepo paths
            // (e.g. `kernel-billing/internal/foo/bar.go:123-127`) used
            // to push the title into ellipsis. Now the path + locate
            // button sit on a second line under the title.
            Button {
                if isOpen { expanded.remove(idx) } else { expanded.insert(idx) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(severityColor(annotation.severity))
                        .frame(width: 8, height: 8)
                    Text(annotation.displayTitle)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let onLocate {
                    Button {
                        onLocate(annotation)
                    } label: {
                        HStack(spacing: 2) {
                            Text(locationLabel(annotation))
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.down.right.square")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Locate in diff")
                } else {
                    Text(locationLabel(annotation))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.leading, 14) // Indent under the severity dot.

            if isOpen {
                Text(annotation.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 14)
            }
        }
    }

    private func locationLabel(_ a: DiffAnnotation) -> String {
        let lines = a.lineStart == a.lineEnd
            ? "\(a.lineStart)"
            : "\(a.lineStart)–\(a.lineEnd)"
        return "\(a.path):\(lines)"
    }

    private func severityColor(_ s: AnnotationSeverity) -> Color {
        switch s {
        case .info:       return .gray
        case .suggestion: return .blue
        case .warning:    return .orange
        case .blocker:    return .red
        }
    }
}

private extension AnnotationSeverity {
    var rank: Int {
        switch self {
        case .info:       return 0
        case .suggestion: return 1
        case .warning:    return 2
        case .blocker:    return 3
        }
    }
}
