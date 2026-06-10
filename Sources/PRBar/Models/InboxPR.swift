import Foundation

struct CheckSummary: Sendable, Hashable, Codable {
    let typename: String        // "CheckRun" | "StatusContext"
    let name: String            // workflow/check name (or context for legacy)
    let conclusion: String?     // SUCCESS | FAILURE | NEUTRAL | … (CheckRun)
    let status: String?         // QUEUED | IN_PROGRESS | COMPLETED (CheckRun) or state (StatusContext)
    /// Click-through link for the check — `detailsUrl` for CheckRuns,
    /// `targetUrl` for legacy StatusContexts. Optional: some integrations
    /// don't supply one.
    let url: String?

    /// Three coarse buckets for the UI: failed / pending / passed. Drives
    /// sorting and icon choice in `CIStatusView`. Falls through to
    /// `.unknown` when GraphQL didn't tell us anything useful.
    var bucket: Bucket {
        switch typename {
        case "CheckRun":
            switch (status ?? "").uppercased() {
            case "QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED":
                return .pending
            default: break
            }
            switch (conclusion ?? "").uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": return .passed
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                return .failed
            default: return .unknown
            }
        case "StatusContext":
            switch (status ?? "").uppercased() {
            case "SUCCESS":             return .passed
            case "PENDING", "EXPECTED": return .pending
            case "FAILURE", "ERROR":    return .failed
            default:                    return .unknown
            }
        default:
            return .unknown
        }
    }

    enum Bucket: Sendable, Hashable {
        case failed, pending, passed, unknown
    }
}

/// A human review submitted on the PR (not the AI triage). Mirrors the
/// `reviews` GraphQL connection. `isFromViewer` is resolved at map time
/// (we have `viewerLogin` there) so the UI can flag "you already reviewed"
/// without re-plumbing the viewer login down to the view.
struct PRReviewSummary: Sendable, Hashable, Codable, Identifiable {
    let author: String
    let state: String          // APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING
    let submittedAt: Date?
    let body: String
    let isFromViewer: Bool

    var id: String { "review-\(author)-\(submittedAt?.timeIntervalSince1970 ?? 0)-\(state)" }
}

/// A top-level (issue) comment on the PR conversation — distinct from
/// review-thread comments. Mirrors the `comments` GraphQL connection.
struct PRCommentSummary: Sendable, Hashable, Codable, Identifiable {
    let author: String
    let createdAt: Date?
    let body: String
    let isFromViewer: Bool

    var id: String { "comment-\(author)-\(createdAt?.timeIntervalSince1970 ?? 0)" }
}

struct InboxPR: Identifiable, Sendable, Hashable, Codable {
    var id: String { nodeId }   // GraphQL global node ID

    let nodeId: String
    let owner: String
    let repo: String
    let number: Int
    let title: String
    let body: String
    let url: URL
    let author: String
    let headRef: String
    let baseRef: String
    let headSha: String           // commit SHA at the head — for diff cache + checkout
    let isDraft: Bool
    let role: PRRole

    /// Open / closed / merged. Defaulted to `.open` so test constructors and
    /// pre-existing cached payloads (which predate the field) still load.
    var state: PRState = .open

    let mergeable: String
    let mergeStateStatus: String
    let reviewDecision: String?
    let checkRollupState: String

    let totalAdditions: Int
    let totalDeletions: Int
    let changedFiles: Int

    let hasAutoMerge: Bool
    let autoMergeEnabledBy: String?

    /// The merge strategy a pending auto-merge will use, when one is enabled
    /// (`autoMergeRequest.mergeMethod`). Defaulted so test constructors and
    /// pre-existing cached payloads don't have to supply it.
    var autoMergeMethod: MergeMethod? = nil

    let allCheckSummaries: [CheckSummary]

    /// Human reviews on this PR, oldest-first (GraphQL `reviews(last:)`
    /// order). Empty when nobody has reviewed yet. Defaulted so test
    /// constructors and old cached payloads don't have to supply it.
    var humanReviews: [PRReviewSummary] = []

    /// Top-level conversation comments, oldest-first. Empty when there's
    /// no discussion. Defaulted for the same reasons as `humanReviews`.
    var issueComments: [PRCommentSummary] = []

    /// Merge methods the repo allows (driven by repo settings + branch
    /// protection's requiresLinearHistory, both applied server-side by
    /// GitHub). Use this to filter the merge menu so we don't offer
    /// e.g. "Create merge commit" on a repo that requires linear history.
    let allowedMergeMethods: Set<MergeMethod>

    /// Whether the repo allows enabling auto-merge on PRs. Phase 2+ feature.
    let autoMergeAllowed: Bool

    /// Whether the repo deletes the head branch automatically on merge.
    /// Drives the default value of --delete-branch on `gh pr merge`.
    let deleteBranchOnMerge: Bool

    var nameWithOwner: String { "\(owner)/\(repo)" }

