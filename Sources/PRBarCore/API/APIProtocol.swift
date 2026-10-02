import Foundation

/// The contract between the PRBar server and every client (the app, the
/// CLI, MCP). JSON-RPC 2.0, one message per line on a Unix socket.
///
/// Bump `APIVersion.current` when a change would make an older peer
/// misread a message, and keep `supported` covering every version this
/// build still understands: the app and a separately installed CLI update
/// on their own schedules.
enum APIVersion {
    static let current = 1
    static let supported = 1...1
}

/// Method names, in one place so the server's dispatch and the clients
/// can't drift apart.
enum APIMethod: String, CaseIterable, Sendable {
    case hello
    case status
    case inbox
    case refreshPR = "inbox.refresh"
    case review
    case runReview = "review.run"
    case reviewOutcome = "review.outcome"
    case reviewLocal = "review.local"
    case explainRules = "rules.explain"
    case ruleFiles = "rules.files"
    case ruleRecords = "rules.records"
    case replayRule = "rules.replay"
    case ruleImpact = "rules.impact"
    case saveRuleFile = "rules.save"
    case convertRepos = "rules.convert"
    case enqueueAction = "action.enqueue"
    case retryAction = "action.retry"
    case dismissAction = "action.dismiss"
    case setConfig = "config.set"
    case loadDiff = "diff.load"
    case invalidateDiff = "diff.invalidate"
    case loadCILog = "ciLog.load"
    case invalidateCILog = "ciLog.invalidate"
    case autoReviewUndo = "autoReview.undo"
    case autoReviewPostNow = "autoReview.postNow"
    case autoReviewDismissFlagged = "autoReview.dismissFlagged"
    case setPreferences = "preferences.set"
    case checkoutUsage = "checkouts.usage"
    case checkoutPrune = "checkouts.prune"
    case fullReview = "history.review"
    case clearReviewHistory = "history.clearReviews"
    case reportHistoryImport = "history.importStatus"
    case reloadHistory = "history.reload"
    case setPopoverVisible = "ui.popoverVisible"
    case historyActions = "history.actions"
    case historyReviews = "history.reviews"
    case poll
    case subscribe
    case shutdown
    case adopt = "server.adopt"
    /// Server to client, no id: one `APIEvent`.
    case event
    /// Server to client, no id: one `StateUpdate`.
    case state
    /// Server to client, no id: `NotificationBatch` for the client to show.
    case notify

    /// Sent by the server only; a client sending one gets "unknown method".
    var isNotification: Bool { self == .event || self == .state || self == .notify }
}

/// Dates as ISO 8601 with milliseconds, the same as the history files.
enum APICoding {
    static var encoder: JSONEncoder { JSONLinesLog<ActionRecord>.encoder() }
    static var decoder: JSONDecoder { JSONLinesLog<ActionRecord>.decoder() }
}

struct RPCError: Codable, Sendable, Error, Equatable, LocalizedError {
    var code: Int
    var message: String

    var errorDescription: String? { message }

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// The peers share no protocol version.
    static let incompatibleVersion = -32000
    /// The request is understood but this server won't do it (e.g.
    /// `shutdown` sent to a server the app hosts).
    static let refused = -32001
    static let notFound = -32002
    /// The `agents:` policy doesn't let a coding agent do this.
    static let notPermitted = -32003
    /// The thing being written changed since the client read it.
    static let conflict = -32004
}

// A line is decoded twice: once as `RPCHeader` to route it, then as the
// typed request or response the method calls for. That keeps payloads as
// real Codable types end to end, with no untyped JSON tree in between
// (whose number/bool guessing differs between Foundation versions).

/// The routing fields of any line: a request has `id` + `method`, a
/// response `id` + `result` or `error`, a notification `method` only.
struct RPCHeader: Decodable, Sendable {
    var id: Int?
    var method: String?
    var error: RPCError?
}

struct RPCRequest<Params: Codable & Sendable>: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?
    var method: String
    var params: Params?
}

struct RPCResponse<Result: Codable & Sendable>: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?
    var result: Result?
    var error: RPCError?
}

enum RPCLine {
    static func encode<T: Encodable>(_ message: T) throws -> Data {
        try APICoding.encoder.encode(message)
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try APICoding.decoder.decode(T.self, from: line)
    }
}

/// An empty object, for methods with no params or no result.
struct APIEmpty: Codable, Sendable, Equatable {}

// MARK: - Payloads

