import Foundation
import Observation

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
            }))
    }

    // MARK: - files

    /// Every file, saved or new, in the order the rules run them.
    var paths: [String] {
        Set(saved.keys).union(edits.keys).sorted { Self.order($0) < Self.order($1) }
    }

    private static func order(_ path: String) -> String {
        if path == "lists.yaml" { return "0" }
        if path.hasPrefix("select/") { return "1" + path }
        return "2" + path
    }

    func text(_ path: String) -> String {
        edits[path] ?? saved[path] ?? ""
    }

    func isEdited(_ path: String) -> Bool {
        edits[path] != nil && edits[path] != saved[path]
    }

    var hasEdits: Bool { paths.contains(where: isEdited) }

    /// The unsaved edits, as the server evaluates them.
    var draft: RuleDraft? {
        let files = edits.filter { saved[$0.key] != $0.value }
        return files.isEmpty ? nil : RuleDraft(files: files)
    }

    func load() async {
        do {
            let result = try await call.files()
            directory = result.directory
            saved = result.files
            issue = result.issue
            edits = edits.filter { saved[$0.key] != $0.value }
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
        edits[path] = text
        evaluateSoon()
    }

    func revert(_ path: String) {
        edits.removeValue(forKey: path)
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
        guard let text = edits[path] else { return }
        do {
            try await call.save(SaveRuleFileParams(path: path, text: text, base: saved[path]))
            saved[path] = text
            edits.removeValue(forKey: path)
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
        let stage = path.hasPrefix("select/") ? "select" : "decide"
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let schema = "# yaml-language-server: $schema=\(RuleSchema.url(stage == "select" ? .select : .decide))\n"
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
