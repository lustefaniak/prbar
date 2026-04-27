import Foundation

/// Pure function: maps a list of annotations onto each `Hunk`'s lines so
/// the diff renderer can draw a severity bar + body bubble at the right
/// spot. Annotations are addressed by *new-side* (post-image) line number,
/// matching what the AI sees when reading the file at HEAD.
///
/// Output is keyed by (filePath, hunkIndex, lineIndex-within-hunk) →
/// list of annotations whose [lineStart, lineEnd] range covers that line.
/// Removed lines never receive annotations (they don't exist in the new
/// file). Context and added lines do.
enum DiffAnnotationCorrelator {
    struct Hit: Sendable, Hashable {
        /// Position of the matched hunk *within its file's hunk list* (not
        /// the global flat list passed to `correlate`). DiffView iterates
        /// per-file when rendering, so the per-file ordinal is what the
        /// renderer can match against. Using a global index caused
        /// annotations to leak across hunks: a hit for hunk 0 matched
        /// every other hunk whose local index also happened to be 0.
        let hunkIndex: Int
        let lineIndex: Int          // index into Hunk.lines
        let annotation: DiffAnnotation
    }

    /// Assigns each annotation to every hunk-line it covers. An annotation
    /// spanning lines 10-20 hits all `.context`/`.added` lines whose new
    /// line number falls in that range.
    static func correlate(
        hunks: [Hunk],
        annotations: [DiffAnnotation]
    ) -> [String: [Hit]] {
        var byFile: [String: [Hit]] = [:]
        var perFileOrdinal: [String: Int] = [:]

        let annotationsByFile = Dictionary(grouping: annotations, by: \.path)

        for hunk in hunks {
            let hunkIndex = perFileOrdinal[hunk.filePath, default: 0]
            perFileOrdinal[hunk.filePath] = hunkIndex + 1

            guard let fileAnnotations = annotationsByFile[hunk.filePath],
                  !fileAnnotations.isEmpty else { continue }

            var newLineNo = hunk.newStart
            for (lineIndex, line) in hunk.lines.enumerated() {
                switch line {
                case .removed:
                    continue   // no new-side line number; advance nothing.
                case .context, .added:
                    let n = newLineNo
                    newLineNo += 1
                    for ann in fileAnnotations where n >= ann.lineStart && n <= ann.lineEnd {
                        byFile[hunk.filePath, default: []].append(
                            Hit(hunkIndex: hunkIndex, lineIndex: lineIndex, annotation: ann)
                        )
                    }
                }
            }
        }

        return byFile
    }

    /// Convenience: new-side line number for each line of a hunk. Returns
    /// nil at indices where the line is `.removed` (no new-side number).
    static func newLineNumbers(for hunk: Hunk) -> [Int?] {
        var out: [Int?] = []
        out.reserveCapacity(hunk.lines.count)
        var n = hunk.newStart
        for line in hunk.lines {
            switch line {
            case .removed:
                out.append(nil)
            case .context, .added:
                out.append(n)
                n += 1
            }
        }
        return out
    }

    /// Convenience: old-side line number for each line of a hunk. Returns
    /// nil for `.added` lines.
    static func oldLineNumbers(for hunk: Hunk) -> [Int?] {
        var out: [Int?] = []
        out.reserveCapacity(hunk.lines.count)
        var n = hunk.oldStart
        for line in hunk.lines {
            switch line {
            case .added:
                out.append(nil)
            case .context, .removed:
                out.append(n)
                n += 1
            }
        }
        return out
    }
}
