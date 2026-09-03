import SwiftUI

/// Settings tab for per-repo `RepoConfig`s. Lists user-defined entries
/// (with built-ins shown as read-only suggestions you can clone), and
/// pops a detail editor when a row is selected. Saves write through to
/// `RepoConfigStore` immediately.
///
/// A rule holds *overrides*, not a full configuration: anything it doesn't
/// override comes from Settings → Review defaults, and the editor shows
/// which is which.
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
                Section {
                    ForEach(store.userConfigs, id: \.id) { config in
                        sidebarRow(config: config, isBuiltin: false)
                            .tag(rowId(config))
                    }
                    .onMove { source, destination in
                        var reordered = store.userConfigs
                        reordered.move(fromOffsets: source, toOffset: destination)
                        store.setAll(reordered)
                    }
                } footer: {
                    if store.userConfigs.count > 1 {
                        Text("Drag to reorder. First match wins, so list specific rules above broader ones.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !builtinsNotShadowed.isEmpty {
                    Section("Built-in") {
                        ForEach(builtinsNotShadowed, id: \.id) { config in
                            sidebarRow(config: config, isBuiltin: true)
                                .tag(rowId(config))
                        }
                    }
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
                } else if let label = autoReviewLabel(config) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(config.resolved(with: store.defaults).autoApprove.enabled ? .green : .orange)
                }
            }
            Spacer()
        }
    }

    private func autoReviewLabel(_ config: RepoConfig) -> String? {
        let effective = config.resolved(with: store.defaults)
        let approves = effective.autoApprove.enabled
        let denies = effective.autoDeny.action != .off
        // Say where it comes from: an inherited policy is easy to miss
        // when the rule itself looks empty.
        let suffix = (config.autoApprove == nil && config.autoDeny == nil) ? " (inherited)" : ""
        switch (approves, denies) {
        case (true, true):  return "auto-approve + deny" + suffix
        case (true, false): return "auto-approve" + suffix
        case (false, true): return "auto-deny" + suffix
        case (false, false): return nil
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
                        if store.userConfigs.contains(where: { $0.id == newValue.id }) {
                            store.upsert(newValue)
                        }
                    }
                ),
                defaults: store.defaults,
                isUserConfig: store.userConfigs.contains(where: { $0.id == selected.id }),
                onPromoteToUser: {
                    let copy = draft ?? selected
                    store.upsert(copy)
                    draft = copy
                }
            )
            .padding()
            .id(selection)
        } else {
            VStack(spacing: 8) {
                Text("Select a repo rule, or click + to add a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Repos with no rule use \(SettingsDestination.reviewDefaults.settingsPath) as-is.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Open Review defaults") {
                    SettingsDestination.open(.reviewDefaults)
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - helpers

    private func rowId(_ config: RepoConfig) -> String {
        config.id.uuidString
    }

    private var allConfigs: [RepoConfig] {
        store.userConfigs + builtinsNotShadowed
    }

    private var builtinsNotShadowed: [RepoConfig] {
        let userKeys = Set(store.userConfigs.map(\.id))
        return RepoConfig.builtins.filter { !userKeys.contains($0.id) }
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
        draft.id = UUID()             // fresh identity, decoupled from .default's static id
        draft.repoGlobs = ["owner/repo"]
        store.upsert(draft)
        selection = rowId(draft)
        self.draft = draft
    }

    private func addFromInbox(nameWithOwner: String) {
        var draft = RepoConfig.default
        draft.id = UUID()
        draft.repoGlobs = [nameWithOwner]
        store.upsert(draft)
        selection = rowId(draft)
        self.draft = draft
    }

    private func deleteSelected() {
        guard let sel = selection,
              let cfg = currentlySelected else { return }
        store.remove(id: cfg.id)
        if rowId(cfg) == sel { selection = nil; draft = nil }
    }
}

// MARK: - editor

struct RepoConfigEditor: View {
    @Binding var config: RepoConfig
    /// What every un-overridden field resolves to. Shown inline so the
    /// editor never presents an empty control as if it meant "off".
    let defaults: ReviewDefaults
    let isUserConfig: Bool
    let onPromoteToUser: () -> Void

    /// Local text buffer for the root-pattern editor. Round-tripping
    /// through `[String]` strips trailing empty lines, which made pressing
    /// Return appear broken (the newline got immediately erased on every
    /// keystroke). The buffer keeps the literal editor text; we only
    /// filter empties when writing back into the persisted array.
    @State private var rootPatternsText: String = ""

    var body: some View {
        ScrollView { editorContent }
            .onAppear { rootPatternsText = config.rootPatterns.joined(separator: "\n") }
            .onChange(of: config.id) { _, _ in
                // Switched to a different rule — re-seed the buffer from
                // the new config.
                rootPatternsText = config.rootPatterns.joined(separator: "\n")
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

            inheritanceBanner

            section("Match") {
                LabeledContent("Repo globs") {
                    TextField("owner/repo  (or owner/*, !owner/private)",
                              text: globBinding)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Exclude (skip all PRs from these repos)", isOn: $config.excluded)
            }

            section("AI review") {
                inheritableToggle("Run AI triage", \.aiReviewEnabled,
                                  inherited: defaults.aiReviewEnabled)
                inheritable("Tool mode", \.toolModeOverride,
                            inherited: defaults.toolMode,
                            describe: { $0.rawValue }) { ReviewSettingControls.toolMode($0) }
                inheritableToggle("Always do a full review (ignore prior verdict)",
                                  \.forceFullReview,
                                  inherited: defaults.forceFullReview)
                Picker("Provider", selection: providerOverrideBinding) {
                    Text("(use app default)").tag("default")
                    ForEach(ProviderID.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                TextField("Claude model (blank = app default)", text: claudeModelOverrideBinding)
                Picker("Claude effort", selection: claudeEffortOverrideBinding) {
                    Text("(use app default)").tag("default")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("XHigh").tag("xhigh")
                    Text("Max").tag("max")
                }
                TextField("Codex model (blank = app default)", text: codexModelOverrideBinding)
                Picker("Codex effort", selection: codexEffortOverrideBinding) {
                    Text("(use app default)").tag("default")
                    Text("None").tag("none")
                    Text("Minimal").tag("minimal")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("XHigh").tag("xhigh")
                }
            }

            section("Per-subreview budget") {
                inheritable("Max cost / subreview", \.maxCostUsdPerSubreview,
                            inherited: defaults.maxCostUsdPerSubreview,
                            describe: { $0 == 0 ? "uncapped" : String(format: "$%.2f", $0) }) {
                    ReviewSettingControls.costCap($0, label: "")
                }
                inheritable("Max tool calls", \.maxToolCallsPerSubreview,
                            inherited: defaults.maxToolCallsPerSubreview,
                            describe: { "\($0)" }) { ReviewSettingControls.maxToolCalls($0) }
                inheritable("Review timeout", \.reviewTimeoutSeconds,
                            inherited: defaults.reviewTimeoutSeconds,
                            describe: { "\($0) s" }) { ReviewSettingControls.reviewTimeout($0) }
            }

            section("Splitter") {
                inheritable("Mode", \.splitMode,
                            inherited: defaults.splitMode,
                            describe: { $0 == .single ? "single review" : "per-subfolder" }) {
                    ReviewSettingControls.splitMode($0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Root patterns (one per line)")
                        .font(.callout)
                    TextEditor(text: $rootPatternsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 220)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.secondary.opacity(0.2))
                        )
                        .onChange(of: rootPatternsText) { _, newValue in
                            config.rootPatterns = ReviewSettingControls.PatternEditor.parse(newValue)
                        }
                    Text("Per-repo only — a directory layout has no app-wide default. fnmatch globs marking each subreview root: \"kernel-*\", \"lib/*\", \"dev-infra\". Order matters within a rule; first match wins.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                inheritable("Unmatched files", \.unmatchedStrategy,
                            inherited: defaults.unmatchedStrategy,
                            describe: { $0.rawValue }) { ReviewSettingControls.unmatchedStrategy($0) }
                inheritable("Min files / subreview", \.minFilesPerSubreview,
                            inherited: defaults.minFilesPerSubreview,
                            describe: { "\($0)" }) { ReviewSettingControls.minFilesPerSubreview($0) }
                inheritable("Max parallel subreviews", \.maxParallelSubreviews,
                            inherited: defaults.maxParallelSubreviews,
                            describe: { "\($0)" }) { ReviewSettingControls.maxParallelSubreviews($0) }
                inheritable("Collapse above N subreviews", \.collapseAboveSubreviewCount,
                            inherited: defaults.collapseAboveSubreviewCount,
                            describe: { $0 == 0 ? "off" : "\($0)" }) {
                    ReviewSettingControls.collapseAboveSubreviewCount($0)
                }
            }

            section("Risk brief") {
                inheritableToggle("Rank changed files by where to look first",
                                  \.riskBriefEnabled,
                                  inherited: defaults.riskBriefEnabled)
                inheritable("Churn window", \.churnWindowDays,
                            inherited: defaults.churnWindowDays,
                            describe: { $0 == 0 ? "off" : "\($0) days" }) {
                    ReviewSettingControls.churnWindowDays($0)
                }
                inheritable("Commit depth", \.churnHistoryDepth,
                            inherited: defaults.churnHistoryDepth,
                            describe: { "\($0)" }) { ReviewSettingControls.churnHistoryDepth($0) }
            }

            section("Filters") {
                inheritableToggle("Review draft PRs", \.reviewDrafts,
                                  inherited: defaults.reviewDrafts)
                inheritableToggle("Skip AI when another reviewer has weighed in",
                                  \.skipAIIfReviewedByOthers,
                                  inherited: defaults.skipAIIfReviewedByOthers)
                inheritable("Extra title patterns to ignore", \.excludeTitlePatterns,
                            inherited: [],
                            describe: { _ in "none beyond the \(defaults.excludeTitlePatterns.count) global" }) { binding in
                    ReviewSettingControls.PatternEditor(
                        title: "Added to the global list, not replacing it",
                        footnote: "To exempt this repo from a global pattern, negate it here: !chore: bump *",
                        patterns: binding
                    )
                }
            }

            section("Notifications") {
                inheritable("Ready-for-review notifications", \.notifyPolicy,
                            inherited: defaults.notifyPolicy,
                            describe: { $0 == .eachReady ? "as each PR is ready" : "one batch" }) {
                    ReviewSettingControls.notifyPolicy($0)
                }
                Picker("Confirm before merge", selection: mergeConfirmBinding) {
                    Text("Follow global setting").tag(MergeConfirmChoice.followGlobal)
                    Text("Merge without confirmation").tag(MergeConfirmChoice.skip)
                    Text("Always confirm").tag(MergeConfirmChoice.confirm)
                }
                .help("Overrides the global \"Merge without confirmation\" setting for repos matching these globs.")
            }

            section("System prompt") {
                inheritable("Custom system prompt", \.customSystemPrompt,
                            inherited: defaults.customSystemPrompt,
                            describe: { $0.isEmpty ? "none" : "\($0.count) characters" }) { binding in
                    VStack(alignment: .leading, spacing: 6) {
                        ReviewSettingControls.customSystemPrompt(binding)
                        Toggle("Replace base system prompt entirely",
                               isOn: replaceBaseBinding)
                            .disabled(binding.wrappedValue.isEmpty)
                    }
                }
            }

            section("Auto-approve") {
                inheritable("Auto-approve policy", \.autoApprove,
                            inherited: defaults.autoApprove,
                            describe: { $0.enabled ? "enabled" : "off" }) { binding in
                    AutoApproveEditor(config: binding)
                }
            }

            section("Auto-deny") {
                inheritable("Auto-deny policy", \.autoDeny,
                            inherited: defaults.autoDeny,
                            describe: { $0.action.displayName.lowercased() }) { binding in
                    AutoDenyEditor(config: binding)
                }
            }

            section("Share findings with the author") {
                inheritable("Share findings policy", \.shareFindings,
                            inherited: defaults.shareFindings,
                            describe: { $0.displayName.lowercased() }) { binding in
                    ReviewSettingControls.shareFindings(binding)
                }
            }
        }
    }

    // MARK: - inheritance

    private var inheritanceBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.left.circle")
                .foregroundStyle(.secondary)
            Text("Unchecked settings come from \(SettingsDestination.reviewDefaults.settingsPath).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open") { SettingsDestination.open(.reviewDefaults) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }

    /// One row per overridable setting: a checkbox that flips the field
    /// between `nil` (inherit) and a concrete value, plus the real control
    /// once it's overridden. Checking it seeds from the inherited value, so
    /// turning an override on never silently changes behaviour.
    @ViewBuilder
    private func inheritable<T: Equatable, C: View>(
        _ title: String,
        _ path: WritableKeyPath<RepoConfig, T?>,
        inherited: T,
        describe: @escaping (T) -> String,
        @ViewBuilder control: @escaping (Binding<T>) -> C
    ) -> some View {
        let isOverridden = config[keyPath: path] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { config[keyPath: path] != nil },
                    set: { on in config[keyPath: path] = on ? inherited : nil }
                )) {
                    Text(title).font(.callout)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if !isOverridden {
                    Text("inherits \(describe(inherited))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if isOverridden {
                control(Binding(
                    get: { config[keyPath: path] ?? inherited },
                    set: { config[keyPath: path] = $0 }
                ))
                .padding(.leading, 20)
            }
        }
    }

    /// A boolean setting reads badly through `inheritable` — the override
    /// checkbox and the value checkbox stack into two boxes that look like
    /// they mean the same thing. Keep the value on the same row as a
    /// switch instead.
    @ViewBuilder
    private func inheritableToggle(
        _ title: String,
        _ path: WritableKeyPath<RepoConfig, Bool?>,
        inherited: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { config[keyPath: path] != nil },
                set: { on in config[keyPath: path] = on ? inherited : nil }
            )) {
                Text(title).font(.callout)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if config[keyPath: path] != nil {
                Toggle("", isOn: Binding(
                    get: { config[keyPath: path] ?? inherited },
                    set: { config[keyPath: path] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            } else {
                Text("inherits \(onOff(inherited))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func onOff(_ value: Bool) -> String { value ? "on" : "off" }

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

    private var providerOverrideBinding: Binding<String> {
        Binding(
            get: { config.providerOverride?.rawValue ?? "default" },
            set: { tag in config.providerOverride = ProviderID(rawValue: tag) }
        )
    }

    /// Tri-state choice for the merge-confirmation override (nil = follow
    /// global, true = skip, false = always confirm).
    enum MergeConfirmChoice: Hashable { case followGlobal, skip, confirm }

    private var mergeConfirmBinding: Binding<MergeConfirmChoice> {
        Binding(
            get: {
                switch config.skipMergeConfirmation {
                case .none:  return .followGlobal
                case .some(true):  return .skip
                case .some(false): return .confirm
                }
            },
            set: { choice in
                switch choice {
                case .followGlobal: config.skipMergeConfirmation = nil
                case .skip:         config.skipMergeConfirmation = true
                case .confirm:      config.skipMergeConfirmation = false
                }
            }
        )
    }

    /// `replaceBaseSystemPrompt` only matters alongside a custom prompt,
    /// so it rides the prompt's override rather than getting its own row.
    private var replaceBaseBinding: Binding<Bool> {
        Binding(
            get: { config.replaceBaseSystemPrompt ?? defaults.replaceBaseSystemPrompt },
            set: { config.replaceBaseSystemPrompt = $0 }
        )
    }

    private var claudeModelOverrideBinding: Binding<String> {
        Binding(
            get: { config.claudeModelOverride ?? "" },
            set: { config.claudeModelOverride = $0.isEmpty ? nil : $0 }
        )
    }

    private var codexModelOverrideBinding: Binding<String> {
        Binding(
            get: { config.codexModelOverride ?? "" },
            set: { config.codexModelOverride = $0.isEmpty ? nil : $0 }
        )
    }

    private var claudeEffortOverrideBinding: Binding<String> {
        Binding(
            get: { config.claudeEffortOverride ?? "default" },
            set: { tag in config.claudeEffortOverride = tag == "default" ? nil : tag }
        )
    }

    private var codexEffortOverrideBinding: Binding<String> {
        Binding(
            get: { config.codexEffortOverride ?? "default" },
            set: { tag in config.codexEffortOverride = tag == "default" ? nil : tag }
        )
    }
}
