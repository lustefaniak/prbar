import Foundation
import Observation
import Yams

/// The Rules tab's state: the user's rule files, the edits not saved yet,
/// and what they are tried on (a PR, or a recorded decision). Every edit
/// re-evaluates after a short pause, and the impact of the edits is
/// replayed over the recorded decisions, so the effect of a change is
/// visible before it is saved.
@MainActor
@Observable
final class RulesWorkbench {
    enum Target: Equatable {
        case pr(InboxPR)
        case record(RuleRecordSummary)

        var title: String {
            switch self {
            case .pr(let pr): return "\(pr.nameWithOwner)#\(pr.number) \(pr.title)"
            case .record(let record): return "\(record.pr) \(record.title)"
            }
        }
    }

    private(set) var directory = ""
    /// As saved, by path relative to the directory.
    private(set) var saved: [String: String] = [:]
    /// Edited text, by path; a path absent from `saved` is a new file.
    private(set) var edits: [String: String] = [:]
    /// Saved files deleted in the edits; the editor still shows their
    /// saved text.
    private(set) var removed: Set<String> = []
    private(set) var issue: String?
    var selectedPath: String?

    private(set) var records: [RuleRecordSummary] = []
    private(set) var target: Target?
    private(set) var explanation: RulesExplanation?
    private(set) var replay: RuleReplayResult?
    private(set) var impact: RuleImpact?
    /// How far back the impact looks.
    var impactDays = 60

    private(set) var isEvaluating = false
    /// What the last conversion of prbar.yaml's `repos:` did, in words.
    private(set) var converted: String?
    /// The last request that failed, in words.
    private(set) var error: String?

    @ObservationIgnored
    private let call: Caller
    @ObservationIgnored
    private var pending: Task<Void, Never>?
    /// Each evaluation is numbered so a slow answer to an older draft can't
    /// replace a newer one.
    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    var debounce: Duration = .milliseconds(400)

    /// One API request; the session's `call` in the app, a stub in tests.
    struct Caller: Sendable {
        var files: @Sendable () async throws -> RuleFilesResult
        var records: @Sendable (Int?) async throws -> [RuleRecordSummary]
        var explain: @Sendable (PRReference, RuleDraft?) async throws -> RulesExplanation
        var replay: @Sendable (UUID, RuleDraft?) async throws -> RuleReplayResult
        var impact: @Sendable (RuleDraft, Int?) async throws -> RuleImpact
        var save: @Sendable (SaveRuleFileParams) async throws -> Void
        var convert: @Sendable () async throws -> RulesConvert.Written = {
            throw RPCError(code: RPCError.refused, message: "not available")
        }
        var accept: @Sendable (UUID) async throws -> Void = { _ in
            throw RPCError(code: RPCError.refused, message: "not available")
        }
        var reject: @Sendable (UUID) async throws -> Void = { _ in
            throw RPCError(code: RPCError.refused, message: "not available")
        }
    }

    init(call: Caller) {
        self.call = call
    }

    convenience init(session: ServerSession) {
        self.init(call: Caller(
            files: { @MainActor in try await session.call(.ruleFiles, APIEmpty(), as: RuleFilesResult.self) },
            records: { @MainActor limit in
                try await session.call(.ruleRecords, RuleRecordsParams(limit: limit), as: [RuleRecordSummary].self)
            },
            explain: { @MainActor pr, draft in
                try await session.call(.explainRules, ExplainRulesParams(pr: pr, draft: draft), as: RulesExplanation.self)
            },
            replay: { @MainActor id, draft in
                try await session.call(.replayRule, ReplayRuleParams(id: id, draft: draft), as: RuleReplayResult.self)
            },
            impact: { @MainActor draft, days in
                try await session.call(.ruleImpact, RuleImpactParams(draft: draft, days: days), as: RuleImpact.self)
            },
            save: { @MainActor params in
                _ = try await session.call(.saveRuleFile, params, as: APIEmpty.self)
            },
            convert: { @MainActor in
                try await session.call(.convertRepos, ConvertReposParams(), as: RulesConvert.Written.self)
            },
            accept: { @MainActor id in
                _ = try await session.call(.acceptRuleProposal, RuleProposalParams(id: id), as: APIEmpty.self)
            },
            reject: { @MainActor id in
                _ = try await session.call(.rejectRuleProposal, RuleProposalParams(id: id), as: APIEmpty.self)
            }))
    }

    // MARK: - files

    /// Every file, saved or new, in the order the rules run them.
    var paths: [String] {
        Set(saved.keys).union(edits.keys).sorted { Self.order($0) < Self.order($1) }
    }

