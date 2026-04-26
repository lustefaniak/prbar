import SwiftUI

/// Pure-Swift renderer for a unified diff (already parsed into [Hunk]).
/// Lines are colored by kind (added/removed/context) and the leading edge
/// of any line covered by an AI annotation gets a severity-colored bar
/// that expands to the annotation body when clicked.
///
/// No external syntax-highlighter; SF Mono 12pt for the line content.
/// File groups are collapsible; subpath filter chips at the top let the
/// user narrow to one subreview's files when viewing a multi-root PR.
struct DiffView: View {
    let hunks: [Hunk]
    let annotations: [DiffAnnotation]

    /// Optional subpath filter chips. Empty → no chips shown. Each entry is
    /// the subpath of one subreview (e.g. "kernel-billing").
    let subpaths: [String]

    @State private var selectedSubpath: String? = nil
    @State private var collapsedFiles: Set<String> = []
    @State private var expandedAnnotationKeys: Set<String> = []

    init(
        hunks: [Hunk],
        annotations: [DiffAnnotation],
        subpaths: [String] = []
    ) {
        self.hunks = hunks
        self.annotations = annotations
        self.subpaths = subpaths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !subpaths.isEmpty {
                subpathFilterRow
            }
            if filteredHunks.isEmpty {
                Text("No diff to show.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fileGroups, id: \.path) { group in
                    fileSection(path: group.path, hunks: group.hunks)
                }
            }
        }
    }

    // MARK: - filtering

    private var filteredHunks: [Hunk] {
        guard let sel = selectedSubpath else { return hunks }
        if sel.isEmpty {
            // "Root" filter — anything not under a chip-named subpath.
            return hunks.filter { hunk in
                !subpaths.contains(where: { !$0.isEmpty && hunk.filePath.hasPrefix("\($0)/") })
            }
        }
        return hunks.filter { $0.filePath.hasPrefix("\(sel)/") || $0.filePath == sel }
    }

    private var fileGroups: [(path: String, hunks: [Hunk])] {
        var seen: [String] = []
        var byPath: [String: [Hunk]] = [:]
        for h in filteredHunks {
            if byPath[h.filePath] == nil { seen.append(h.filePath) }
            byPath[h.filePath, default: []].append(h)
        }
        return seen.map { ($0, byPath[$0] ?? []) }
    }

    private var correlatedHits: [String: [DiffAnnotationCorrelator.Hit]] {
        DiffAnnotationCorrelator.correlate(hunks: filteredHunks, annotations: annotations)
    }

    // MARK: - subviews

    private var subpathFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", selected: selectedSubpath == nil) {
                    selectedSubpath = nil
                }
                ForEach(subpaths, id: \.self) { sp in
                    chip(
                        label: sp.isEmpty ? "(root)" : sp,
                        selected: selectedSubpath == sp
                    ) {
                        selectedSubpath = (selectedSubpath == sp) ? nil : sp
                    }
                }
            }
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : .secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fileSection(path: String, hunks: [Hunk]) -> some View {
        let collapsed = collapsedFiles.contains(path)
        let added = hunks.flatMap(\.lines).filter { if case .added = $0 { return true } else { return false } }.count
        let removed = hunks.flatMap(\.lines).filter { if case .removed = $0 { return true } else { return false } }.count

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if collapsed { collapsedFiles.remove(path) } else { collapsedFiles.insert(path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced).bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("+\(added)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("-\(removed)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.secondary.opacity(0.08))
            }
            .buttonStyle(.plain)

            if !collapsed {
                ForEach(Array(hunks.enumerated()), id: \.offset) { idx, hunk in
                    hunkBlock(hunk, hunkIndexInFile: idx, fileHits: correlatedHits[path] ?? [])
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(.secondary.opacity(0.2))
        )
    }

    @ViewBuilder
    private func hunkBlock(
        _ hunk: Hunk,
        hunkIndexInFile: Int,
        fileHits: [DiffAnnotationCorrelator.Hit]
    ) -> some View {
        let newLines = DiffAnnotationCorrelator.newLineNumbers(for: hunk)
        let oldLines = DiffAnnotationCorrelator.oldLineNumbers(for: hunk)
        // We index hits by their original (whole-list) hunkIndex, not the
        // per-file one — find the matching subset by line.
        let hitsByLine: [Int: [DiffAnnotationCorrelator.Hit]] = Dictionary(
            grouping: fileHits.filter { hit in
                // Match the *line content* via filePath + lineIndex range —
                // the renderer only needs to know "is there an annotation
                // on this hunk-relative line index". We just match on
                // line index (same hunk in filtered list = same indices).
                hit.lineIndex < hunk.lines.count
            },
            by: \.lineIndex
        )

        VStack(alignment: .leading, spacing: 0) {
            // Hunk header line.
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.06))

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIdx, line in
                let hitsHere = hitsByLine[lineIdx] ?? []
                diffLineRow(
                    line: line,
                    oldLine: oldLines[lineIdx],
                    newLine: newLines[lineIdx],
                    hits: hitsHere,
                    keyPrefix: "\(hunk.filePath)#\(hunkIndexInFile).\(lineIdx)"
                )
            }
        }
    }

    @ViewBuilder
    private func diffLineRow(
        line: DiffLine,
        oldLine: Int?,
        newLine: Int?,
        hits: [DiffAnnotationCorrelator.Hit],
        keyPrefix: String
    ) -> some View {
        let bg: Color = {
            switch line {
            case .added:   return .green.opacity(0.10)
            case .removed: return .red.opacity(0.10)
            case .context: return .clear
            }
        }()
        let prefixColor: Color = {
            switch line {
            case .added:   return .green
            case .removed: return .red
            case .context: return .secondary
            }
        }()

        // Worst severity wins for the bar color when multiple annotations
        // overlap a single line.
        let severity = hits.map(\.annotation.severity).max(by: { $0.rank < $1.rank })

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(severity.map(severityColor) ?? .clear)
                    .frame(width: 3)

                Text(formatLineNumber(oldLine))
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                Text(formatLineNumber(newLine))
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)

                Text(String(line.prefix))
                    .foregroundStyle(prefixColor)
                Text(line.content)
                    .foregroundStyle(prefixColor.opacity(line.isContext ? 0.7 : 1))
                Spacer(minLength: 0)
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.vertical, 1)
            .background(bg)
            .contentShape(Rectangle())
            .onTapGesture {
                if !hits.isEmpty {
                    toggleExpanded(keyPrefix)
                }
            }

            if !hits.isEmpty && expandedAnnotationKeys.contains(keyPrefix) {
                annotationBubble(hits: hits)
            }
        }
    }

    @ViewBuilder
    private func annotationBubble(hits: [DiffAnnotationCorrelator.Hit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                let ann = hit.annotation
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(severityColor(ann.severity))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ann.severity.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(severityColor(ann.severity))
                        Text(ann.body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08))
    }

    private func toggleExpanded(_ key: String) {
        if expandedAnnotationKeys.contains(key) {
            expandedAnnotationKeys.remove(key)
        } else {
            expandedAnnotationKeys.insert(key)
        }
    }

    private func formatLineNumber(_ n: Int?) -> String {
        n.map { String($0) } ?? ""
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

private extension DiffLine {
    var isContext: Bool {
        if case .context = self { return true }
        return false
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
