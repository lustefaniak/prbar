import SwiftUI
import SwiftData
import AppKit

/// Chronological list of PR actions taken through PRBar — manual review
/// posts, merges, auto-approve fires (success and failure both shown).
/// Backed by SwiftData via `ActionLogStore`; entries persist across
/// relaunches and survive the underlying PR leaving the inbox.
struct HistoryView: View {
    @Environment(ActionLogStore.self) private var store

    var body: some View {
        let entries = store.fetchAll(limit: 200)
        let groups = Self.groupByDay(entries)

        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.day) { group in
                        DayHeader(date: group.day)
                        ForEach(group.entries, id: \.id) { entry in
                            HistoryRow(entry: entry, onOpen: { open(entry) })
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
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

    private func open(_ entry: ActionLogEntry) {
        let url = URL(string: "https://github.com/\(entry.owner)/\(entry.repo)/pull/\(entry.prNumber)")!
        NSWorkspace.shared.open(url)
    }

    struct DayGroup { let day: Date; let entries: [ActionLogEntry] }

    static func groupByDay(_ entries: [ActionLogEntry]) -> [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: entries) { cal.startOfDay(for: $0.timestamp) }
        return dict.keys.sorted(by: >).map { day in
            DayGroup(day: day, entries: dict[day]!)
        }
    }
}

private struct DayHeader: View {
    let date: Date

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        Text(Self.formatter.string(from: date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct HistoryRow: View {
    let entry: ActionLogEntry
    var onOpen: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.kind.symbolName)
                    .foregroundStyle(symbolColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.kind.displayName)
                            .font(.callout.weight(.medium))
                        if entry.outcome == .failure {
                            Text("failed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12), in: .capsule)
                        }
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(entry.nameWithOwner) #\(entry.prNumber)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.prTitle)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let err = entry.errorMessage, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if let detail = entry.detail, !detail.isEmpty,
                              entry.kind != .merge {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let cost = entry.costUsd, cost > 0 {
                        Text(String(format: "$%.2f", cost))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbolColor: Color {
        switch entry.kind {
        case .merge:          .purple
        case .approve, .autoApprove: .green
        case .comment:        .blue
        case .requestChanges: .orange
        case .other:          .secondary
        }
    }
}
