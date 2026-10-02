import SwiftUI

/// Settings → Rules. The user's rule files with an editor, and beside it
/// what the rules decide for a chosen PR or recorded decision, every
/// condition with the values it read. Edits are evaluated as they are
/// typed, and replayed over the recorded decisions to show which ones
/// they would change, before anything is saved.
struct RulesSettings: View {
    @Environment(ServerSession.self) private var session
    @Environment(InboxModel.self) private var inbox
    @Environment(ConfigModel.self) private var config
    @State private var workbench: RulesWorkbench?

    var body: some View {
        Group {
            if let workbench {
                RulesWorkbenchView(
                    workbench: workbench, prs: inbox.prs,
                    conversionIssue: config.needsConversion ? (config.loadIssue ?? "") : nil)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let workbench = self.workbench ?? RulesWorkbench(session: session)
            self.workbench = workbench
            await workbench.load()
            if let edit = ScreenshotMode.initialRulesEdit {
                workbench.selectedPath = edit.path
                workbench.edit(edit.path, edit.text)
            }
            if let pr = ScreenshotMode.initialRulesTarget {
                workbench.choose(.pr(pr))
            }
        }
    }
}

private struct RulesWorkbenchView: View {
    @Bindable var workbench: RulesWorkbench
    let prs: [InboxPR]
    /// Set while prbar.yaml's `repos:` couldn't be converted: why.
    let conversionIssue: String?
    @State private var newFileStage: String?
    @State private var converting = false
    @State private var newFileName = ""

    var body: some View {
        VStack(spacing: 0) {
            if let conversionIssue {
                HStack(alignment: .top) {
                    Text(conversionIssue + "\nFix what it names, then convert again.")
                        .textSelection(.enabled)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(converting ? "Converting…" : "Convert again") {
                        converting = true
                        Task {
                            await workbench.convert()
                            converting = false
                        }
                    }
                    .disabled(converting)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
            if let converted = workbench.converted {
                banner(converted, color: .green)
            }
            if let issue = workbench.issue {
                banner(issue, color: .orange)
            }
            if let error = workbench.error {
                banner(error, color: .red)
            }
            HSplitView {
                fileList
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
                editor
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .layoutPriority(1)
                RulesResultsView(workbench: workbench, prs: prs)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(color.opacity(0.12))
    }

    // MARK: - files

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $workbench.selectedPath) {
                section("Lists", paths: workbench.paths.filter { $0 == "lists.yaml" })
                section("Configure: per repository", paths: workbench.paths.filter { $0.hasPrefix("configure/") })
                section("Select: review or skip", paths: workbench.paths.filter { $0.hasPrefix("select/") })
                section("Decide: what is posted", paths: workbench.paths.filter { $0.hasPrefix("decide/") })
            }
            .listStyle(.sidebar)
            .overlay {
                if workbench.paths.isEmpty {
                    Text("No rule files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Menu {
                    Button("Configure rule: settings per repository") { startNewFile("configure") }
                    Button("Select rule") { startNewFile("select") }
                    Button("Decide rule") { startNewFile("decide") }
                    if !workbench.paths.contains("lists.yaml") {
                        Button("Lists") { workbench.newFile("lists.yaml", text: RulesWorkbench.template(for: "lists.yaml")) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New rule file")
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workbench.directory)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show the rules directory in Finder")
                .disabled(workbench.directory.isEmpty || !FileManager.default.fileExists(atPath: workbench.directory))
                Button {
                    Task { await workbench.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the rules directory again")
            }
            .padding(8)
            Text(workbench.directory)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding([.horizontal, .bottom], 8)
        }
        .popover(isPresented: Binding(get: { newFileStage != nil }, set: { if !$0 { newFileStage = nil } })) {
            newFilePopover
        }
    }

    @ViewBuilder
    private func section(_ title: String, paths: [String]) -> some View {
        if !paths.isEmpty {
            Section(title) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                        if workbench.isEdited(path) {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                                .help("Not saved")
                        }
                    }
                    .tag(path)
                }
            }
        }
    }

    private func startNewFile(_ stage: String) {
        newFileName = "50-" + (stage == "select" ? "skip" : stage == "configure" ? "settings" : "post")
        newFileStage = stage
    }

    private var newFileError: String? {
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        guard let stage = newFileStage, !name.isEmpty else { return "" }
        let path = "\(stage)/\(name).yaml"
        if !RuleDirectory.isRuleFile(path) || name.contains("/") { return "Use a plain file name." }
        if workbench.paths.contains(path) { return "\(path) exists." }
        return nil
    }

    private var newFilePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New \(newFileStage ?? "") rule").font(.headline)
            Text("Files run in name order; a number in front sets it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text("\(newFileStage ?? "")/").foregroundStyle(.secondary)
                TextField("name", text: $newFileName)
                    .frame(width: 160)
                    .onSubmit(createNewFile)
                Text(".yaml").foregroundStyle(.secondary)
            }
            if let error = newFileError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { newFileStage = nil }
                Button("Create", action: createNewFile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFileError != nil)
            }
        }
        .padding()
    }

