import SwiftUI

/// Controls shared by Settings → Review defaults and the per-repo rule
/// editor.
///
/// The two panes edit the same settings at different levels: one writes a
/// concrete `ReviewDefaults` field, the other writes an optional override
/// on a `RepoConfig`. Both end up handing a `Binding<T>` to the same
/// control here, so a range, a label, or a picker's options can't drift
/// between the pane that sets the default and the pane that overrides it.
enum ReviewSettingControls {
    // MARK: - Splitter

    @ViewBuilder
    static func splitMode(_ value: Binding<SplitMode>) -> some View {
        Picker("Mode", selection: value) {
            Text("Per-subfolder").tag(SplitMode.perSubfolder)
            Text("Single review").tag(SplitMode.single)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    static func unmatchedStrategy(_ value: Binding<UnmatchedStrategy>) -> some View {
        Picker("Unmatched", selection: value) {
            Text("Review at root").tag(UnmatchedStrategy.reviewAtRoot)
            Text("Skip review").tag(UnmatchedStrategy.skipReview)
            Text("Group as <other>").tag(UnmatchedStrategy.groupAsOther)
        }
    }

    @ViewBuilder
    static func minFilesPerSubreview(_ value: Binding<Int>) -> some View {
        Stepper("Min files / subreview: \(value.wrappedValue)", value: value, in: 1...100)
    }

    @ViewBuilder
    static func maxParallelSubreviews(_ value: Binding<Int>) -> some View {
        Stepper("Max parallel subreviews: \(value.wrappedValue)", value: value, in: 1...10)
            .help("Each subreview runs its own AI call under its own cost cap, so this multiplies what a single PR can spend.")
    }

    @ViewBuilder
    static func collapseAboveSubreviewCount(_ value: Binding<Int>) -> some View {
        Stepper(
            "Collapse above N subreviews: \(value.wrappedValue == 0 ? "off" : "\(value.wrappedValue)")",
            value: value,
            in: 0...20
        )
        .help("Fold a PR that splits into more than N subreviews back into one repo-root review. 0 turns it off. Ignored in sandboxed mode, where splitting is what keeps cost down.")
    }

    // MARK: - AI

    @ViewBuilder
    static func toolMode(_ value: Binding<ToolMode>) -> some View {
        Picker("Tool mode", selection: value) {
            Text("Sandboxed — explore a real checkout via git").tag(ToolMode.sandboxed)
            Text("Minimal — read-only code exploration, inlined diff").tag(ToolMode.minimal)
            Text("None — pure prompt, no exploration").tag(ToolMode.none)
        }
    }

    @ViewBuilder
    static func customSystemPrompt(_ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: value)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.2))
                )
            Text("Appended after the base system prompt unless you replace it below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Budgets

    /// Free-text currency rather than a slider: the old 0.05–3.00 slider
    /// made a large PR or a high-effort model unreviewable at any price,
    /// and slider granularity is the wrong shape for money anyway.
    @ViewBuilder
    static func costCap(_ value: Binding<Double>, label: String = "Max cost / subreview") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                TextField(
                    "3.00",
                    value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = max(0, $0) }),
                    format: .currency(code: "USD")
                )
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            }
            Text(value.wrappedValue == 0
                 ? "Uncapped — only the daily cap in Settings → General stops a run."
                 : "The provider is killed mid-stream once a subreview's reported spend passes this.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    static func maxToolCalls(_ value: Binding<Int>) -> some View {
        Stepper("Max tool calls / subreview: \(value.wrappedValue)", value: value, in: 0...50)
            .help("Informational only — exceeding it is logged, not fatal. claude fires a couple of ambient tools we can't disable.")
    }

    @ViewBuilder
    static func reviewTimeout(_ value: Binding<Int>) -> some View {
        Stepper("Review timeout / subreview: \(value.wrappedValue) s", value: value, in: 60...1800, step: 30)
            .help("Wall-clock ceiling per subreview. Sandboxed reviews explore a worktree over several turns and can take minutes on a large PR — too tight a value kills the run mid-flight (exited 143).")
    }

    // MARK: - Risk brief

    @ViewBuilder
    static func churnWindowDays(_ value: Binding<Int>) -> some View {
        Stepper(
            "Churn window: \(value.wrappedValue == 0 ? "off" : "\(value.wrappedValue) days")",
            value: value,
            in: 0...365,
            step: 15
        )
        .help("0 drops the churn term and leaves the rest of the brief intact. Commit depth below is usually the binding constraint, not this.")
    }

    @ViewBuilder
    static func churnHistoryDepth(_ value: Binding<Int>) -> some View {
        Stepper("Commit depth fetched: \(value.wrappedValue)", value: value, in: 100...5000, step: 100)
            .help("Deepening a blobless clone is cheap — it carries commits and trees, never file contents. 1000 commits spans roughly 3 weeks on a busy monorepo.")
    }

    // MARK: - Notifications

    @ViewBuilder
    static func notifyPolicy(_ value: Binding<NotifyPolicy>) -> some View {
        Picker("Notify", selection: value) {
            Text("One batch once triage settles").tag(NotifyPolicy.batchSettled)
            Text("As each PR becomes ready").tag(NotifyPolicy.eachReady)
        }
    }

    // MARK: - Patterns

    /// Newline-separated pattern editor. Holds its text in local `@State`
    /// because round-tripping through a filtered `[String]` erases the
    /// newline on every keystroke, which makes Return look broken.
    struct PatternEditor: View {
        let title: String
        let footnote: String
        @Binding var patterns: [String]

        @State private var text: String = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout)
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2))
                    )
                    .onChange(of: text) { _, newValue in
                        patterns = Self.parse(newValue)
                    }
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onAppear { text = patterns.joined(separator: "\n") }
        }

        static func parse(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isNewline || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - Auto-review

/// The auto-approve gate set. Extracted so the app-level defaults and a
/// repo rule present an identical set of gates.
struct AutoApproveEditor: View {
    @Binding var config: AutoApproveConfig

    var body: some View {
        Toggle("Enable auto-approve", isOn: $config.enabled)
            .help("Fires after AI review with a 30 s undo banner before posting.")
        Group {
            HStack {
                Text("Min confidence: \(String(format: "%.2f", config.minConfidence))")
                Slider(value: $config.minConfidence, in: 0.5...1.0, step: 0.01)
            }
            Toggle("Per-provider confidence floors", isOn: perProviderBinding)
                .help("Claude and codex don't calibrate confidence the same way — one shared floor over-trusts whichever is looser.")
            if config.claudeMinConfidence != nil || config.codexMinConfidence != nil {
                ConfidenceFloorSlider(
                    label: "Claude",
                    value: ConfidenceFloorSlider.binding($config.claudeMinConfidence, fallback: config.minConfidence)
                )
                ConfidenceFloorSlider(
                    label: "Codex",
                    value: ConfidenceFloorSlider.binding($config.codexMinConfidence, fallback: config.minConfidence)
                )
            }

            Toggle("Also auto-approve \"Approve with notes\" verdicts",
                   isOn: $config.allowApproveWithNotes)
                .help("The .comment verdict means the AI approves but has observations. Off by default — the notes usually want a human read.")

            Picker("Tolerate annotations up to", selection: $config.maxAnnotationSeverity) {
                ForEach(AnnotationSeverity.allCases, id: \.self) { severity in
                    Text(severity.displayName).tag(severity)
                }
            }
            Stepper("Max annotations: \(config.maxAnnotations == 0 ? "unlimited" : "\(config.maxAnnotations)")",
                    value: $config.maxAnnotations, in: 0...100)
                .help("A review with 30 nitpicks is worth reading even when none of them block.")

            Stepper("Max additions: \(capLabel(config.maxAdditions))",
                    value: $config.maxAdditions, in: 0...10000, step: 50)
            Stepper("Max deletions: \(capLabel(config.maxDeletions))",
                    value: $config.maxDeletions, in: 0...10000, step: 50)
            Stepper("Max changed files: \(capLabel(config.maxChangedFiles))",
                    value: $config.maxChangedFiles, in: 0...500, step: 5)

            Toggle("Post \"Auto-approved by PRBar\" comment",
                   isOn: $config.postAttributionComment)
                .help("Off: a bare approval, no comment body. On: adds the attribution line with the confidence score.")
            Toggle("Post AI annotations as inline comments",
                   isOn: $config.postInlineAnnotations)
                .help("Annotations that don't land on a line of the diff are dropped — GitHub rejects them.")
        }
        .disabled(!config.enabled)
        .opacity(config.enabled ? 1 : 0.5)
    }

    private var perProviderBinding: Binding<Bool> {
        Binding(
            get: { config.claudeMinConfidence != nil || config.codexMinConfidence != nil },
            set: { on in
                let seed = config.minConfidence
                config.claudeMinConfidence = on ? seed : nil
                config.codexMinConfidence = on ? seed : nil
            }
        )
    }

    private func capLabel(_ value: Int) -> String {
        value == 0 ? "unlimited" : "\(value)"
    }
}

/// The auto-deny gate set — the mirror of `AutoApproveEditor`.
struct AutoDenyEditor: View {
    @Binding var config: AutoDenyConfig

    var body: some View {
        Picker("On a request-changes verdict", selection: $config.action) {
            ForEach(AutoDenyAction.allCases, id: \.self) { action in
                Text(action.displayName).tag(action)
            }
        }
        .help("\"Flag in PRBar only\" never posts to GitHub — it surfaces the PR in the banner and leaves the review to you.")
        Group {
            HStack {
                Text("Min confidence: \(String(format: "%.2f", config.minConfidence))")
                Slider(value: $config.minConfidence, in: 0.5...1.0, step: 0.01)
            }
            Toggle("Per-provider confidence floors", isOn: perProviderBinding)
            if config.claudeMinConfidence != nil || config.codexMinConfidence != nil {
                ConfidenceFloorSlider(
                    label: "Claude",
                    value: ConfidenceFloorSlider.binding($config.claudeMinConfidence, fallback: config.minConfidence)
                )
                ConfidenceFloorSlider(
                    label: "Codex",
                    value: ConfidenceFloorSlider.binding($config.codexMinConfidence, fallback: config.minConfidence)
                )
            }

            Picker("Corroborating severity", selection: $config.requiredSeverity) {
                ForEach(AnnotationSeverity.allCases, id: \.self) { severity in
                    Text("\(severity.displayName) or above").tag(severity)
                }
            }
            Stepper("Need at least \(config.minMatchingAnnotations) matching annotation(s)",
                    value: $config.minMatchingAnnotations, in: 0...20)
                .help("0 lets the verdict alone fire. A summary-only rejection is hard for the author to action.")
            Stepper("Max additions: \(config.maxAdditions == 0 ? "unlimited" : "\(config.maxAdditions)")",
                    value: $config.maxAdditions, in: 0...10000, step: 50)
                .help("Skip auto-deny above this size — a sprawling PR's pushback reads better authored by a human.")
            Toggle("Post AI annotations as inline comments",
                   isOn: $config.postInlineAnnotations)
                .disabled(config.action == .flagOnly)
        }
        .disabled(config.action == .off)
        .opacity(config.action == .off ? 0.5 : 1)
    }

    private var perProviderBinding: Binding<Bool> {
        Binding(
            get: { config.claudeMinConfidence != nil || config.codexMinConfidence != nil },
            set: { on in
                let seed = config.minConfidence
                config.claudeMinConfidence = on ? seed : nil
                config.codexMinConfidence = on ? seed : nil
            }
        )
    }
}

struct ConfidenceFloorSlider: View {
    let label: String
    let value: Binding<Double>

    var body: some View {
        HStack {
            Text("\(label): \(String(format: "%.2f", value.wrappedValue))")
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0.5...1.0, step: 0.01)
        }
        .padding(.leading, 16)
    }

    /// Surfaces an optional floor as a plain slider value. Writing always
    /// sets a concrete number; clearing back to "inherit" happens through
    /// the per-provider toggle, not the slider.
    static func binding(_ source: Binding<Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0 }
        )
    }
}