    private static func order(_ path: String) -> String {
        if path == "lists.yaml" { return "0" }
        if path.hasPrefix("configure/") { return "1" + path }
        if path.hasPrefix("select/") { return "2" + path }
        return "3" + path
    }

    func text(_ path: String) -> String {
        if isRemoved(path) { return saved[path] ?? "" }
        return edits[path] ?? saved[path] ?? ""
    }

    func isEdited(_ path: String) -> Bool {
        isRemoved(path) || (edits[path] != nil && edits[path] != saved[path])
    }

    func isRemoved(_ path: String) -> Bool { removed.contains(path) }

    var hasEdits: Bool { paths.contains(where: isEdited) }

    /// The names in lists.yaml as edited, for completion and the builder.
    var listNames: [String] {
        let text = self.text("lists.yaml")
        guard let lists = try? YAMLDecoder().decode([String: [String]]?.self, from: text) else { return [] }
        return lists.keys.sorted()
    }

    /// The lines of `path` a problem names: `<path>:<line>:<col>`, or
    /// for a YAML syntax error `<path>:-1:0: yaml: line <n>`.
    func problemLines(_ path: String) -> Set<Int> {
        guard let problem = draftProblem ?? issue else { return [] }
        var lines: Set<Int> = []
        let marker = "/" + path + ":"
        var rest = Substring(problem)
        while let range = rest.range(of: marker) {
            var after = rest[range.upperBound...]
            if after.hasPrefix("-1:0: yaml: line ") { after = after.dropFirst("-1:0: yaml: line ".count) }
            if let line = Int(after.prefix { $0.isNumber }) { lines.insert(line) }
            rest = rest[range.upperBound...]
        }
        return lines
    }