    private func createNewFile() {
        guard newFileError == nil, let stage = newFileStage else { return }
        let path = "\(stage)/\(newFileName.trimmingCharacters(in: .whitespaces)).yaml"
        workbench.newFile(path, text: RulesWorkbench.template(for: path))
        newFileStage = nil
    }

    // MARK: - editor

    @ViewBuilder
    private var editor: some View {
        if let path = workbench.selectedPath {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(path).font(.headline.monospaced())
                    Spacer()
                    if workbench.isSaved(path) {
                        Button("Open in Editor") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: workbench.directory).appendingPathComponent(path))
                        }
                        .help("Open the saved file in your editor; it has completion for the file's structure through its JSON schema. Changes saved there show here.")
                    }
                    if workbench.isEdited(path) {
                        Button("Revert") { workbench.revert(path) }
                        Button("Save") { Task { await workbench.save(path) } }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(workbench.draftProblem != nil)
                            .help(workbench.draftProblem == nil ? "Write the file; the rules load at once" : "Fix the problem below first")
                    }
                }
                .padding(8)
                Divider()
                RuleTextEditor(path: path, workbench: workbench)
                    .frame(maxHeight: .infinity)
                if let problem = workbench.draftProblem {
                    Divider()
                    ScrollView {
                        Text(problem)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                }
            }
        } else {
            ContentUnavailableView(
                "No rules yet", systemImage: "list.bullet.rectangle",
                description: Text("Review defaults decide for every repository until a rule says otherwise. Add one with +: configure sets what differs per repository, select whether a PR is reviewed, decide what is posted. Pick a PR under Try on to see what decides it now. Nothing changes until you save."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The text of one file. Held in local state and pushed to the workbench
/// on change, so typing isn't routed through a re-derived binding.
private struct RuleTextEditor: View {
    let path: String
    let workbench: RulesWorkbench
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { text = workbench.text(path) }
            .onChange(of: path) { _, new in text = workbench.text(new) }
            .onChange(of: workbench.text(path)) { _, new in
                if new != text { text = new }
            }
            .onChange(of: text) { _, new in workbench.edit(path, new) }
    }
}

// MARK: - results

private struct RulesResultsView: View {
    let workbench: RulesWorkbench
    let prs: [InboxPR]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Try on").font(.headline)
                targetMenu
                if workbench.isEvaluating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    result
                    Divider()
                    impact
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var targetMenu: some View {
        Menu {
            Section("Inbox") {
                ForEach(prs.prefix(30)) { pr in
                    Button("\(pr.nameWithOwner)#\(pr.number) \(pr.title)") { workbench.choose(.pr(pr)) }
                }
            }
            Section("Recent decisions") {
                ForEach(workbench.records.prefix(30)) { record in
                    Button("\(record.stage.rawValue): \(record.pr) \(record.title)") { workbench.choose(.record(record)) }
                }
            }
        } label: {
            Text(workbench.target?.title ?? "Choose a PR or a decision")
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var result: some View {
        if let explanation = workbench.explanation {
            if let configured = explanation.configured {
                ConfiguredView(configured: configured)
            }
            outcomeRow("Select", explanation.selectOutcome)
            if let decide = explanation.decideOutcome {
                outcomeRow("Decide", decide)
            } else {
                Text("Decide runs on a completed review of the PR's current commit; there is none yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(explanation.layers ?? [], id: \.layer) { layer in
                if layer.select != nil || layer.decide != nil {
                    LayerTraceView(layer: layer)
                }
            }
        } else if let replay = workbench.replay {
            Text("\(replay.record.stage.rawValue) of \(replay.record.pr), recorded \(replay.record.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            outcomeRow("Recorded", replay.record.outcome)
            outcomeRow("Now", replay.now)
            if let draft = replay.draft {
                outcomeRow("Edited", draft, highlight: draft != replay.now)
            }
            if let trace = replay.draftTrace ?? replay.trace {
                TraceView(stage: replay.record.stage.rawValue.capitalized, trace: trace)
            }
        } else if workbench.target == nil {
            Text("Choose a PR from the inbox, or a recent decision, to see every condition evaluated on it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func outcomeRow(_ label: String, _ text: String?, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.bold()).frame(width: 64, alignment: .leading)
            Text(text ?? "").font(.callout)
                .foregroundStyle(highlight ? Color.orange : Color.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var impact: some View {
        Text("What the edits change").font(.headline)
        if workbench.draft == nil {
            Text("Edit a rule to see which recorded decisions of the last \(workbench.impactDays) days it would change.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let impact = workbench.impact {
            if impact.draftProblem != nil {
                Text("The edited rules don't compile yet.").font(.caption).foregroundStyle(.secondary)
            } else if impact.changes.isEmpty {
                Text("None of \(impact.examined) decisions in the last \(workbench.impactDays) days would change.")
                    .font(.callout)
            } else {
                Text("\(impact.changes.count) of \(impact.examined) decisions in the last \(workbench.impactDays) days would change:")
                    .font(.callout)
                ForEach(impact.changes) { change in
                    Button {
                        workbench.choose(.record(change.record))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(change.record.pr) \(change.record.title)").lineLimit(1)
                            Text("\(change.record.stage.rawValue): \(change.now)  →  \(change.draft)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct LayerTraceView: View {
    let layer: RuleLayerTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(layer.layer == .repo ? "The repository's rules" : "Your rules")
                .font(.subheadline.bold())
            Text(layer.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let select = layer.select { TraceView(stage: "Select", trace: select) }
            if let decide = layer.decide { TraceView(stage: "Decide", trace: decide) }
        }
    }
}

/// One stage: the answer underneath, then each policy file in order with
/// its conditions and the predicates they combine.
private struct TraceView: View {
    let stage: String
    let trace: RuleTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage).font(.caption.bold()).foregroundStyle(.secondary)
            if let below = trace.below {
                Text("below: \(below)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(Array(trace.policies.enumerated()), id: \.offset) { _, policy in
                PolicyView(policy: policy)
            }
        }
    }
}

private struct PolicyView: View {
    let policy: RuleTrace.Policy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(URL(fileURLWithPath: policy.path).lastPathComponent).font(.caption.monospaced().bold())
                Spacer()
                resultBadge
            }
            ForEach(Array(policy.conditions.enumerated()), id: \.offset) { _, condition in
                ConditionView(condition: condition)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
    }

    private var background: Color {
        switch policy.result {
        case .matched: return .green.opacity(0.10)
        case .error: return .red.opacity(0.10)
        case .noMatch, .notReached: return .secondary.opacity(0.06)
        }
    }

    @ViewBuilder
    private var resultBadge: some View {
        switch policy.result {
        case .matched(let output):
            Text(output).font(.caption).foregroundStyle(.green).lineLimit(2)
        case .noMatch:
            Text("no match").font(.caption).foregroundStyle(.secondary)
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        case .notReached:
            Text("not reached").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConditionView: View {
    let condition: RuleTrace.Condition

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ValueIcon(value: condition.value)
                Text(condition.text).font(.caption.monospaced()).textSelection(.enabled)
                Spacer(minLength: 4)
                if let line = condition.line {
                    Text("line \(line)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !(condition.terms.count == 1 && condition.terms[0].text == condition.text) {
                ForEach(Array(condition.terms.enumerated()), id: \.offset) { _, term in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ValueIcon(value: term.value)
                        Text(term.text).font(.caption.monospaced())
                    }
                    .padding(.leading, 18)
                    inputs(term.inputs).padding(.leading, 40)
                }
            } else if let term = condition.terms.first {
                inputs(term.inputs).padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private func inputs(_ inputs: [RuleTrace.Input]) -> some View {
        if !inputs.isEmpty {
            Text(inputs.map { "\($0.text) = \($0.value ?? "not evaluated")" }.joined(separator: ", "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ValueIcon: View {
    let value: String?

    var body: some View {
        switch value {
        case "true":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "false":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                .help("Not evaluated")
        case let other?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help(other)
        }
    }
}

/// What the configure rules and the repository lists set for the PR's
/// repository: the settings everything else runs with.
private struct ConfiguredView: View {
    let configured: ConfiguredSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings for \(configured.repository)").font(.subheadline.bold())
            if !configured.triaged {
                Text("Not in `repositories.triage`: review requests here aren't triaged.").font(.caption).foregroundStyle(.orange)
            }
            if configured.hidden {
                Text("In `repositories.hide`: never shown.").font(.caption).foregroundStyle(.orange)
            }
            if configured.trustsRules {
                Text("Its own .prbar/rules are read.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = configured.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if configured.rules.isEmpty {
                Text("No configure rule matches: Review defaults apply as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Review defaults, changed by \(configured.rules.joined(separator: ", ")):")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(configured.settings, id: \.self) { line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }
}
