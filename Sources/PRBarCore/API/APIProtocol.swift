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
    case review
    case historyActions = "history.actions"
    case historyReviews = "history.reviews"
    case poll
    case subscribe
    case shutdown
    /// Server to client, no id: one `APIEvent`.
    case event
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
}

struct HelloResult: Codable, Sendable, Equatable {
    var minProtocolVersion: Int
    var maxProtocolVersion: Int
    /// Who is serving: "PRBar.app" or "prbar-review serve".
    var holder: String
    var build: String
    var pid: Int32

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
