import SwiftUI

struct GeneralSettings: View {
    @Environment(ReviewQueueWorker.self) private var queue
    @Environment(RepoConfigStore.self) private var repoConfigs
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("sequentialFocusMode") private var sequentialFocusMode = true
    @AppStorage("postIncludesAISummary") private var postIncludesAISummary = true
    @AppStorage("badgeShowReadyToMerge")    private var badgeReadyToMerge    = true
    @AppStorage("badgeShowReviewRequested") private var badgeReviewRequested = true
    @AppStorage("badgeShowCIFailed")        private var badgeCIFailed        = true
    @AppStorage(MyDraftHandling.storageKey) private var draftHandlingRaw     =
        MyDraftHandling.default.rawValue
    @AppStorage(InboxVisibility.hideReviewedByOthersKey) private var hideReviewedByOthersFromInbox = false
    @AppStorage(MyPRsScope.storageKey)      private var myPRsScopeRaw        =
        MyPRsScope.default.rawValue
    @AppStorage("defaultProviderId")        private var defaultProviderRaw   = ProviderID.claude.rawValue
    @AppStorage(ProviderRelevance.suppressionStorageKey)
        private var suppressUnusedProviderWarnings = false
    @AppStorage("dailyCostCapEnabled")      private var costCapEnabled       = true
    @AppStorage("dailyCostCapUsd")          private var costCapUsd: Double   = 5.0
    @AppStorage("skipMergeConfirmation")    private var skipMergeConfirmation = false
    @AppStorage("defaultClaudeModel")       private var defaultClaudeModel    = "sonnet"
    @AppStorage("defaultClaudeEffort")      private var defaultClaudeEffort   = ""
    @AppStorage("defaultCodexModel")        private var defaultCodexModel     = ""
    @AppStorage("defaultCodexEffort")       private var defaultCodexEffort    = ""

    /// Probed at view-load. Drives "(not installed)" annotations in the
    /// provider picker so users don't pick a backend they don't have.
    @State private var providerAvailability: [ProviderID: Bool] = [:]

    /// True once the user has explicitly chosen "Custom…" for the claude
    /// model picker (or the stored value doesn't match a known preset).
    /// Seeded from the stored value on appear — see `claudeModelPresets`.
    @State private var claudeModelCustomMode = false

