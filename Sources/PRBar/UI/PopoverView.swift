import SwiftUI

struct PopoverView: View {
    @Environment(PRPoller.self) private var poller
    @Environment(Notifier.self) private var notifier
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var selectedTab: Tab = .myPRs
    @State private var selectedPR: InboxPR?
    /// Node IDs the user chose to "Skip for now" during the current
    /// review session. Excluded from sequential auto-advance so the user
    /// isn't bounced back onto a PR they deferred. Forgotten (cleared)
    /// once advancing finds nothing left to review — see `advanceToNext`.
    @State private var skippedNodeIds: Set<String> = []
    @State private var toolResults: [ToolProbeResult] = []
    @AppStorage("sequentialFocusMode") private var sequentialFocusMode = true
    @AppStorage(MyDraftHandling.storageKey) private var myDraftHandlingRaw =
        MyDraftHandling.default.rawValue
    private let probedTools = ["gh", "claude", "codex", "git"]

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case myPRs = "My PRs"
        case inbox = "Inbox"
        case history = "History"
        var id: String { rawValue }
    }

    private var missingTools: [ToolProbeResult] {
        toolResults.filter { !$0.available }
    }

    private var myPRsCount: Int {
        // Match what MyPRsView actually renders — when the user has
        // opted to hide drafts from My PRs, those drafts must not
        // count towards the segmented-tab badge either, otherwise the
        // badge says e.g. "3" while the list shows 1.
        let hideDrafts = (MyDraftHandling(rawValue: myDraftHandlingRaw) ?? .default).hidesFromMyPRs
        return poller.prs.filter {
            ($0.role == .authored || $0.role == .both)
                && !(hideDrafts && $0.isDraft)
        }.count
    }
    private var inboxCount: Int {
        poller.prs.filter { $0.role == .reviewRequested || $0.role == .both }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected = selectedPR {
                PRDetailView(
                    pr: selected,
                    onBack: { selectedPR = nil },
                    onPostedAction: { advanceOrClose(after: selected) },
                    onSkip: { skip(after: selected) }
                )
            } else {
                listContent
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Skip in screenshot mode: probing forks `gh --version`
            // / `claude --version` which adds latency and would render
            // a "missing tool" banner if the host machine lacks them.
            if !ScreenshotMode.isActive { await probeTools() }
        }
        .task {
            // Skip in screenshot mode: pollNow would race the fixture
            // seeding and could emit spurious delta-driven notifications.
            if !ScreenshotMode.isActive { poller.pollNow() }
        }
        .onAppear {
            notifier.setPopoverVisible(true)
            seedScreenshotStateOnce()
        }
        .onDisappear { notifier.setPopoverVisible(false) }
        .onChange(of: poller.prs) { _, newPRs in
            queue.enqueueNewReviewRequests(from: newPRs)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        header

        if !missingTools.isEmpty {
            missingToolsBanner
        }

        if queue.batchUndoActive {
            AutoApproveBanner()
        }

        tabPicker

        Group {
            switch selectedTab {
            case .myPRs:  MyPRsView(onSelect: { select($0) })
            case .inbox:  InboxView(onSelect: { select($0) })
            case .history: HistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        // Bottom-right Settings affordance — same place macOS apps put
        // gear icons in popovers. Right-click on the menu-bar icon also
        // works; this is the discoverable in-popover entry point.
        HStack {
            Spacer()
            // SettingsLink talks to SwiftUI's internal Settings-scene
            // plumbing, which works reliably from inside an animating-
            // closed popover (the manual NSApp.perform / sendAction
            // path lost the dispatch when the popover was tearing down).
            // The simultaneous tap gesture dismisses the popover in
            // parallel with SettingsLink's action — both fire, neither
            // blocks the other.
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .simultaneousGesture(
                TapGesture().onEnded {
                    (NSApp.delegate as? AppDelegate)?.dismissPopover()
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("PopoverIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 18)
                .foregroundStyle(.tint)
            Text("PRBar")
                .font(.headline)
            Spacer()
            if let lastFetchedAt = poller.lastFetchedAt {
                Text(lastFetchedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last successful fetch")
            }
            Button(action: { poller.pollNow() }) {
                if poller.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(poller.isFetching)
            .help("Refresh all")
        }
    }

    private var missingToolsBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing CLIs: \(missingTools.map(\.tool).joined(separator: ", "))")
                    .font(.caption)
                Text("Install them and refresh — see Diagnostics in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tabLabel(tab)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    private func tabLabel(_ tab: Tab) -> String {
        switch tab {
        case .myPRs:  return myPRsCount > 0  ? "\(tab.rawValue)  \(myPRsCount)"  : tab.rawValue
        case .inbox:  return inboxCount > 0  ? "\(tab.rawValue)  \(inboxCount)"  : tab.rawValue
        case .history: return tab.rawValue
        }
    }

    /// Open a PR the user explicitly picked from a list. Un-skips it —
    /// choosing it is an explicit decision to review it now, so it should
    /// no longer be excluded from later auto-advance.
    private func select(_ pr: InboxPR) {
        skippedNodeIds.remove(pr.nodeId)
        selectedPR = pr
    }

    /// "Skip for now": remember the PR for this session and jump to the
    /// next non-skipped review-requested PR. Always advances (unlike
    /// `advanceOrClose`, this ignores `sequentialFocusMode` — advancing
    /// is the button's whole purpose).
    private func skip(after current: InboxPR) {
        skippedNodeIds.insert(current.nodeId)
        advanceToNext(after: current)
    }

    /// Pick the next ready PR after the user actioned the current one.
    /// Honours `sequentialFocusMode`: off ⇒ return to the list (and end
    /// the skip session).
    private func advanceOrClose(after current: InboxPR) {
        guard sequentialFocusMode else {
            selectedPR = nil
            skippedNodeIds.removeAll()
            return
        }
        advanceToNext(after: current)
    }

    /// Select the next ready, non-skipped PR. "Ready" = role is
    /// reviewRequested or both, not the same PR, not skipped this
    /// session, and (AI triage is terminal OR the repo has AI off OR no
    /// review state recorded). When nothing remains, return to the list
    /// and forget the session's skips.
    private func advanceToNext(after current: InboxPR) {
        let next = poller.prs.first { pr in
            guard pr.nodeId != current.nodeId else { return false }
            guard !skippedNodeIds.contains(pr.nodeId) else { return false }
            guard pr.role == .reviewRequested || pr.role == .both else { return false }
            guard !pr.isDraft else { return false }
            // Skip already-handled (the user approved, or someone else did).
            if pr.reviewDecision == "APPROVED" { return false }
            // Treat "no review state yet" as ready too — repos with AI off
            // never enqueue, so they'd otherwise be skipped here.
            switch queue.reviews[pr.nodeId]?.status {
            case .none, .completed, .failed: return true
            case .queued, .running: return false
            }
        }
        if let next {
            selectedPR = next
        } else {
            selectedPR = nil
            skippedNodeIds.removeAll()
        }
    }

    /// Apply the screenshot launcher's pre-set tab + selection if any.
    /// Cleared after first read so subsequent re-opens behave normally.
    private func seedScreenshotStateOnce() {
        if let tab = ScreenshotMode.initialPopoverTab {
            switch tab {
            case .myPRs:   selectedTab = .myPRs
            case .inbox:   selectedTab = .inbox
            case .history: selectedTab = .history
            }
            ScreenshotMode.initialPopoverTab = nil
        }
        if let pr = ScreenshotMode.initialSelectedPR {
            selectedPR = pr
            ScreenshotMode.initialSelectedPR = nil
        }
    }

    private func probeTools() async {
        let names = probedTools
        let probed = await Task.detached(priority: .userInitiated) {
            names.map(ToolProbe.probe)
        }.value
        self.toolResults = probed
    }
}

#Preview {
    PopoverView()
        .environment(PRPoller(fetcher: { [] }))
        .environment(Notifier(deliverer: NoopDeliverer()))
        .environment(ReviewQueueWorker(diffFetcher: { _, _, _ in "" }))
        .environment(ActionQueue())
}

private struct NoopDeliverer: NotificationDeliverer {
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async {}
}
