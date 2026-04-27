import SwiftUI

struct PopoverView: View {
    @Environment(PRPoller.self) private var poller
    @Environment(Notifier.self) private var notifier
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var selectedTab: Tab = .myPRs
    @State private var selectedPR: InboxPR?
    @State private var toolResults: [ToolProbeResult] = []
    @AppStorage("sequentialFocusMode") private var sequentialFocusMode = true
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
        poller.prs.filter { $0.role == .authored || $0.role == .both }.count
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
                    onPostedAction: { advanceOrClose(after: selected) }
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
            case .myPRs:  MyPRsView(onSelect: { selectedPR = $0 })
            case .inbox:  InboxView(onSelect: { selectedPR = $0 })
            case .history: HistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        // Bottom-right Settings affordance — same place macOS apps put
        // gear icons in popovers. Right-click on the menu-bar icon also
        // works; this is the discoverable in-popover entry point.
        HStack {
            Spacer()
            // Plain Button (not SettingsLink) so we can dismiss the
            // popover before opening Settings — otherwise the popover
            // lingers behind the Settings window. Routes through
            // AppDelegate.openSettings which uses the same modern /
            // legacy selector dance Apple's SettingsLink does.
            Button {
                let appDelegate = NSApp.delegate as? AppDelegate
                appDelegate?.dismissPopover()
                appDelegate?.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
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

    /// Pick the next ready PR after the user actioned the current one.
    /// "Ready" = role is reviewRequested or both, not the same PR, and
    /// (AI triage is terminal OR the repo has AI off OR no review state
    /// recorded). Falls back to closing the detail view when there's
    /// nothing left or the toggle is off.
    private func advanceOrClose(after current: InboxPR) {
        guard sequentialFocusMode else {
            selectedPR = nil
            return
        }
        let candidates = poller.prs.filter { pr in
            guard pr.nodeId != current.nodeId else { return false }
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
        if let next = candidates.first {
            selectedPR = next
        } else {
            selectedPR = nil
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
}

private struct NoopDeliverer: NotificationDeliverer {
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async {}
}
