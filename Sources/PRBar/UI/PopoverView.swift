import SwiftUI

struct PopoverView: View {
    @Environment(PRPoller.self) private var poller
    @Environment(Notifier.self) private var notifier
    @Environment(ReviewQueueWorker.self) private var queue

    @State private var selectedTab: Tab = .myPRs
    @State private var selectedPR: InboxPR?
    @State private var toolResults: [ToolProbeResult] = []
    private let probedTools = ["gh", "claude", "git"]

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
                PRDetailView(pr: selected, onBack: { selectedPR = nil })
            } else {
                listContent
            }
        }
        .padding(16)
        .frame(width: 480)
        .task { await probeTools() }
        .task { poller.pollNow() }   // refresh whenever the popover opens
        .onAppear { notifier.setPopoverVisible(true) }
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

        tabPicker

        Group {
            switch selectedTab {
            case .myPRs:  MyPRsView(onSelect: { selectedPR = $0 })
            case .inbox:  InboxView(onSelect: { selectedPR = $0 })
            case .history: HistoryView()
            }
        }
        .frame(minHeight: 80, alignment: .top)

        Divider()

        footer
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title3)
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

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
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
