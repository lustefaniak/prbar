import SwiftUI

/// Renders a `ReviewTrace` as an indented, scrollable timeline. Each row
/// is one event from the AI's run: assistant text, tool call, tool
/// result, rate-limit ping, or final result. Tool-call rows can expand
/// to show their full JSON input + result preview.
///
/// Per `PRDetailView` design, this lives inside a disclosure group so
/// users only pay the eye-cost of reading it when they explicitly ask.
struct ReviewTraceView: View {
    let trace: ReviewTrace

    @State private var expanded: Set<Int> = []

    var body: some View {
        if trace.isEmpty {
            Text("No activity captured for this review.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(trace.events.enumerated()), id: \.offset) { idx, event in
                    row(idx: idx, event: event)
                }
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, event: ReviewTraceEvent) -> some View {
        switch event {
        case .assistantText(let text):
            assistantRow(text: text)
        case .toolCall(let name, let summary, let json):
            toolCallRow(idx: idx, name: name, summary: summary, json: json)
        case .toolResult(let toolName, let preview, let ok):
            toolResultRow(idx: idx, toolName: toolName, preview: preview, ok: ok)
        case .rateLimit(let status):
            statusRow(icon: "hourglass", color: .yellow,
                      label: "rate limit: \(status)")
        case .finalResult(let cost, let durationMs, let verdict):
            finalResultRow(cost: cost, durationMs: durationMs, verdict: verdict)
        }
    }

    private func assistantRow(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.purple)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolCallRow(idx: Int, name: String, summary: String, json: String) -> some View {
        let isOpen = expanded.contains(idx)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isOpen { expanded.remove(idx) } else { expanded.insert(idx) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: iconForTool(name))
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .frame(width: 14)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isOpen, !json.isEmpty {
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 20)
                    .textSelection(.enabled)
            }
        }
    }

    private func toolResultRow(idx: Int, toolName: String?, preview: String, ok: Bool) -> some View {
        let isOpen = expanded.contains(idx)
        let label = (toolName.map { "\($0) → " } ?? "→ ") + (ok ? "ok" : "error")
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isOpen { expanded.remove(idx) } else { expanded.insert(idx) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: ok ? "arrow.uturn.backward" : "xmark.octagon")
                        .font(.caption2)
                        .foregroundStyle(ok ? .green : .red)
                        .frame(width: 14)
                    Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !preview.isEmpty {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(preview.isEmpty)

            if isOpen, !preview.isEmpty {
                Text(preview)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 20)
                    .textSelection(.enabled)
                    .lineLimit(20)
            }
        }
    }

    private func statusRow(icon: String, color: Color, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func finalResultRow(cost: Double?, durationMs: Int?, verdict: String?) -> some View {
        var bits: [String] = []
        if let v = verdict { bits.append("verdict=\(v)") }
        if let c = cost { bits.append(String(format: "$%.4f", c)) }
        if let ms = durationMs { bits.append(String(format: "%.1fs", Double(ms) / 1000.0)) }
        let label = "result " + (bits.isEmpty ? "" : bits.joined(separator: " · "))
        return statusRow(icon: "checkmark.seal", color: .green, label: label)
    }

    private func iconForTool(_ name: String) -> String {
        switch name {
        case "Read", "Open": return "doc.text"
        case "Glob": return "rectangle.stack"
        case "Grep": return "magnifyingglass"
        case "WebFetch": return "globe"
        case "WebSearch": return "globe.badge.chevron.backward"
        default: return "wrench.and.screwdriver"
        }
    }
}