    private static let claudeModelPresets: [(tag: String, label: String, value: String)] = [
        ("auto", "Auto (claude's default)", ""),
        ("sonnet", "Sonnet", "sonnet"),
        ("opus", "Opus", "opus"),
        ("haiku", "Haiku", "haiku"),
        ("fable", "Fable", "fable"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(enabled: newValue)
                    }
                    .task {
                        // Reflect the actual system state when the pane opens.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            } header: {
                Text("Startup")
            } footer: {
                Text("Registered via SMAppService. Removing the app from /Applications can break this — re-toggle if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Advance to next ready PR after action", isOn: $sequentialFocusMode)
                Toggle("Pre-fill review body with AI summary",
                       isOn: $postIncludesAISummary)
                    .task {
                        // One-shot migration of the legacy
                        // `approveIncludesComment` key to the new combined
                        // setting. Only runs if the new key is unset.
                        let defaults = UserDefaults.standard
                        if defaults.object(forKey: "postIncludesAISummary") == nil,
                           let legacy = defaults.object(forKey: "approveIncludesComment") as? Bool {
                            defaults.set(legacy, forKey: "postIncludesAISummary")
                            postIncludesAISummary = legacy
                        }
                    }
            } header: {
                Text("Review focus")
            } footer: {
                Text("After Approve / Comment / Request changes, the detail pane jumps to the next ready review-requested PR instead of returning to the list.\n\nWhen pre-fill is on, completed AI reviews seed the editable body field on the PR detail pane. The button matching the AI's verdict is highlighted; you can pick any action and edit the body before posting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default review provider", selection: providerBinding) {
                    Text(autoLabel).tag(ProviderID.autoSentinel)
                    ForEach(ProviderID.allCases, id: \.self) { p in
                        Text(label(for: p)).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Only warn about providers I use", isOn: $suppressUnusedProviderWarnings)
                    .help("PRBar stops flagging a backend you've configured away from as \"not installed\" — both here and in Diagnostics. A provider a repo override still points at keeps its warning; \"Auto\" keeps both, since it runs whichever is present.")
            } header: {
                Text("AI provider")
            } footer: {
                Text("App-wide default. \"Auto\" picks claude when it's installed, otherwise codex. A repo's `providerOverride` (Settings → Repositories) wins over this; PRDetailView's \"Re-run with…\" menu can override either for a single run. If a chosen provider isn't installed the review fails with a clear message — see Diagnostics for current status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task { await probeProviderAvailability() }

            Section {
                Picker("Model", selection: claudeModelPickerBinding) {
                    ForEach(Self.claudeModelPresets, id: \.tag) { preset in
                        Text(preset.label).tag(preset.tag)
                    }
                    Text("Custom…").tag("custom")
                }
                if claudeModelCustomMode {
                    TextField("Model id (e.g. claude-sonnet-5)", text: claudeModelTextBinding)
                }
                Picker("Effort", selection: claudeEffortBinding) {
                    Text("Auto (claude's default)").tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("XHigh").tag("xhigh")
                    Text("Max").tag("max")
                }
            } header: {
                Text("Claude model & effort")
            } footer: {
                Text("Applies to reviews that run on the claude provider. Defaults to \"sonnet\" so PRBar never inherits whatever model you last picked in an interactive claude session — that's what silently burns extra quota. A repo's override (Settings → Repositories) wins over this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                claudeModelCustomMode = !Self.claudeModelPresets.contains { $0.value == defaultClaudeModel }
            }

            Section {
                TextField("Model id (blank = codex's own default)", text: $defaultCodexModel)
                    .onChange(of: defaultCodexModel) { _, newValue in
                        queue.defaultCodexModel = newValue
                    }
                Picker("Effort", selection: codexEffortBinding) {
                    Text("Auto (codex's default)").tag("")
                    Text("None").tag("none")
                    Text("Minimal").tag("minimal")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("XHigh").tag("xhigh")
                }
            } header: {
                Text("Codex model & effort")
            } footer: {
                Text("Codex has no stable short model aliases the way claude does (sonnet/opus/haiku/fable) — this is a literal model id passed straight to --model. Leave blank to use whatever's in ~/.codex/config.toml. A repo's override (Settings → Repositories) wins over this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enforce daily cost cap", isOn: capEnabledBinding)
                    .help("Off if you're on a subscription (Claude MAX / OpenAI Pro) — the per-token cost claude reports is informational, not billed.")
                HStack {
                    Text("Daily cap")
                    Spacer()
                    TextField(
                        "5.00",
                        value: capUsdBinding,
                        format: .currency(code: "USD")
                    )
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!costCapEnabled)
                }
                .opacity(costCapEnabled ? 1 : 0.5)
            } header: {
                Text("Budgets")
            } footer: {
                Text("Stops new reviews from queuing once today's spend hits the cap. The window resets at local midnight (your calendar's start of day). Spend is tallied from the Review History ledger — codex runs and claude runs killed before their final cost-report event count as $0 against the cap. Per-subreview cost cap (live SIGTERM mid-stream) is set per-repo in Settings → Repositories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Merge without confirmation", isOn: $skipMergeConfirmation)
            } header: {
                Text("Merging")
            } footer: {
                Text("When on, the Squash / Merge / Rebase button merges immediately instead of asking to confirm first. A per-repo override (Settings → Repositories) wins over this default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ready-to-merge PRs",   isOn: $badgeReadyToMerge)
                Toggle("Pending review requests", isOn: $badgeReviewRequested)
                Toggle("Authored PRs with red CI", isOn: $badgeCIFailed)
            } header: {
                Text("Menu bar badge")
            } footer: {
                Text("Show a count next to the menu-bar icon when there's something actionable. Toggle each source independently; turn them all off to hide the badge entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Drafts you authored", selection: $draftHandlingRaw) {
                    ForEach(MyDraftHandling.allCases, id: \.rawValue) { v in
                        Text(v.pickerLabel).tag(v.rawValue)
                    }
                }
                Picker("Show", selection: $myPRsScopeRaw) {
                    ForEach(MyPRsScope.allCases, id: \.rawValue) { v in
                        Text(v.pickerLabel).tag(v.rawValue)
                    }
                }
            } header: {
                Text("My PRs")
            } footer: {
                Text("Silence keeps drafts visible in the My PRs list but excludes them from the menu-bar badge and CI / ready-to-merge notifications. Hide also removes them from the list until promoted to ready. Review-requested drafts (other people's) are always silenced — that path is separate.\n\nShow narrows the (non-draft) list: \"Needs my attention\" keeps ready-to-merge, approved-but-waiting, changes-requested, red CI and conflicts; \"Only badge-counted\" keeps just what the menu-bar badge counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide PRs already reviewed by others", isOn: $hideReviewedByOthersFromInbox)
            } header: {
                Text("Inbox")
            } footer: {
                Text("When on, review requests another reviewer has already approved or requested changes on are removed from the Inbox list instead of sinking to the bottom. PRs still waiting on your review stay visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Picker label for one provider — adds "(not installed)" when the
    /// CLI binary isn't on PATH so the user makes an informed choice.
    /// Suppressed for providers the user has configured away from when
    /// "Only warn about providers I use" is on.
    private func label(for p: ProviderID) -> String {
        if providerAvailability[p] == false, relevantProviders.contains(p) {
            return "\(p.displayName) (not installed)"
        }
        return p.displayName
    }

    /// Providers whose missing CLI is still worth flagging, given the
    /// suppression toggle, the app-wide default, and per-repo overrides.
    private var relevantProviders: Set<ProviderID> {
        ProviderRelevance.relevantProviders(
            suppressionEnabled: suppressUnusedProviderWarnings,
            defaultProviderRaw: defaultProviderRaw,
            repoOverrides: repoConfigs.providerOverrides
        )
    }

    /// "Auto" picker label that names which provider would actually
    /// run right now, so the segmented control isn't opaque.
    private var autoLabel: String {
        let resolved = ProviderID.resolveAuto { binary in
            providerAvailability.first { $0.key.binaryName == binary }?.value ?? false
        }
        // While availability is still being probed, fall back to the
        // tie-break.
        if providerAvailability.isEmpty { return "Auto (claude)" }
        return "Auto (\(resolved.displayName.lowercased()))"
    }

    /// Probe both binaries off the main thread; populate the @State map
    /// so the picker reactively updates.
    private func probeProviderAvailability() async {
        let probed = await Task.detached(priority: .userInitiated) {
            ProviderID.allCases.reduce(into: [ProviderID: Bool]()) { acc, p in
                acc[p] = ExecutableResolver.find(p.binaryName) != nil
            }
        }.value
        await MainActor.run {
            self.providerAvailability = probed
        }
    }

    private var capEnabledBinding: Binding<Bool> {
        Binding(
            get: { costCapEnabled },
            set: { newValue in
                costCapEnabled = newValue
                queue.dailyCostCapEnabled = newValue
            }
        )
    }

    private var capUsdBinding: Binding<Double> {
        Binding(
            get: { costCapUsd },
            set: { newValue in
                costCapUsd = max(0, newValue)
                queue.dailyCostCap = costCapUsd
            }
        )
    }

    /// Bridge the AppStorage string (`"auto"`, `"claude"`, `"codex"`) ↔
    /// the picker's selection. Setter pushes the resolved concrete
    /// `ProviderID` into the live worker so the change applies without
    /// restart; `"auto"` resolves to whichever backend is installed
    /// (claude wins ties).
    private var providerBinding: Binding<String> {
        Binding(
            get: { defaultProviderRaw },
            set: { newValue in
                defaultProviderRaw = newValue
                if newValue == ProviderID.autoSentinel {
                    queue.defaultProviderId = ProviderID.resolveAuto()
                } else {
                    queue.defaultProviderId = ProviderID(rawValue: newValue) ?? .claude
                }
            }
        )
    }

    /// Picker selection for the claude model preset row. "custom" is a
    /// pure UI sentinel (never persisted) — it just flips
    /// `claudeModelCustomMode` to reveal the free-text field; the actual
    /// stored value only ever changes via a real preset or the text field.
    private var claudeModelPickerBinding: Binding<String> {
        Binding(
            get: {
                if claudeModelCustomMode { return "custom" }
                return Self.claudeModelPresets.first { $0.value == defaultClaudeModel }?.tag ?? "auto"
            },
            set: { tag in
                if tag == "custom" {
                    claudeModelCustomMode = true
                    return
                }
                claudeModelCustomMode = false
                let value = Self.claudeModelPresets.first { $0.tag == tag }?.value ?? ""
                defaultClaudeModel = value
                queue.defaultClaudeModel = value
            }
        )
    }

    private var claudeModelTextBinding: Binding<String> {
        Binding(
            get: { defaultClaudeModel },
            set: { newValue in
                defaultClaudeModel = newValue
                queue.defaultClaudeModel = newValue
            }
        )
    }

    private var claudeEffortBinding: Binding<String> {
        Binding(
            get: { defaultClaudeEffort },
            set: { newValue in
                defaultClaudeEffort = newValue
                queue.defaultClaudeEffort = newValue
            }
        )
    }

    private var codexEffortBinding: Binding<String> {
        Binding(
            get: { defaultCodexEffort },
            set: { newValue in
                defaultCodexEffort = newValue
                queue.defaultCodexEffort = newValue
            }
        )
    }
}

#Preview {
    GeneralSettings()
        .frame(width: 520, height: 360)
}
