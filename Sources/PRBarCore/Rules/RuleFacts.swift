import CEL
import CELSwift
import Foundation

/// What a rule can read about a change. The field names are the rules'
/// vocabulary (`pr.changed_files`, snake case through `Rules.coding`), so
/// renaming a property breaks every policy that reads it: treat this as a
/// file format, not an implementation detail. `docs/rules.md` lists them.
struct ChangeFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Change"

    /// `owner/name`.
    var repo: String
    var owner: String
    var name: String
    /// 0 for a local review.
    var number: Int
    var title: String
    var body: String
    var author: String
    /// GitHub's `authorAssociation`: `MEMBER`, `OWNER`, `COLLABORATOR`,
    /// `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `NONE`;
    /// empty when unknown.
    var authorAssociation: String
    var authorIsBot: Bool
    var baseRef: String
    var headRef: String
    var labels: [String]
    var draft: Bool
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var createdAt: Date?
    var updatedAt: Date?
    var headCommittedAt: Date?
    /// Since it was opened, and since it last changed.
    var age: Duration?
    var idle: Duration?
    /// The viewer is a requested reviewer.
    var requested: Bool
    /// The viewer opened it.
    var authored: Bool
    var requestedReviewers: [String]
    var requestedTeams: [String]
    /// People's reviews, newest last.
    var reviews: [PersonReviewFacts]
    /// Another human approved or requested changes.
    var reviewedByOthers: Bool
    /// Some PRBar already posted a verdict for this head commit.
    var prbarVerdictAtHead: Bool
    /// `passed`, `failed`, `pending` or `none`, over every check.
    var checksState: String
    var checks: [CheckFacts]
    /// The changed files. In `select`, fetched only when a rule reads them;
    /// null when that fetch failed, so `has(pr.files)` is false.
    var files: [FileFacts]?
    /// The logins of everyone who authored a commit on it. Fetched only
    /// when a rule reads it, like `files`.
    var committers: [String]?
    /// Work in a local checkout (`prbar-review <dir>`), not a pull request.
    var local: Bool

    init(_ pr: InboxPR, now: Date, files: [FileFacts]? = nil, committers: [String]? = nil) {
        repo = pr.nameWithOwner
        owner = pr.owner
        name = pr.repo
        number = pr.number
        title = pr.title
        body = pr.body
        author = pr.author
        authorAssociation = pr.authorAssociation
        authorIsBot = pr.authorIsBot
        baseRef = pr.baseRef
        headRef = pr.headRef
        labels = pr.labels
        draft = pr.isDraft
        additions = pr.totalAdditions
        deletions = pr.totalDeletions
        changedFiles = pr.changedFiles
        createdAt = pr.createdAt
        updatedAt = pr.updatedAt ?? pr.headCommittedAt
        headCommittedAt = pr.headCommittedAt
        age = pr.createdAt.map { Self.duration(from: $0, to: now) }
        idle = updatedAt.map { Self.duration(from: $0, to: now) }
        requested = pr.role == .reviewRequested || pr.role == .both
        authored = pr.role == .authored || pr.role == .both
        requestedReviewers = pr.requestedReviewers
        requestedTeams = pr.requestedTeams
        reviews = pr.humanReviews.map(PersonReviewFacts.init)
        reviewedByOthers = pr.isReviewedByOthers
        prbarVerdictAtHead = pr.hasPRBarVerdictAtHead
        checks = pr.allCheckSummaries.map(CheckFacts.init)
        checksState = Self.state(of: checks)
        self.files = files
        self.committers = committers
        local = pr.local != nil
    }

    private static func duration(from start: Date, to end: Date) -> Duration {
        .seconds(Int64(max(0, end.timeIntervalSince(start)).rounded()))
    }

    private static func state(of checks: [CheckFacts]) -> String {
        if checks.isEmpty { return "none" }
        if checks.contains(where: { $0.state == "failed" }) { return "failed" }
        if checks.contains(where: { $0.state == "pending" }) { return "pending" }
        return "passed"
    }
}

