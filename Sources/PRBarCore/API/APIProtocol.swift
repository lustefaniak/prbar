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

    /// Problems a client should surface, empty when everything is fine.
    var problems: [String] {
        var out: [String] = []
        if let lastPollError { out.append("last poll failed: \(lastPollError)") }
        if let configIssue { out.append("config: \(configIssue)") }
        return out
    }
}

/// A PR named either by its GraphQL node id or by `owner/repo#number`.
struct PRReference: Codable, Sendable, Equatable {
    var nodeId: String?
    var owner: String?
    var repo: String?
    var number: Int?
}

struct ReviewResult: Codable, Sendable {
    var pr: InboxPR
    /// Nil when PRBar has no review state for the PR.
    var review: ReviewState?
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