    /// A problem as the tab shows it: paths relative to the rules
    /// directory, `file, line n:` for positions, without the compiler's
    /// framing.
    func readable(_ problem: String) -> String {
        var text = problem
        if !directory.isEmpty { text = text.replacingOccurrences(of: directory + "/", with: "") }
        text = text.replacingOccurrences(of: "rules don't compile:\n", with: "")
        text = text.replacingOccurrences(
            of: #"(\S+\.ya?ml):-1:0: yaml: line (\d+): "#, with: "$1, line $2: ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(\S+\.ya?ml):(\d+):\d+: "#, with: "$1, line $2: ", options: .regularExpression)
        text = text.replacingOccurrences(of: "ERROR: ", with: "")
        return text
    }

    /// `path`, or the same name with a number when it is taken.
    func freePath(_ path: String) -> String {
        guard paths.contains(path) else { return path }
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().relativePath
        var n = 2
        while paths.contains("\(dir)/\(stem)-\(n).yaml") { n += 1 }
        return "\(dir)/\(stem)-\(n).yaml"
    }

    /// Adds the lists that are missing from lists.yaml, as an edit.
    func addLists(_ lists: [String: [String]]) {
        let missing = lists.keys.sorted().filter { !listNames.contains($0) }
        guard !missing.isEmpty else { return }
        var text = self.text("lists.yaml")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        for name in missing {
            text += "\(name): [\((lists[name] ?? []).joined(separator: ", "))]\n"
        }
        edits["lists.yaml"] = text
    }

    /// Starts a file from an example, with the lists it reads.
    func start(_ example: RuleExamples.Example) {
        addLists(example.lists)
        newFile(freePath(example.path), text: example.text)
    }

    /// Whether the file exists on disk, so it can be opened elsewhere.
    func isSaved(_ path: String) -> Bool { saved[path] != nil }

    /// The unsaved edits, as the server evaluates them.
    var draft: RuleDraft? {
        let files = edits.filter { saved[$0.key] != $0.value && !removed.contains($0.key) }
        return files.isEmpty && removed.isEmpty ? nil : RuleDraft(files: files, removed: removed.sorted())
    }

    func load() async {
        do {
            let result = try await call.files()
            directory = result.directory
            saved = result.files
            issue = result.issue
            edits = edits.filter { saved[$0.key] != $0.value }
            removed = removed.filter { saved[$0] != nil }
            if selectedPath.map({ !paths.contains($0) }) ?? true { selectedPath = paths.first }
            records = try await call.records(200)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        evaluateSoon(after: .zero)
    }

    func edit(_ path: String, _ text: String) {
        guard text != self.text(path) else { return }
        removed.remove(path)
        edits[path] = text
        evaluateSoon()
    }

    func revert(_ path: String) {
        edits.removeValue(forKey: path)
        removed.remove(path)
        if saved[path] == nil, selectedPath == path { selectedPath = paths.first }
        evaluateSoon(after: .zero)
    }

    /// Starts a policy file in `stage`, or the lists file.
    func newFile(_ path: String, text: String) {
        guard RuleDirectory.isRuleFile(path), saved[path] == nil, edits[path] == nil else { return }
        edits[path] = text
        selectedPath = path
        evaluateSoon(after: .zero)
    }

    func save(_ path: String) async {
        let text = isRemoved(path) ? nil : edits[path]
        guard text != nil || isRemoved(path) else { return }
        do {
            try await call.save(SaveRuleFileParams(path: path, text: text, base: saved[path]))
            saved[path] = text
            edits.removeValue(forKey: path)
            removed.remove(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await load()
    }

    /// What a new file starts with: a rule that compiles, to edit from.
    static func template(for path: String) -> String {
        if path == "lists.yaml" {
            return "# Named lists of logins, read in rules as lists.<name>.\nteam: []\n"
        }
        let stage = path.split(separator: "/").first.map(String.init) ?? "decide"
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let file = RuleSchema.File(rawValue: stage) ?? .decide
        let schema = "# yaml-language-server: $schema=\(RuleSchema.url(file))\n"
        if stage == "configure" {
            return schema + """
                # Settings for some repositories; what this doesn't set comes
                # from Review defaults. `repo.full_name`, `repo.owner`, `repo.name`.
                name: \(name)
                rule:
                  match:
                    - condition: glob(repo.full_name, "my-org/*")
                      output:
                        rule: \(name)
                        max_cost_usd_per_subreview: 2
                        review_drafts: false

                """
        }
        if stage == "select" {
            return schema + """
                name: \(name)
                rule:
                  match:
                    - condition: pr.draft
                      output:
                        rule: \(name)
                        action: skip
                        reason: drafts wait until they are ready

                """
        }
        return schema + """
            name: \(name)
            rule:
              match:
                - condition: below.action == "approve" && pr.additions > 400
                  output:
                    rule: \(name)
                    action: share

            """
    }

    /// Turns prbar.yaml's `repos:` into a configure rule.
    func convert() async {
        do {
            let written = try await call.convert()
            converted = "Converted \(written.entries) repos: entries into \(written.rulePath). Each of the \(written.checked.count) repositories PRBar has seen resolves to the same settings as before. The old prbar.yaml is kept as \(written.backupPath)."
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await load()
    }

    // MARK: - proposals

    /// Opens a proposal's files as unsaved edits, so it is tried on PRs
    /// and on the record like any edit before it is accepted. The files it
    /// deletes are deleted in the edits too, or the preview would run
    /// rules that accepting it never leaves on disk.
    func open(_ proposal: RuleProposal) {
        for (path, text) in proposal.draft.files where RuleDirectory.isRuleFile(path) {
            edits[path] = text
            removed.remove(path)
        }
        for path in proposal.draft.removed where saved[path] != nil {
            edits.removeValue(forKey: path)
            removed.insert(path)
        }
        selectedPath = (Array(proposal.draft.files.keys) + proposal.draft.removed).sorted().first ?? selectedPath
        evaluateSoon(after: .zero)
    }

    func accept(_ proposal: RuleProposal) async {
        do {
            try await call.accept(proposal.id)
            for path in proposal.draft.files.keys where edits[path] == proposal.draft.files[path] {
                edits.removeValue(forKey: path)
            }
            removed.subtract(proposal.draft.removed)
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await load()
    }

    func reject(_ proposal: RuleProposal) async {
        do {
            try await call.reject(proposal.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - evaluation

    func choose(_ target: Target?) {
        self.target = target
        explanation = nil
        replay = nil
        evaluateSoon(after: .zero)
    }

    func evaluateSoon(after delay: Duration? = nil) {
        pending?.cancel()
        let delay = delay ?? debounce
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    func evaluate() async {
        generation += 1
        let mine = generation
        let draft = draft
        let target = target
        isEvaluating = true
        defer { if mine == generation { isEvaluating = false } }
        do {
            var explanation: RulesExplanation?
            var replay: RuleReplayResult?
            switch target {
            case .pr(let pr):
                explanation = try await call.explain(PRReference(nodeId: pr.nodeId), draft)
            case .record(let record):
                replay = try await call.replay(record.id, draft)
            case nil:
                break
            }
            var impact: RuleImpact?
            if let draft { impact = try await call.impact(draft, impactDays) }
            guard mine == generation else { return }
            self.explanation = explanation
            self.replay = replay
            self.impact = impact
            error = nil
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Why the draft can't be evaluated, from whichever answer says so.
    var draftProblem: String? {
        explanation?.draftProblem ?? replay?.draftProblem ?? impact?.draftProblem
    }
}