struct CheckFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Check"

    var name: String
    /// `passed`, `failed`, `pending` or `unknown`.
    var state: String

    init(_ check: CheckSummary) {
        name = check.name
        switch check.bucket {
        case .passed: state = "passed"
        case .failed: state = "failed"
        case .pending: state = "pending"
        case .unknown: state = "unknown"
        }
    }
}

struct PersonReviewFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.PersonReview"

    var author: String
    /// `approved`, `changes_requested`, `commented`, `dismissed`.
    var state: String
    var submittedAt: Date?
    var byViewer: Bool

    init(_ review: PRReviewSummary) {
        author = review.author
        state = review.state.lowercased()
        submittedAt = review.submittedAt
        byViewer = review.isFromViewer
    }
}

/// One changed file, with the risk brief's reading of it: what kind of
/// file it is and how much it deserves a close look. The same deterministic
/// ranking the review prompt is routed with, minus churn, which needs a
/// checkout.
struct FileFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.File"

    var path: String
    var additions: Int
    var deletions: Int
    /// `source`, `test`, `manifest`, `generated`, `docs`.
    var kind: String
    /// The path names a sensitive area (auth, billing, migrations, …).
    var sensitive: Bool
    /// 0 to 1: size, a source file changed without its test, a sensitive
    /// area; damped for generated files and docs.
    var risk: Double

    /// Files with their counts, in the order given.
    static func list(_ files: [(path: String, additions: Int, deletions: Int)]) -> [FileFacts] {
        let brief = RiskBrief.compute(
            paths: files.map(\.path),
            added: Dictionary(files.map { ($0.path, $0.additions) }, uniquingKeysWith: +),
            removed: Dictionary(files.map { ($0.path, $0.deletions) }, uniquingKeysWith: +))
        let rows = Dictionary(brief.rows.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return files.map { file in
            let row = rows[file.path]
            return FileFacts(
                path: file.path, additions: file.additions, deletions: file.deletions,
                kind: (row?.fileClass ?? RiskBrief.classify(file.path)).rawValue,
                sensitive: RiskBrief.sensitiveHit(file.path) != nil,
                risk: row?.score ?? 0)
        }
    }

    /// The files of a unified diff.
    static func list(diff: String) -> [FileFacts] {
        var order: [String] = []
        var added: [String: Int] = [:]
        var removed: [String: Int] = [:]
        for hunk in DiffParser.parse(diff) {
            if !order.contains(hunk.filePath) { order.append(hunk.filePath) }
            for line in hunk.lines {
                switch line {
                case .added: added[hunk.filePath, default: 0] += 1
                case .removed: removed[hunk.filePath, default: 0] += 1
                case .context: break
                }
            }
        }
        return list(order.map { ($0, added[$0] ?? 0, removed[$0] ?? 0) })
    }
}

struct FindingFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Finding"

    var path: String
    var lineStart: Int
    var lineEnd: Int
    var severity: AnnotationSeverity
    var title: String
    var body: String

    init(_ annotation: DiffAnnotation) {
        path = annotation.path
        lineStart = annotation.lineStart
        lineEnd = annotation.lineEnd
        severity = annotation.severity
        title = annotation.displayTitle
        body = annotation.body
    }
}

/// One folder's review, when a monorepo PR was split.
struct SubreviewFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Subreview"

    /// The folder, empty for the repository root.
    var path: String
    var verdict: String
    var confidence: Double
    var findings: Int

    init(_ outcome: SubreviewOutcome) {
        path = outcome.subpath
        verdict = outcome.result.verdict.rawValue
        confidence = outcome.result.confidence
        findings = outcome.result.annotations.count
    }
}

/// A review of an earlier commit of the same PR.
struct PriorReviewFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.PriorReview"

    var headSha: String
    var verdict: String
    var confidence: Double
    var findings: Int
    var maxSeverity: AnnotationSeverity

    init(_ prior: PriorReview) {
        headSha = prior.headSha
        verdict = prior.aggregated.verdict.rawValue
        confidence = prior.aggregated.confidence
        findings = prior.aggregated.annotations.count
        maxSeverity = prior.aggregated.annotations.map(\.severity).max() ?? .info
    }
}