struct HelloParams: Codable, Sendable {
    /// Free text naming the client, for the server's log and for the
    /// `ActionSource` of anything it posts.
    var client: String
    var protocolVersion: Int
    /// A coding agent rather than the user's own front end: the server
    /// holds its requests to the `agents:` policy in `prbar.yaml`.
    var agent: Bool?
}

struct HelloResult: Codable, Sendable, Equatable {
    var minProtocolVersion: Int
    var maxProtocolVersion: Int
    /// Who is serving: "PRBar.app" or "prbar-review serve".
    var holder: String
    var build: String
    var pid: Int32
    /// Set when the server lives and dies with that process (one the app
    /// started); nil for a server someone started on purpose.
    var exitsWith: Int32?
    /// Set for a server a one-off `prbar-review <pr>` started: it reviews
    /// only what it's asked to and exits after this many seconds without
    /// clients. The app adopts such a server rather than starting another.
    var idleExitSeconds: Int?

    var protocolVersions: ClosedRange<Int> { minProtocolVersion...maxProtocolVersion }
}

/// Whether the server is *working*, not only reachable.
struct ServerStatus: Codable, Sendable, Equatable {
    var holder: String
    var build: String
    var pid: Int32
    var startedAt: Date
    /// False when the server only shows state and leaves review and posting
    /// to someone else (another process holds the runtime lock).
    var ownsAutomation: Bool

    var lastPollAt: Date?
    /// Set while the most recent poll failed, `gh` not being
    /// authenticated included.
    var lastPollError: String?
    var prCount: Int
    var awaitingReview: Int

    var reviewsQueued: Int
    var reviewsRunning: Int

    var configPath: String
    var configIssue: String?
    var configWarnings: [String]
    /// What `agents:` lets coding agents do. Nil from an older server.
    var agents: AgentPolicy?
    /// Set for a server started on demand by `prbar-review <pr>`.
    var idleExitSeconds: Int?
    /// The rules directory, and how many select / decide policies are in
    /// effect from it. Nil from an older server.
    var rulesPath: String?
    var rules: RuleCounts?
    var rulesIssue: String?

    /// Problems a client should surface, empty when everything is fine.
    var problems: [String] {
        var out: [String] = []
        if let lastPollError { out.append("last poll failed: \(lastPollError)") }
        if let configIssue { out.append("config: \(configIssue)") }
        if let rulesIssue { out.append("rules: \(rulesIssue)") }
        return out
    }
}

/// Why the rules decide what they do for a PR: `select` always, `decide`
/// when the server holds a completed review of its current head.
struct ExplainRulesParams: Codable, Sendable {
    var pr: PRReference
    /// Evaluate these unsaved edits in place of the user's rules.
    var draft: RuleDraft?
}

struct RulesExplanation: Codable, Sendable {
    var pr: InboxPR
    /// Every condition evaluated, with the facts it read, then the outcome.
    var select: String
    var decide: String?
    /// The same, per layer, as values. Nil from an older server.
    var layers: [RuleLayerTrace]?
    /// What happens, in words: "reviewed.", "nothing posted (...)".
    var selectOutcome: String?
    var decideOutcome: String?
    /// Why the draft couldn't be evaluated: it doesn't compile.
    var draftProblem: String?
    /// What the configure rules set for the PR's repository.
    var configured: ConfiguredSummary?
}

/// The settings configure rules set for a repository, for showing.
struct ConfiguredSummary: Codable, Sendable, Equatable {
    var repository: String
    /// The ids of the rules that set something, in order.
    var rules: [String]
    /// `name: value` for each setting they set.
    var settings: [String]
    /// From the `repositories:` lists in prbar.yaml.
    var triaged: Bool
    var hidden: Bool
    var trustsRules: Bool
    var error: String?
}

/// Unsaved edits to the user's rules directory, by path relative to it
/// (`decide/10-x.yaml`, `lists.yaml`): what the Rules tab evaluates while
/// the user types.
struct RuleDraft: Codable, Sendable, Equatable {
    var files: [String: String] = [:]
    /// Files deleted in the draft.
    var removed: [String] = []

    /// The directory's files with the draft applied.
    func applied(to files: [String: String]) -> [String: String] {
        var out = files.merging(self.files) { $1 }
        for path in removed { out.removeValue(forKey: path) }
        return out
    }
}

struct RuleFilesResult: Codable, Sendable, Equatable {
    /// The user's rules directory.
    var directory: String
    /// By path relative to it.
    var files: [String: String]
    /// Why the rules in effect aren't what's in the directory.
    var issue: String?
}