    /// Plain string form of the PR number — avoids SwiftUI's
    /// LocalizedStringKey grouping (which renders 20609 as "20 609").
    /// Use this in any UI string interpolation.
    var numberString: String { String(number) }

    /// True when this PR is genuinely click-to-merge ready: GitHub says
    /// `mergeStateStatus == "CLEAN"` (no conflicts, required checks
    /// passed, required reviews approved), it's not a draft, the row
    /// represents one of *my* PRs (so I'm allowed to merge it), and at
    /// least one merge method is allowed by repo policy.
    var isReadyToMerge: Bool {
        mergeStateStatus == "CLEAN"
            && !isDraft
            && !allowedMergeMethods.isEmpty
            && (role == .authored || role == .both)
    }

    /// Human-readable reason this PR can't be merged right now, or nil when
    /// it's click-to-merge ready. Drives the merge action card's status line
    /// and explains why the immediate-merge button is disabled. Ordered most-
    /// blocking first so the single surfaced reason is the actionable one.
    var mergeBlockReason: String? {
        if isReadyToMerge { return nil }
        if isDraft { return "Draft — mark ready for review to merge" }
        if allowedMergeMethods.isEmpty { return "No merge method enabled for this repo" }
        switch reviewDecision {
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Review required"
        default: break
        }
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" || mergeStateStatus == "CONFLICTING" {
            return "Merge conflicts — rebase needed"
        }
        switch checkRollupState {
        case "FAILURE", "ERROR": return "Checks failing"
        case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS": return "Checks pending"
        default: break
        }
        if mergeStateStatus == "BLOCKED" { return "Blocked by branch protection" }
        return "Not mergeable yet (\(mergeStateStatus))"
    }

    /// The viewer's most recent submitted review, if they've reviewed
    /// this PR at all. Drives the "you already reviewed" indicator.
    var myLastReview: PRReviewSummary? {
        humanReviews.last { $0.isFromViewer }
    }

    /// Default merge method for this PR — first allowed in the order
    /// most teams converge on. Used as the primary action of the row's
    /// split button when there's no per-repo "last used" override.
    var preferredMergeMethod: MergeMethod? {
        for m in [MergeMethod.squash, .rebase, .merge] where allowedMergeMethods.contains(m) {
            return m
        }
        return nil
    }
}

extension InboxPR {
    private enum CodingKeys: String, CodingKey {
        case nodeId, owner, repo, number, title, body, url, author
        case headRef, baseRef, headSha, isDraft, role, state
        case mergeable, mergeStateStatus, reviewDecision, checkRollupState
        case totalAdditions, totalDeletions, changedFiles
        case hasAutoMerge, autoMergeEnabledBy, autoMergeMethod, allCheckSummaries
        case allowedMergeMethods, autoMergeAllowed, deleteBranchOnMerge
        case humanReviews, issueComments
    }

