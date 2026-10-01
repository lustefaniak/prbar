import CEL
import CELSwift
import Foundation

/// What a rule can read about a change. The field names are the rules'
/// vocabulary (`pr.changed_files`, snake case through `Rules.coding`), so
/// renaming a property breaks every policy that reads it: treat this as a
/// file format, not an implementation detail.
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
    var baseRef: String
    var headRef: String
    var draft: Bool
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    /// The viewer is a requested reviewer.
    var requested: Bool
    /// The viewer opened it.
    var authored: Bool
    /// Another human approved or requested changes.
    var reviewedByOthers: Bool
    /// Some PRBar already posted a verdict for this head commit.
    var prbarVerdictAtHead: Bool
    /// Work in a local checkout (`prbar-review <dir>`), not a pull request.
    var local: Bool

    init(_ pr: InboxPR) {
        repo = pr.nameWithOwner
        owner = pr.owner
        name = pr.repo
        number = pr.number
        title = pr.title
        body = pr.body
        author = pr.author
        baseRef = pr.baseRef
        headRef = pr.headRef
        draft = pr.isDraft
        additions = pr.totalAdditions
        deletions = pr.totalDeletions
        changedFiles = pr.changedFiles
        requested = pr.role == .reviewRequested || pr.role == .both
        authored = pr.role == .authored || pr.role == .both
        reviewedByOthers = pr.isReviewedByOthers
        prbarVerdictAtHead = pr.hasPRBarVerdictAtHead
        local = pr.local != nil
    }
}

struct FindingFacts: Codable, Sendable, Hashable, CELNamedType {
    static let celTypeName = "prbar.Finding"

    var path: String
    var lineStart: Int
    var lineEnd: Int
    var severity: AnnotationSeverity
    var title: String

    init(_ annotation: DiffAnnotation) {
        path = annotation.path
        lineStart = annotation.lineStart
        lineEnd = annotation.lineEnd
        severity = annotation.severity
        title = annotation.displayTitle
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

    init(_ review: AggregatedReview, provider: ProviderID) {
        verdict = review.verdict.rawValue
        confidence = review.confidence
        self.provider = provider.rawValue
        findings = review.annotations.map(FindingFacts.init)
        maxSeverity = review.annotations.map(\.severity).max() ?? .info
        costUsd = review.costUsd
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
    /// `lists:` from prbar.yaml, e.g. `pr.author in lists.trusted`.
    var lists: [String: [String]]
}

/// The `decide` stage: what to post once the review is in.
struct DecideFacts: Codable, Sendable, Hashable {
    var pr: ChangeFacts
    var review: ReviewFacts
    var viewer: String
    var lists: [String: [String]]
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
