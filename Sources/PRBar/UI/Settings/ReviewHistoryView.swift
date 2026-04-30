import SwiftUI
import SwiftData

/// Settings → Review History tab. Browse every AI triage that reached a
/// terminal state (completed or failed). Filterable by status, provider,
/// repo (substring), and time window. Expand a row for the persisted
/// `AggregatedReview` summary, cost, head SHA, and failure reason.
///
/// Read path uses `@Query` so a freshly-recorded triage shows up live
/// without needing the user to flip to another tab and back. Writes
/// (clear-all) go through the `ReviewLogStore` env to stay on the
/// same `ModelContext` the rest of the app uses.
struct ReviewHistoryView: View {
    @Environment(ReviewLogStore.self) private var store

    @Query(sort: [SortDescriptor(\ReviewLogEntry.triggeredAt, order: .reverse)])
    private var allEntries: [ReviewLogEntry]

    @State private var statusFilter: StatusFilter = .all
    @State private var providerFilter: ProviderFilter = .all
    @State private var repoFilter: String = ""
    @State private var window: TimeWindow = .last7Days
    @State private var expanded: Set<UUID> = []
    @State private var confirmClear: Bool = false

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, completed, failed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:       return "All"
            case .completed: return "Completed"
            case .failed:    return "Failed"
            }
        }
    }

    enum ProviderFilter: String, CaseIterable, Identifiable {
        case all, claude, codex
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:    return "All"
            case .claude: return "Claude"
            case .codex:  return "Codex"
            }
        }
    }

    enum TimeWindow: String, CaseIterable, Identifiable {
        case today, last24h, last7Days, last30Days, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today:      return "Today"
            case .last24h:    return "Last 24h"
            case .last7Days:  return "Last 7 days"
            case .last30Days: return "Last 30 days"
            case .all:        return "All time"
            }
        }
        func cutoff(now: Date = Date()) -> Date? {
            switch self {
            case .today:      return Calendar.current.startOfDay(for: now)
            case .last24h:    return now.addingTimeInterval(-86_400)
            case .last7Days:  return now.addingTimeInterval(-86_400 * 7)
            case .last30Days: return now.addingTimeInterval(-86_400 * 30)
            case .all:        return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            statsBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered, id: \.id) { entry in
                        EntryRow(
                            entry: entry,
                            isExpanded: expanded.contains(entry.id),
                            onToggle: { toggle(entry.id) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear history", systemImage: "trash")
                }
                .disabled(allEntries.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete all review history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Delete \(allEntries.count) entries", role: .destructive) {
                store.clearAll()
                expanded.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the AI triage ledger that the daily cost cap reads. The cap will read $0 spent until new reviews accumulate.")
        }
    }

    private var filterBar: some View {
        // `.segmented` Pickers render their `title` argument inline as a
        // wrapping label outside of a Form; `.labelsHidden()` collapses
        // it so the segmented control gets the full row width. The
        // labels live as plain `Text` to the left so the field is still
        // identifiable.
        HStack(spacing: 12) {
            Text("Status").foregroundStyle(.secondary).font(.caption)
            Picker("Status", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            Text("Provider").foregroundStyle(.secondary).font(.caption)
            Picker("Provider", selection: $providerFilter) {
                ForEach(ProviderFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)

            Picker("Window", selection: $window) {
                ForEach(TimeWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()

            TextField("Filter by repo (owner/repo)", text: $repoFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)
        }
    }

    private var statsBar: some View {
        HStack(spacing: 24) {
            stat(label: "Entries", value: "\(filtered.count)")
            stat(label: "Spend (filtered)", value: formattedSpend(filtered))
            stat(label: "Today", value: formattedSpend(filtered.filter { Calendar.current.isDateInToday($0.triggeredAt) }))
            Spacer()
        }
        .font(.caption)
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func formattedSpend(_ rows: [ReviewLogEntry]) -> String {
        let total = rows.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        return String(format: "$%.2f", total)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No reviews match the current filters.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var filtered: [ReviewLogEntry] {
        let cutoff = window.cutoff()
        let needle = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return allEntries.filter { e in
            if let cutoff, e.triggeredAt < cutoff { return false }
            switch statusFilter {
            case .all: break
            case .completed: if e.status != .completed { return false }
            case .failed:    if e.status != .failed { return false }
            }
            switch providerFilter {
            case .all: break
            case .claude: if e.providerId != .claude { return false }
            case .codex:  if e.providerId != .codex { return false }
            }
            if !needle.isEmpty {
                if !e.nameWithOwner.lowercased().contains(needle) { return false }
            }
            return true
        }
    }
}

private struct EntryRow: View {
    let entry: ReviewLogEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.prTitle)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("#\(entry.prNumber)")
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(entry.nameWithOwner)
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.secondary)
                            Text(entry.providerId.displayName)
                                .foregroundStyle(.secondary)
                            if !entry.headSha.isEmpty {
                                Text("·").foregroundStyle(.secondary)
                                Text(String(entry.headSha.prefix(7)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if let v = entry.verdict {
                        verdictPill(v)
                    }
                    Text(formattedCost)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(entry.triggeredAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedDetail
                    .padding(.leading, 22)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var expandedDetail: some View {
        if entry.status == .failed {
            VStack(alignment: .leading, spacing: 4) {
                Text("Failure reason")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(entry.errorMessage ?? "(no message)")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } else if let agg = entry.decodeAggregated() {
            VStack(alignment: .leading, spacing: 8) {
                if !agg.summaryMarkdown.isEmpty {
                    MarkdownText(raw: agg.summaryMarkdown)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !agg.annotations.isEmpty {
                    Text("\(agg.annotations.count) annotation\(agg.annotations.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Tools: \(agg.toolCallCount) call\(agg.toolCallCount == 1 ? "" : "s")\(agg.toolNamesUsed.isEmpty ? "" : " (\(agg.toolNamesUsed.joined(separator: ", ")))")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Cached review payload couldn't be decoded — schema may have changed since this entry was written.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedCost: String {
        guard let c = entry.costUsd else { return "—" }
        return String(format: "$%.3f", c)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func verdictPill(_ v: ReviewVerdict) -> some View {
        Text(v.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(verdictColor(v).opacity(0.15), in: Capsule())
            .foregroundStyle(verdictColor(v))
    }

    private func verdictColor(_ v: ReviewVerdict) -> Color {
        switch v {
        case .approve:        return .green
        case .comment:        return .blue
        case .requestChanges: return .orange
        case .abstain:        return .secondary
        }
    }
}