    /// Explicit decode so payloads cached before `humanReviews` /
    /// `issueComments` existed still load — Swift's synthesized
    /// `Decodable` throws `keyNotFound` for a missing key even when the
    /// property has a default value, so the new arrays use
    /// `decodeIfPresent ?? []`. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nodeId = try c.decode(String.self, forKey: .nodeId)
        self.owner = try c.decode(String.self, forKey: .owner)
        self.repo = try c.decode(String.self, forKey: .repo)
        self.number = try c.decode(Int.self, forKey: .number)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decode(String.self, forKey: .body)
        self.url = try c.decode(URL.self, forKey: .url)
        self.author = try c.decode(String.self, forKey: .author)
        self.headRef = try c.decode(String.self, forKey: .headRef)
        self.baseRef = try c.decode(String.self, forKey: .baseRef)
        self.headSha = try c.decode(String.self, forKey: .headSha)
        self.isDraft = try c.decode(Bool.self, forKey: .isDraft)
        self.role = try c.decode(PRRole.self, forKey: .role)
        self.state = (try? c.decodeIfPresent(PRState.self, forKey: .state)) ?? .open
        self.mergeable = try c.decode(String.self, forKey: .mergeable)
        self.mergeStateStatus = try c.decode(String.self, forKey: .mergeStateStatus)
        self.reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
        self.checkRollupState = try c.decode(String.self, forKey: .checkRollupState)
        self.totalAdditions = try c.decode(Int.self, forKey: .totalAdditions)
        self.totalDeletions = try c.decode(Int.self, forKey: .totalDeletions)
        self.changedFiles = try c.decode(Int.self, forKey: .changedFiles)
        self.hasAutoMerge = try c.decode(Bool.self, forKey: .hasAutoMerge)
        self.autoMergeEnabledBy = try c.decodeIfPresent(String.self, forKey: .autoMergeEnabledBy)
        self.autoMergeMethod = try c.decodeIfPresent(MergeMethod.self, forKey: .autoMergeMethod)
        self.allCheckSummaries = try c.decode([CheckSummary].self, forKey: .allCheckSummaries)
        self.allowedMergeMethods = try c.decode(Set<MergeMethod>.self, forKey: .allowedMergeMethods)
        self.autoMergeAllowed = try c.decode(Bool.self, forKey: .autoMergeAllowed)
        self.deleteBranchOnMerge = try c.decode(Bool.self, forKey: .deleteBranchOnMerge)
        self.humanReviews = try c.decodeIfPresent([PRReviewSummary].self, forKey: .humanReviews) ?? []
        self.issueComments = try c.decodeIfPresent([PRCommentSummary].self, forKey: .issueComments) ?? []
    }

    init(node: InboxResponse.PullRequestNode, viewerLogin: String) {
        self.nodeId = node.id

        let parts = node.repository.nameWithOwner.split(separator: "/", maxSplits: 1)
        self.owner = parts.first.map(String.init) ?? ""
        self.repo = parts.dropFirst().first.map(String.init) ?? ""

        self.number = node.number
        self.title = node.title
        self.body = node.body
        self.url = URL(string: node.url) ?? URL(string: "https://github.com")!
        self.author = node.author?.login ?? ""
        self.headRef = node.headRefName
        self.baseRef = node.baseRefName
        self.headSha = node.commits.nodes.first?.commit.oid ?? ""
        self.isDraft = node.isDraft
        self.state = PRState(githubRawValue: node.state ?? "OPEN")
        self.mergeable = node.mergeable
        self.mergeStateStatus = node.mergeStateStatus
        self.reviewDecision = node.reviewDecision
        self.totalAdditions = node.additions
        self.totalDeletions = node.deletions
        self.changedFiles = node.changedFiles
        self.hasAutoMerge = node.autoMergeRequest != nil
        self.autoMergeEnabledBy = node.autoMergeRequest?.enabledBy?.login
        self.autoMergeMethod = node.autoMergeRequest?.mergeMethod
            .flatMap { MergeMethod(rawValue: $0.lowercased()) }

        var methods: Set<MergeMethod> = []
        if node.repository.squashMergeAllowed { methods.insert(.squash) }
        if node.repository.mergeCommitAllowed { methods.insert(.merge) }
        if node.repository.rebaseMergeAllowed { methods.insert(.rebase) }
        self.allowedMergeMethods = methods
        self.autoMergeAllowed = node.repository.autoMergeAllowed
        self.deleteBranchOnMerge = node.repository.deleteBranchOnMerge

        let isAuthor = (node.author?.login == viewerLogin)
        let reviewerLogins = node.reviewRequests.nodes.compactMap { $0.requestedReviewer?.login }
        let isReviewRequested = reviewerLogins.contains(viewerLogin)
        switch (isAuthor, isReviewRequested) {
        case (true, true): self.role = .both
        case (true, false): self.role = .authored
        case (false, true): self.role = .reviewRequested
        case (false, false): self.role = .other
        }

        let rollup = node.commits.nodes.first?.commit.statusCheckRollup
        self.checkRollupState = rollup?.state ?? "EMPTY"
        self.allCheckSummaries = (rollup?.contexts.nodes ?? []).compactMap { ctx in
            guard let ctx else { return nil }   // skip nulls (private/inaccessible)
            return CheckSummary(
                typename: ctx.typename,
                name: ctx.name ?? ctx.context ?? "(unknown)",
                conclusion: ctx.conclusion,
                status: ctx.status ?? ctx.state,
                url: ctx.detailsUrl ?? ctx.targetUrl
            )
        }

        self.humanReviews = node.reviews.nodes.compactMap { r in
            guard let login = r.author?.login else { return nil }
            // Drop comment-only reviews with no body (the empty wrapper
            // GitHub creates when someone leaves only inline thread
            // comments) — they'd render as noise. Verdicts (approve /
            // changes / dismissed) always carry signal even with no body.
            let st = r.state.uppercased()
            let isVerdict = (st == "APPROVED" || st == "CHANGES_REQUESTED" || st == "DISMISSED")
            guard isVerdict || !r.body.isEmpty else { return nil }
            return PRReviewSummary(
                author: login,
                state: r.state,
                submittedAt: InboxPR.parseISO(r.submittedAt),
                body: r.body,
                isFromViewer: login == viewerLogin
            )
        }
        self.issueComments = node.comments.nodes.compactMap { c in
            guard let login = c.author?.login, !c.body.isEmpty else { return nil }
            // Skip comments GitHub has collapsed (marked duplicate /
            // outdated / resolved / spam) — they're hidden in the web UI.
            if c.isMinimized == true { return nil }
            return PRCommentSummary(
                author: login,
                createdAt: InboxPR.parseISO(c.createdAt),
                body: c.body,
                isFromViewer: login == viewerLogin
            )
        }
    }

    /// Parse a GitHub ISO-8601 timestamp (with or without fractional
    /// seconds). Constructs the formatter locally — `ISO8601DateFormatter`
    /// isn't `Sendable`, so a shared static would trip strict concurrency,
    /// and mapping runs once per PR per poll (not hot).
    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