struct ReviewFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Review"

    /// `approve`, `comment` (approve with notes), `request_changes`, `abstain`.
    var verdict: String
    var confidence: Double
    /// `claude` or `codex`.
    var provider: String
    var findings: [FindingFacts]
    /// The highest finding severity, `severity.info` when there are none, so
    /// `review.max_severity <= severity.suggestion` holds for a clean review.
    var maxSeverity: AnnotationSeverity
    var costUsd: Double
    /// Per folder, when the PR was split; one entry otherwise.
    var subreviews: [SubreviewFacts]
    /// Reviews of earlier commits that were never posted, oldest first.
    var prior: [PriorReviewFacts]

    init(_ review: AggregatedReview, provider: ProviderID, prior: [PriorReview] = []) {
        verdict = review.verdict.rawValue
        confidence = review.confidence
        self.provider = provider.rawValue
        findings = review.annotations.map(FindingFacts.init)
        maxSeverity = review.annotations.map(\.severity).max() ?? .info
        costUsd = review.costUsd
        subreviews = review.perSubreview.map(SubreviewFacts.init)
        self.prior = prior.map(PriorReviewFacts.init)
    }
}

/// What the layers under a rule would decide: the prbar.yaml settings, or a
/// lower layer of rules. A rule reads it to adjust that answer instead of
/// restating it: `below.action == "approve" && !(pr.author in lists.oldest)`.
struct BelowFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Below"

    /// `select`: `review` or `skip`. `decide`: `approve`, `request_changes`,
    /// `comment`, `share`, `flag` or `none`.
    var action: String
    /// Why, in words; empty when there is nothing to say.
    var reason: String
    /// The id of the rule that decided, empty when the settings did.
    var rule: String
    /// `settings`, or `repo` for the reviewed repository's rules.
    var source: String

    /// A lower layer's matched rule, as the next layer up sees it.
    static func rule(_ id: String, action: String, reason: String?, layer: RuleLayer) -> BelowFacts {
        BelowFacts(action: action, reason: reason ?? "", rule: id, source: layer.rawValue)
    }

    static func settings(_ action: String, reason: String = "") -> BelowFacts {
        BelowFacts(action: action, reason: reason, rule: "", source: "settings")
    }

    /// What the settings' auto-review decision means as an action.
    static func settings(_ decision: AutoReviewPolicy.Decision) -> BelowFacts {
        switch decision {
        case .approve: return .settings("approve")
        case .share: return .settings("share")
        case .deny(.requestChanges): return .settings("request_changes")
        case .deny(.comment): return .settings("comment")
        case .deny(.flagOnly), .deny(.off): return .settings("flag")
        case .skip(let reason): return .settings("none", reason: reason)
        }
    }
}

/// Why a review is being considered.
enum RuleTrigger: String, Codable, Sendable, Hashable, CaseIterable {
    /// A poll found the viewer requested on it.
    case reviewRequested = "review_requested"
    /// `prbar-review <pr>` without `--force`.
    case command
    /// A coding agent through MCP.
    case agent
}

/// The `select` stage: whether to review at all.
struct SelectFacts: Codable, Sendable, Hashable {
    var pr: ChangeFacts
    var trigger: RuleTrigger
    /// The viewer's GitHub login.
    var viewer: String
    /// `rules/lists.yaml`, e.g. `pr.author in lists.trusted`.
    var lists: [String: [String]]
    var now: Date
    /// Null only in records written before it existed.
    var below: BelowFacts?
}

/// The `decide` stage: what to post once the review is in.
struct DecideFacts: Codable, Sendable, Hashable {
    var pr: ChangeFacts
    var review: ReviewFacts
    var viewer: String
    var lists: [String: [String]]
    var now: Date
    var below: BelowFacts?
}

/// Severities compare by rank in rules (`f.severity >= severity.warning`),
/// with `severity.<name>` constants for the ranks.
extension AnnotationSeverity: CELValueRepresentable {
    static var celType: CELType { .int }
    var celValue: Value { .int(Int64(rank)) }

    init(celValue: Value) throws {
        guard let rank = celValue.asInt, let match = Self.allCases.first(where: { Int64($0.rank) == rank }) else {
            throw EvalError("not a severity: \(celValue)")
        }
        self = match
    }
}
