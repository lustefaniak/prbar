import SwiftUI
import SwiftData

enum HistoricalReviewWindowID {
    static let id = "historical-review"
}

/// Read-only view of a `ReviewLogEntry`. Opened from Settings → Review
/// History, shows the cached `AggregatedReview` in the same detail
/// shape PRDetailView uses (verdict + summary + annotations) and tries
/// to fetch the live PR alongside so the diff renders with the same
/// annotation-anchored locators.
///
/// Failure modes handled explicitly so a closed/deleted/forbidden PR
/// doesn't blow up the window:
///   - Log entry not found in SwiftData → "Review entry missing".
///   - PR fetch succeeds → live PR header + diff above the cached review.
///   - PR fetch fails (404, no access, gh missing) → cached review
///     only, with a banner explaining what's missing.
struct HistoricalReviewWindowView: View {
    let logEntryId: UUID

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(ReviewLogStore.self) private var reviewLog

    @Query private var entries: [ReviewLogEntry]

    @State private var freshPR: InboxPR? = nil
    @State private var fetchError: String? = nil
    @State private var fetchInFlight: Bool = true

    init(logEntryId: UUID) {
        self.logEntryId = logEntryId
        // Filter the @Query down to the single row we care about so the
        // view re-renders if the user clears history out from under us.
        let predicate = #Predicate<ReviewLogEntry> { $0.id == logEntryId }
        self._entries = Query(filter: predicate)
    }

    var body: some View {
        Group {
            if let entry = entries.first {
                content(for: entry)
            } else {
                missingEntry
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle(navTitle)
        .task(id: logEntryId) {
            await refetchPR()
        }
    }

    private var navTitle: String {
        guard let entry = entries.first else { return "Historical review" }
        return "\(entry.nameWithOwner) #\(entry.prNumber) — \(entry.prTitle)"
    }

    @ViewBuilder
    private func content(for entry: ReviewLogEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                contextBanner(for: entry)

                Divider()

                header(for: entry)

                if entry.status == .failed {
                    Divider()
                    failureSection(entry)
                } else if let agg = entry.decodeAggregated() {
                    Divider()
                    cachedReviewSection(agg, entry: entry)
                } else {
                    Divider()
                    Text("Cached review payload couldn't be decoded — schema may have changed since this entry was written.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
    }

    // MARK: - sections

    @ViewBuilder
    private func contextBanner(for entry: ReviewLogEntry) -> some View {
        // Three states. Loading: yellow / progress. Live: green / link.
        // Missing: gray / explanation. Each is one row so the user can
        // glance the PR availability without reading paragraphs.
        if fetchInFlight {
            banner(
                icon: "hourglass",
                tint: .secondary,
                title: "Loading PR context…",
                detail: "Fetching live PR data from GitHub."
            )
        } else if let pr = freshPR {
            banner(
                icon: "link",
                tint: .green,
                title: "PR is live on GitHub.",
                detail: prStateDescription(pr),
                trailing: AnyView(
                    HStack(spacing: 8) {
                        Button("Open in browser") { NSWorkspace.shared.open(pr.url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Text(pr.headSha == entry.headSha ? "same commit" : "PR moved on")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                )
            )
        } else {
            banner(
                icon: "questionmark.diamond",
                tint: .orange,
                title: "PR is no longer reachable on GitHub.",
                detail: fetchError ?? "Repo may be private/archived, the PR may have been deleted, or `gh` may not be authenticated.",
                trailing: AnyView(
                    Button("Retry") {
                        Task { await refetchPR() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                )
            )
        }
    }

    @ViewBuilder
    private func banner(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        trailing: AnyView? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func header(for entry: ReviewLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.prTitle)
                .font(.title3.bold())
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text("\(entry.nameWithOwner) #\(entry.prNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(entry.providerId.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.headSha.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(String(entry.headSha.prefix(7)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.secondary)
                Text(entry.triggeredAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cachedReviewSection(_ agg: AggregatedReview, entry: ReviewLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                verdictBadge(agg.verdict)
                Text(String(format: "%.0f%% confident", agg.confidence * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if agg.costUsd > 0 {
                    Text(String(format: "$%.4f", agg.costUsd))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if agg.toolCallCount > 0 {
                    Text("\(agg.toolCallCount) tool\(agg.toolCallCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !agg.summaryMarkdown.isEmpty {
                MarkdownText(raw: agg.summaryMarkdown)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !agg.annotations.isEmpty {
                AnnotationsSummaryView(annotations: agg.annotations)
            }
        }
    }

    @ViewBuilder
    private func failureSection(_ entry: ReviewLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Review run failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline.bold())
            Text(entry.errorMessage ?? "(no error message recorded)")
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var missingEntry: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Review entry missing")
                .font(.headline)
            Text("This row may have been cleared from history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close") { dismissWindow(id: HistoricalReviewWindowID.id) }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func verdictBadge(_ v: ReviewVerdict) -> some View {
        let (label, color): (String, Color) = {
            switch v {
            case .approve:        return ("Approve", .green)
            case .comment:        return ("Approve with notes", .blue)
            case .requestChanges: return ("Request changes", .red)
            case .abstain:        return ("Abstain", .gray)
            }
        }()
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private func prStateDescription(_ pr: InboxPR) -> String {
        var parts: [String] = []
        parts.append("@\(pr.author)")
        parts.append("`\(pr.baseRef)` ← `\(pr.headRef)`")
        parts.append("+\(pr.totalAdditions) -\(pr.totalDeletions) (\(pr.changedFiles) files)")
        if pr.isDraft { parts.append("draft") }
        return parts.joined(separator: " · ")
    }

    // MARK: - fetch

    private func refetchPR() async {
        guard let entry = entries.first else {
            fetchInFlight = false
            return
        }
        fetchInFlight = true
        fetchError = nil
        do {
            let client = try GHClient()
            let pr = try await client.fetchPR(
                owner: entry.owner,
                repo: entry.repo,
                number: entry.prNumber
            )
            await MainActor.run {
                self.freshPR = pr
                self.fetchInFlight = false
            }
        } catch {
            await MainActor.run {
                self.freshPR = nil
                self.fetchError = error.localizedDescription
                self.fetchInFlight = false
            }
        }
    }
}