struct RuleRecordsParams: Codable, Sendable {
    /// Newest first; nil means every recorded one.
    var limit: Int?
}

/// A recorded rule decision, without the facts it was made on.
struct RuleRecordSummary: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var at: Date
    var stage: RuleEvaluation.Stage
    var layer: RuleLayer
    /// `owner/repo#number`.
    var pr: String
    var title: String
    var outcome: String
}

struct ReplayRuleParams: Codable, Sendable {
    var id: UUID
    var draft: RuleDraft?
}

/// A recorded decision evaluated again on its own facts: against the rules
/// now, and against the draft when there is one.
struct RuleReplayResult: Codable, Sendable {
    var record: RuleRecordSummary
    var now: String
    var trace: RuleTrace?
    var draft: String?
    var draftTrace: RuleTrace?
    var draftProblem: String?
}

struct RuleImpactParams: Codable, Sendable {
    var draft: RuleDraft
    /// How far back; every record kept when nil.
    var days: Int?
}

/// What a draft would change: each recorded decision whose answer under
/// the draft differs from its answer under the rules now.
struct RuleImpact: Codable, Sendable {
    struct Change: Codable, Sendable, Equatable, Identifiable {
        var record: RuleRecordSummary
        var now: String
        var draft: String

        var id: UUID { record.id }
    }

    /// Decisions replayed: the latest per PR, commit and stage.
    var examined: Int
    var changes: [Change]
    var draftProblem: String?
}

/// Turn the `repos:` of an old prbar.yaml into a configure rule.
struct ConvertReposParams: Codable, Sendable {
    /// Check and return the rule without writing anything.
    var dryRun: Bool?
}

struct SaveRuleFileParams: Codable, Sendable {
    /// Relative to the rules directory.
    var path: String
    /// Nil deletes the file.
    var text: String?
    /// What the client read, nil for a file it creates. The save is refused
    /// with `conflict` when the file changed since, so it can't erase an
    /// edit made in an editor meanwhile.
    var base: String?
}

struct RuleCounts: Codable, Sendable, Equatable {
    var select: Int
    var decide: Int
    /// Nil from an older server.
    var configure: Int? = nil
}

/// A PR named either by its GraphQL node id or by `owner/repo#number`.
struct PRReference: Codable, Sendable, Equatable {
    var nodeId: String?
    var owner: String?
    var repo: String?
    var number: Int?
    /// A directory in a checkout reviewed with `review.local`.
    var path: String?
}

/// Review a working directory: its uncommitted and unpushed changes
/// against where its branch forked. Never posts anything.
struct LocalReviewParams: Codable, Sendable {
    var path: String
    /// What to compare with; by default the merge base with `origin/HEAD`
    /// (else `origin/main`, `origin/master`, `main`, `master`).
    var base: String?
    var provider: ProviderID?
    /// Review again even when these exact changes were reviewed already.
    var force: Bool?
}

struct ReviewResult: Codable, Sendable {
    var pr: InboxPR
    /// Nil when PRBar has no review state for the PR.
    var review: ReviewState?
    /// From `review.run`: why nothing was queued, when the request was
    /// dropped without a review state (not requested, excluded, failed at
    /// this commit already).
    var ignored: String?
    /// From `review.run`: the provider the review runs with.
    var provider: ProviderID?
}

struct ReviewOutcomeParams: Codable, Sendable {
    var pr: PRReference
    /// GitHub writes for the PR logged from this moment on are reported.
    var since: Date
}

/// Where one review stands, posts included: what a client waiting for a
/// review to be completely done needs.
struct ReviewOutcome: Codable, Sendable {
    var pr: InboxPR
    var review: ReviewState?
    /// The review is terminal and nothing it set off is still going: no
    /// staged post waiting out the undo window, no write queued, running
    /// or retrying.
    var settled: Bool
    /// The auto-deny gate flagged the PR without posting.
    var flagged: Bool
    /// GitHub writes for the PR since `since`, oldest first.
    var actions: [ActionRecord]
}

struct AdoptParams: Codable, Sendable {
    /// The adopting app's pid: the server now exits with it.
    var exitWith: Int32
}

struct RefreshParams: Codable, Sendable {
    var pr: PRReference
    /// Refresh even when a refresh of this PR is already in flight.
    var force: Bool?
}

struct SubscribeParams: Codable, Sendable {
    /// Also send `state` updates (the data a UI renders), starting with a
    /// full snapshot in the reply. Without it only `event`s arrive.
    var state: Bool?
    /// Also send `notify` batches: this client shows notifications, so the
    /// server stops handing them to its own fallback while it's connected.
    var notifications: Bool?
}

