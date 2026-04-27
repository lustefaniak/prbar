import SwiftUI

/// Settings tab for per-repo `RepoConfig`s. Lists user-defined entries
/// (with built-ins shown as read-only suggestions you can clone), and
/// pops a detail editor when a row is selected. Saves write through to
/// `RepoConfigStore` immediately.
struct RepositoriesSettings: View {
    @Environment(RepoConfigStore.self) private var store
    @Environment(PRPoller.self) private var poller

    @State private var selection: String? = nil   // repoGlobs.joined(",")
    @State private var draft: RepoConfig? = nil

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
            detail
                .frame(minWidth: 480)
        }
        // Drop the local edit-buffer when the selection moves so the
        // detail pane reflects the freshly-selected row instead of the
        // previously-edited one. Without this, draft (a parent-level
        // @State) outlives the .id(selection) view churn and keeps
        // bleeding the prior config into the editor's bindings.
        .onChange(of: selection) { _, _ in draft = nil }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configured")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(store.userConfigs, id: \.repoGlobs) { config in
                    sidebarRow(config: config, isBuiltin: false)
                        .tag(rowId(config))
                }
                ForEach(builtinsNotShadowed, id: \.repoGlobs) { config in
                    sidebarRow(config: config, isBuiltin: true)
                        .tag(rowId(config))
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    addNew()
                } label: {
                    Label("New rule", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                if let sel = selection,
                   store.userConfigs.contains(where: { rowId($0) == sel }) {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this rule")
                }
            }

            // Quick suggestions from PRs we've seen.
            if !suggestedRepos.isEmpty {
                Divider()
                Text("From your inbox")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(suggestedRepos, id: \.self) { name in
                    Button {
                        addFromInbox(nameWithOwner: name)
                    } label: {
                        Label(name, systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(8)
    }

    private func sidebarRow(config: RepoConfig, isBuiltin: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(config.repoGlobs.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                if isBuiltin {
                    Text("built-in").font(.caption2).foregroundStyle(.secondary)
                } else if config.excluded {
                    Text("excluded").font(.caption2).foregroundStyle(.orange)
                } else if config.autoApprove.enabled {
                    Text("auto-approve").font(.caption2).foregroundStyle(.green)
                }
            }
            Spacer()
        }
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        if let selected = currentlySelected {
            RepoConfigEditor(
                config: Binding(
                    get: { draft ?? selected },
                    set: { newValue in
                        draft = newValue
                        // Only persist when the rule already exists in
                        // userConfigs — built-in rows require an explicit
                        // "Save as user override" first.
                        if store.userConfigs.contains(where: { $0.repoGlobs == newValue.repoGlobs }) {
                            store.upsert(newValue)
                        }
                    }
                ),
                isUserConfig: store.userConfigs.contains(where: { $0.repoGlobs == selected.repoGlobs }),
                onPromoteToUser: {
                    var copy = draft ?? selected
                    store.upsert(copy)
                    draft = copy
                }
            )
            .padding()
            .id(selection)
        } else {
            Text("Select a repo rule, or click + to add a new one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - helpers

    private func rowId(_ config: RepoConfig) -> String {
        config.repoGlobs.joined(separator: ",")
    }

    private var allConfigs: [RepoConfig] {
        store.userConfigs + builtinsNotShadowed
    }

    private var builtinsNotShadowed: [RepoConfig] {
        let userKeys = Set(store.userConfigs.map(\.repoGlobs))
        return RepoConfig.builtins.filter { !userKeys.contains($0.repoGlobs) }
    }

    private var currentlySelected: RepoConfig? {
        guard let id = selection else { return nil }
        return allConfigs.first { rowId($0) == id }
    }

    private var suggestedRepos: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for pr in poller.prs {
            let name = "\(pr.owner)/\(pr.repo)"
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        let configured = Set(store.userConfigs.flatMap(\.repoGlobs))
        return ordered.filter { !configured.contains($0) }
    }

    private func addNew() {
        var draft = RepoConfig.default
        draft.repoGlobs = ["owner/repo"]
        store.upsert(draft)
        selection = rowId(draft)
        self.draft = draft
    }

    private func addFromInbox(nameWithOwner: String) {
        var draft = RepoConfig.default
        draft.repoGlobs = [nameWithOwner]
        store.upsert(draft)
        selection = rowId(draft)
        self.draft = draft
    }

    private func deleteSelected() {
        guard let sel = selection,
              let cfg = currentlySelected else { return }
        store.remove(repoGlobs: cfg.repoGlobs)
        if rowId(cfg) == sel { selection = nil; draft = nil }
    }
}

// MARK: - editor

/// Internal so `ScreenshotTests` can render just the editor pane (the
/// SwiftUI `HSplitView` from `RepositoriesSettings` is AppKit-backed
/// and `ImageRenderer` can't capture it).
struct RepoConfigEditor: View {
    @Binding var config: RepoConfig
    let isUserConfig: Bool
    let onPromoteToUser: () -> Void
    /// When true, drops the outer `ScrollView` so `ImageRenderer` (used
    /// by `ScreenshotTests`) captures every section instead of clipping
    /// to the proposed frame.
    var screenshotMode: Bool = false

    var body: some View {
        if screenshotMode {
            editorContent
        } else {
            ScrollView { editorContent }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
                if !isUserConfig {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("Built-in rule. Edit to create a user override.")
                            .font(.caption)
                        Spacer()
                        Button("Save as user override", action: onPromoteToUser)
                    }
                    .padding(8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }

                section("Match") {
                    LabeledContent("Repo globs") {
                        TextField("owner/repo  (or owner/*, !owner/private)",
                                  text: globBinding)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Exclude (skip all PRs from these repos)", isOn: $config.excluded)
                    Toggle("Auto-review draft PRs", isOn: $config.reviewDrafts)
                        .help("Drafts churn a lot; off by default. Re-run is always available manually.")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ignore PRs by title (one glob per line)")
                            .font(.callout)
                        TextEditor(text: titlePatternsBinding)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 140)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.secondary.opacity(0.2))
                            )
                        Text("fnmatch-style, case-insensitive. Examples: \"[Prod deploy]*\", \"chore: bump *\". Matching PRs disappear from lists, notifications, and AI triage.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Skip AI when another reviewer has already weighed in",
                           isOn: $config.skipAIIfReviewedByOthers)
                        .help("Row stays visible; AI just doesn't auto-run when reviewDecision is APPROVED or CHANGES_REQUESTED. Manual Re-run still works.")
                }

                section("Splitter") {
                    Picker("Mode", selection: $config.splitMode) {
                        Text("Per-subfolder").tag(SplitMode.perSubfolder)
                        Text("Single review").tag(SplitMode.single)
                    }
                    .pickerStyle(.segmented)

                    if config.splitMode == .perSubfolder {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Root patterns (one per line)")
                                .font(.callout)
                            TextEditor(text: rootPatternsBinding)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 100, maxHeight: 220)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(.secondary.opacity(0.2))
                                )
                            Text("fnmatch globs that mark each subreview root. Examples: \"kernel-*\", \"lib/*\", \"dev-infra\". Order matters within a single rule — first match wins.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Picker("Unmatched", selection: $config.unmatchedStrategy) {
                            Text("Review at root").tag(UnmatchedStrategy.reviewAtRoot)
                            Text("Skip review").tag(UnmatchedStrategy.skipReview)
                            Text("Group as <other>").tag(UnmatchedStrategy.groupAsOther)
                        }
                        Stepper("Min files / subreview: \(config.minFilesPerSubreview)",
                                value: $config.minFilesPerSubreview, in: 1...100)
                        Stepper("Max parallel subreviews: \(config.maxParallelSubreviews)",
                                value: $config.maxParallelSubreviews, in: 1...10)
                        Stepper("Collapse above N subreviews: \(config.collapseAboveSubreviewCount.map(String.init) ?? "off")",
                                onIncrement: { config.collapseAboveSubreviewCount = (config.collapseAboveSubreviewCount ?? 5) + 1 },
                                onDecrement: {
                                    let cur = config.collapseAboveSubreviewCount ?? 0
                                    config.collapseAboveSubreviewCount = cur <= 1 ? nil : cur - 1
                                })
                    }
                }

                section("AI") {
                    Toggle("Enable AI triage on this repo",
                           isOn: $config.aiReviewEnabled)
                        .help("When off, PRs go straight to 'ready for review' — the AI never runs. Manual Re-run still works from the detail view.")
                    Picker("Provider", selection: providerOverrideBinding) {
                        Text("(use app default)").tag("default")
                        ForEach(ProviderID.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p.rawValue)
                        }
                    }
                    .help("Overrides the app-wide default for this repo. Per-PR \"Re-run with…\" can still override this for a single run.")
                    Picker("Tool mode", selection: toolModeBinding) {
                        Text("(use global default)").tag("default")
                        Text("Minimal — read-only code exploration").tag("minimal")
                        Text("None — pure prompt, no exploration").tag("none")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom system prompt")
                            .font(.callout)
                        TextEditor(text: customPromptBinding)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200, maxHeight: 480)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(.secondary.opacity(0.2))
                            )
                    }
                    Toggle("Replace base system prompt entirely",
                           isOn: $config.replaceBaseSystemPrompt)
                        .disabled((config.customSystemPrompt ?? "").isEmpty)

                    Stepper("Max tool calls / subreview: \(config.maxToolCallsPerSubreview)",
                            value: $config.maxToolCallsPerSubreview, in: 0...50)
                    HStack {
                        Text("Max cost / subreview: $\(String(format: "%.2f", config.maxCostUsdPerSubreview))")
                        Slider(value: $config.maxCostUsdPerSubreview, in: 0.05...3.0, step: 0.05)
                    }
                }

                section("Auto-approve") {
                    Toggle("Enable auto-approve for this repo",
                           isOn: $config.autoApprove.enabled)
                        .help("Fires after AI review with a 30 s undo banner before posting.")
                    Group {
                        HStack {
                            Text("Min confidence: \(String(format: "%.2f", config.autoApprove.minConfidence))")
                            Slider(value: $config.autoApprove.minConfidence, in: 0.5...1.0, step: 0.01)
                        }
                        Toggle("Require zero blocking annotations",
                               isOn: $config.autoApprove.requireZeroBlockingAnnotations)
                        Stepper("Max additions: \(config.autoApprove.maxAdditions == 0 ? "unlimited" : "\(config.autoApprove.maxAdditions)")",
                                value: $config.autoApprove.maxAdditions, in: 0...10000, step: 50)
                    }
                    .disabled(!config.autoApprove.enabled)
                    .opacity(config.autoApprove.enabled ? 1 : 0.5)
                }
            }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(.bottom, 4)
    }

    // MARK: - bindings

    private var globBinding: Binding<String> {
        Binding(
            get: { config.repoGlobs.joined(separator: ", ") },
            set: { newValue in
                config.repoGlobs = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var rootPatternsBinding: Binding<String> {
        Binding(
            get: { config.rootPatterns.joined(separator: "\n") },
            set: { newValue in
                // Accept either newline-separated (TextEditor) or
                // comma-separated input (legacy paste from older
                // single-line field).
                config.rootPatterns = newValue
                    .split(whereSeparator: { $0.isNewline || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var providerOverrideBinding: Binding<String> {
        Binding(
            get: { config.providerOverride?.rawValue ?? "default" },
            set: { tag in
                config.providerOverride = ProviderID(rawValue: tag)
            }
        )
    }

    private var toolModeBinding: Binding<String> {
        Binding(
            get: {
                guard let mode = config.toolModeOverride else { return "default" }
                switch mode {
                case .minimal: return "minimal"
                case .none:    return "none"
                }
            },
            set: { tag in
                switch tag {
                case "minimal": config.toolModeOverride = .minimal
                case "none":    config.toolModeOverride = ToolMode.none
                default:        config.toolModeOverride = nil
                }
            }
        )
    }

    private var customPromptBinding: Binding<String> {
        Binding(
            get: { config.customSystemPrompt ?? "" },
            set: { config.customSystemPrompt = $0.isEmpty ? nil : $0 }
        )
    }

    private var titlePatternsBinding: Binding<String> {
        Binding(
            get: { config.excludeTitlePatterns.joined(separator: "\n") },
            set: { newValue in
                config.excludeTitlePatterns = newValue
                    .split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
