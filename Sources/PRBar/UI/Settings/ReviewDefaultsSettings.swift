import SwiftUI

/// Settings → Review defaults: the app-level value of every setting a repo
/// rule can override.
///
/// These used to exist only on a per-repo rule, which meant a user with no
/// rule ran on compiled-in numbers with nothing in the UI to show them —
/// the per-subreview cost cap in particular produced "exceeded budget"
/// failures that looked like a malfunction rather than a budget.
struct ReviewDefaultsSettings: View {
    @Environment(RepoConfigStore.self) private var store

    @AppStorage("dailyCostCapEnabled") private var dailyCapEnabled = true
    @AppStorage("dailyCostCapUsd") private var dailyCapUsd: Double = 5.0

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                ReviewSettingControls.costCap($store.defaults.maxCostUsdPerSubreview)
                if let warning = dailyCapWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ReviewSettingControls.maxToolCalls($store.defaults.maxToolCallsPerSubreview)
                ReviewSettingControls.reviewTimeout($store.defaults.reviewTimeoutSeconds)
            } header: {
                Text("Per-subreview budget")
            } footer: {
                Text("Applies to each subreview a PR is split into, so a PR that fans out to three subreviews can spend up to three times the cap. The separate daily cap lives in Settings → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run AI triage on incoming review requests", isOn: $store.defaults.aiReviewEnabled)
                ReviewSettingControls.toolMode($store.defaults.toolMode)
                Toggle("Always do a full review (ignore prior verdict)", isOn: $store.defaults.forceFullReview)
                    .help("When the PR head moves, retriages re-evaluate the whole diff with no incremental framing. Off keeps cost down but biases the AI toward judging only the increment.")
            } header: {
                Text("AI review")
            }

            Section {
                ReviewSettingControls.splitMode($store.defaults.splitMode)
                ReviewSettingControls.unmatchedStrategy($store.defaults.unmatchedStrategy)
                ReviewSettingControls.minFilesPerSubreview($store.defaults.minFilesPerSubreview)
                ReviewSettingControls.maxParallelSubreviews($store.defaults.maxParallelSubreviews)
                ReviewSettingControls.collapseAboveSubreviewCount($store.defaults.collapseAboveSubreviewCount)
            } header: {
                Text("Splitter")
            } footer: {
                Text("Root patterns are the one splitter setting with no app-level default — a directory layout belongs to its repo. Set those per repo in Settings → Repositories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Rank changed files by where to look first", isOn: $store.defaults.riskBriefEnabled)
                Group {
                    ReviewSettingControls.churnWindowDays($store.defaults.churnWindowDays)
                    ReviewSettingControls.churnHistoryDepth($store.defaults.churnHistoryDepth)
                }
                .disabled(!store.defaults.riskBriefEnabled)
                .opacity(store.defaults.riskBriefEnabled ? 1 : 0.5)
            } header: {
                Text("Risk brief")
            } footer: {
                Text("Prepends a mechanical reading order to each subreview's prompt. It routes attention on a large diff and never contributes to the verdict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Review draft PRs", isOn: $store.defaults.reviewDrafts)
                    .help("Drafts churn a lot; off by default. Re-run is always available manually.")
                Toggle("Skip AI when another reviewer has already weighed in",
                       isOn: $store.defaults.skipAIIfReviewedByOthers)
                ReviewSettingControls.PatternEditor(
                    title: "Ignore PRs by title (one glob per line)",
                    footnote: "fnmatch-style, case-insensitive. Examples: \"[Prod deploy]*\", \"chore: bump *\". Matching PRs disappear from lists, notifications, and AI triage. A repo rule adds to this list rather than replacing it.",
                    patterns: $store.defaults.excludeTitlePatterns
                )
            } header: {
                Text("Filters")
            }

            Section {
                ReviewSettingControls.notifyPolicy($store.defaults.notifyPolicy)
            } header: {
                Text("Ready-for-review notifications")
            }

            Section {
                ReviewSettingControls.customSystemPrompt($store.defaults.customSystemPrompt)
                Toggle("Replace base system prompt entirely",
                       isOn: $store.defaults.replaceBaseSystemPrompt)
                    .disabled(store.defaults.customSystemPrompt.isEmpty)
            } header: {
                Text("System prompt")
            }

            Section {
                AutoApproveEditor(config: $store.defaults.autoApprove)
            } header: {
                Text("Auto-approve")
            } footer: {
                Text("Applies to every repo without its own auto-approve setting. Off by default on purpose — turning it on here lets PRBar approve on repos you haven't thought about individually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                AutoDenyEditor(config: $store.defaults.autoDeny)
            } header: {
                Text("Auto-deny")
            } footer: {
                Text("Same reach as auto-approve, and a heavier act: this posts a blocking review on a colleague's PR on the AI's say-so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ReviewSettingControls.shareFindings($store.defaults.shareFindings)
                if store.defaults.shareFindings != .off {
                    ReviewSettingControls.shareMinConfidence($store.defaults.shareMinConfidence)
                    ReviewSettingControls.shareMaxComments($store.defaults.shareMaxComments)
                }
            } header: {
                Text("Share findings with the author")
            } footer: {
                Text("When a completed review clears neither gate above, post its findings to the PR as a comment so the author can start on them instead of waiting for you. It never approves or requests changes, so your own review still decides the PR. Rides the same undo window as the other two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ReviewSettingControls.resolveThreads($store.defaults.resolveThreads)
            } header: {
                Text("Resolve addressed threads")
            } footer: {
                Text("Closes a review thread PRBar opened once all of: the anchored code changed, the PR author replied, and a later review no longer reports that finding. Resolving collapses the thread for everyone on the PR, so it ships off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A per-subreview cap above the daily cap fails on the first review of
    /// the day — worth catching here rather than in a review.
    private var dailyCapWarning: String? {
        let perSubreview = store.defaults.maxCostUsdPerSubreview
        guard dailyCapEnabled, perSubreview > 0, perSubreview > dailyCapUsd else { return nil }
        return String(
            format: "The daily cap is $%.2f, so a subreview can never reach $%.2f. Raise the daily cap in %@.",
            dailyCapUsd, perSubreview, SettingsDestination.general.settingsPath
        )
    }
}