struct NotificationBatch: Codable, Sendable, Equatable {
    var events: [NotificationEvent]
}

struct SubscribeResult: Codable, Sendable {
    var status: ServerStatus
    /// The full state, when subscribed with `state: true`.
    var state: StateUpdate?
}

struct RunReviewParams: Codable, Sendable {
    var pr: PRReference
    /// Run with this provider instead of the configured one.
    var provider: ProviderID?
    /// Review even when a repo gate (draft, already reviewed, a verdict
    /// already at this SHA) would skip it, or a review is cached.
    var force: Bool?
    /// Fetch the PR from GitHub first, so one outside the inbox can be
    /// reviewed, and at its current head.
    var fetch: Bool?
    /// Without `force`, apply every repo gate an incoming review request
    /// meets, the review request itself included (`prbar-review <pr>`).
    var gated: Bool?
}

/// A GitHub write, for the server's action queue.
struct EnqueueActionParams: Codable, Sendable {
    /// The PR as the client saw it when the user acted. Sent whole, not as
    /// a reference: a review is posted against this snapshot's head SHA,
    /// the commit the user reviewed, even if the PR has moved since.
    var pr: InboxPR
    var kind: GHActionKind
}

struct SetConfigParams: Codable, Sendable {
    /// The whole config, rule ids included (they are UI identity, kept
    /// across the API though never written to the file).
    var config: PRBarConfig
    /// The revision the edit started from. The write is refused with
    /// `conflict` when the config changed since by any other hand, so a
    /// whole-config write can't erase an edit made to the file meanwhile.
    var baseRevision: Int?
}

/// A PR as the client sees it, for loads keyed by its head SHA.
struct PRSnapshot: Codable, Sendable {
    var pr: InboxPR
}

struct CILogParams: Codable, Sendable {
    var pr: InboxPR
    var check: CheckSummary
}

struct ActionTarget: Codable, Sendable {
    var prNodeId: String
}

/// Machine-local preferences the front end owns (in its own settings, not
/// `prbar.yaml`) and hands to the server. Nil leaves a field as it is.
struct PreferencesParams: Codable, Sendable {
    var dailyCostCapEnabled: Bool?
    var dailyCostCapUsd: Double?
    /// Whether drafts you authored raise CI and ready-to-merge
    /// notifications.
    var notifyAuthoredDrafts: Bool?
    /// How long staged auto reviews wait for an undo. A headless server
    /// runs with 0, since nobody sees the banner; a UI that shows it sets
    /// its own.
    var undoWindowSeconds: Double?

    /// Later values win, field by field.
    mutating func merge(_ other: PreferencesParams) {
        dailyCostCapEnabled = other.dailyCostCapEnabled ?? dailyCostCapEnabled
        dailyCostCapUsd = other.dailyCostCapUsd ?? dailyCostCapUsd
        notifyAuthoredDrafts = other.notifyAuthoredDrafts ?? notifyAuthoredDrafts
        undoWindowSeconds = other.undoWindowSeconds ?? undoWindowSeconds
    }
}

struct CheckoutUsage: Codable, Sendable {
    /// Bytes used by the bare clones and worktrees reviews run in.
    var bytes: Int64
}

struct FullReviewParams: Codable, Sendable {
    var id: UUID
}

struct FullReviewResult: Codable, Sendable {
    /// Nil for a failed run or a row whose file is missing.
    var review: AggregatedReview?
}

struct PopoverVisibility: Codable, Sendable {
    /// While the user is looking at PRBar, notifications are held back.
    var visible: Bool
}

struct HistoryParams: Codable, Sendable {
    /// Newest first; nil means all of it.
    var limit: Int?
    /// Only this PR's entries (`owner`, `repo`, `number`; a `nodeId` is
    /// ignored). A server older than this field returns every PR's, so a
    /// client still checks what comes back.
    var pr: PRReference?
}

/// Something changed in the server. Clients refresh what they show from
/// it; the payload says what changed, not the whole new state.
struct APIEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// A poll finished; `count` PRs in the inbox now.
        case inboxChanged
        /// A review reached a terminal state (completed, failed, skipped)
        /// or was answered from cache.
        case reviewSettled
        /// A GitHub write succeeded.
        case actionCompleted
        case configChanged
    }

    var kind: Kind
    var prNodeId: String?
    /// `owner/repo#number`, when the event is about one PR.
    var pr: String?
    var count: Int?
    var detail: String?
}
