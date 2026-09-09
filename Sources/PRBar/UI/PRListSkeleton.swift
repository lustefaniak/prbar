import SwiftUI

/// Placeholder rows shown while the first poll is in flight, in place of a
/// bare "Fetching…" line.
///
/// Mirrors `PRRowView`'s layout — leading role badge, title over a
/// monospaced meta line, trailing spacer — so the list keeps its shape when
/// the real rows arrive instead of reflowing. The bars are redacted `Text`
/// rather than sized rectangles to inherit the real row's font metrics;
/// widths come from `containerRelativeFrame` so they track the list whether
/// it's rendering in the 560pt popover or the wider detail window.
struct PRListSkeleton: View {
    /// Fraction of the list width each title bar spans, varied so the block
    /// doesn't read as a table.
    private static let titleWidths: [CGFloat] = [0.68, 0.44, 0.8, 0.52]

    /// Longer than any bar, so a bar always fills its frame rather than
    /// shrinking to the filler's intrinsic width.
    private static let filler = String(repeating: "x", count: 120)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.titleWidths, id: \.self) { titleWidth in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        bar(width: titleWidth)
                        bar(width: 0.3)
                            .font(.system(.caption, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .opacity(dimmed ? 0.5 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: dimmed
        )
        .onAppear { dimmed = true }
        .accessibilityLabel("Loading pull requests")
    }

    private func bar(width: CGFloat) -> some View {
        Text(verbatim: Self.filler)
            .lineLimit(1)
            .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                length * width
            }
    }
}
