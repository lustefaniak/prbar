import Foundation

/// `prbar-review status | inbox | history | events`: clients of the running
/// PRBar server (the app, or `prbar-review serve`). They read what that
/// server knows; none of them starts one.
///
/// Exit status: 0 fine, 1 the server reported a problem (`status`) or went
/// away (`events`), 2 bad arguments, 3 no reachable or compatible server.
enum ClientCommand: Equatable {
    case status(json: Bool)
    case inbox(json: Bool)
    case history(kind: HistoryKind, limit: Int?, json: Bool)
    case events

    enum HistoryKind: String, Equatable {
        case actions, reviews
    }

    static let names: Set<String> = ["status", "inbox", "history", "events"]

    init?(args: [String]) {
        guard let name = args.first else { return nil }
        var json = false
        var limit: Int?
        var positional: [String] = []
        var i = args.index(after: args.startIndex)
        while i < args.endIndex {
            switch args[i] {
            case "--json":
                json = true
            case "--limit":
                i += 1
                guard i < args.endIndex, let n = Int(args[i]), n > 0 else { return nil }
                limit = n
            default:
                guard !args[i].hasPrefix("-") else { return nil }
                positional.append(args[i])
            }
            i += 1
        }
        switch name {
        case "status" where positional.isEmpty && limit == nil:
            self = .status(json: json)
        case "inbox" where positional.isEmpty && limit == nil:
            self = .inbox(json: json)
        case "history" where positional.count <= 1:
            guard let kind = HistoryKind(rawValue: positional.first ?? "actions") else { return nil }
            self = .history(kind: kind, limit: limit ?? (json ? nil : 20), json: json)
        case "events" where positional.isEmpty && limit == nil && !json:
            self = .events
        default:
            return nil
        }
    }

    static let usage = """
    usage: prbar-review status [--json]
           prbar-review inbox [--json]
           prbar-review history [actions|reviews] [--limit <n>] [--json]
           prbar-review events

    Ask the running PRBar server (the app, or `prbar-review serve`).

      status    whether the server is working: last poll, queue, config
      inbox     the PRs it is tracking
      history   recent GitHub actions or AI reviews, newest first
                (20 unless --limit; all of them with --json)
      events    follow changes as they happen, one JSON object per line

    """

    func run(socketURL: URL = ServerLocation.socketURL()) async -> Int32 {
        let connected: ServerConnection.Connected
        do {
            connected = try await ServerConnection.connect(socketURL: socketURL, client: "prbar-review")
        } catch {
            Self.fail(error.localizedDescription)
            return 3
        }
        let client = connected.client
        defer { client.close() }
        do {
            switch self {
            case .status(let json):
                let status = try await client.call(.status, as: ServerStatus.self)
                if json {
                    try Self.printJSON(status)
                } else {
                    Self.print(Self.describe(status, now: Date()))
                }
                return status.problems.isEmpty ? 0 : 1
            case .inbox(let json):
                let prs = try await client.call(.inbox, as: [InboxPR].self)
                if json {
                    try Self.printJSON(prs)
                } else {
                    Self.print(prs.map(Self.describe).joined(separator: "\n"))
                }
            case .history(.actions, let limit, let json):
                let records = try await client.call(.historyActions, HistoryParams(limit: limit), as: [ActionRecord].self)
                if json {
                    try Self.printJSONLines(records)
                } else {
                    Self.print(records.map(Self.describe).joined(separator: "\n"))
                }
            case .history(.reviews, let limit, let json):
                let records = try await client.call(.historyReviews, HistoryParams(limit: limit), as: [ReviewRecord].self)
                if json {
                    try Self.printJSONLines(records)
                } else {
                    Self.print(records.map(Self.describe).joined(separator: "\n"))
                }
            case .events:
                _ = try await client.call(.subscribe, SubscribeParams(), as: SubscribeResult.self)
                for await event in client.events {
                    try Self.printJSONLines([event])
                }
                Self.fail("the server went away")
                return 1
            }
            return 0
        } catch {
            Self.fail(error.localizedDescription)
            return 3
        }
    }

    // MARK: - Text output

    static func describe(_ status: ServerStatus, now: Date) -> String {
        var lines = [
            "server:     \(status.holder), build \(status.build), pid \(status.pid), up \(duration(now.timeIntervalSince(status.startedAt)))",
            "automation: \(status.ownsAutomation ? "on" : "off (another PRBar reviews and posts)")",
        ]
        if let at = status.lastPollAt {
            lines.append("last poll:  \(timestamp(at)) (\(duration(now.timeIntervalSince(at))) ago), \(status.prCount) PRs, \(status.awaitingReview) awaiting your review")
        } else {
            lines.append("last poll:  none yet")
        }
        lines.append("reviews:    \(status.reviewsRunning) running, \(status.reviewsQueued) queued")
        lines.append("config:     \(status.configPath)")
        if let agents = status.agents {
            let granted = AgentPolicy.Capability.allCases.map { "\($0.rawValue) \(agents[$0].rawValue)" }
            lines.append("agents:     \(granted.joined(separator: ", "))")
        }
        lines += status.problems.map { "problem:    \($0)" }
        lines += status.configWarnings.map { "warning:    \($0)" }
        return lines.joined(separator: "\n")
    }

    static func describe(_ pr: InboxPR) -> String {
        let role: String
        switch pr.role {
        case .reviewRequested: role = "review"
        case .authored: role = "mine"
        case .both: role = "both"
        case .other: role = "other"
        }
        return "\(pad(role, 7)) \(pad("\(pr.nameWithOwner)#\(pr.number)", 32)) \(pr.isDraft ? "[draft] " : "")\(pr.title)"
    }

    static func describe(_ record: ActionRecord) -> String {
        var line = "\(timestamp(record.timestamp))  \(pad(record.kind.rawValue, 16)) \(pad(record.outcome.rawValue, 8)) \(record.nameWithOwner)#\(record.prNumber)"
        if let error = record.errorMessage { line += "  \(error)" }
        return line
    }

    static func describe(_ record: ReviewRecord) -> String {
        let cost = record.costUsd.map { String(format: "$%.2f", $0) } ?? "-"
        var line = "\(timestamp(record.triggeredAt))  \(pad(record.status.rawValue, 9)) \(pad(record.verdict?.rawValue ?? "-", 15)) \(pad(cost, 6)) \(record.nameWithOwner)#\(record.prNumber)  \(record.prTitle)"
        if let error = record.errorMessage { line += "  (\(error))" }
        return line
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Writing

    private static func print(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = APICoding.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
    }

    /// One compact object per line, so `jq` and `head` work on the stream.
    private static func printJSONLines<T: Encodable>(_ values: [T]) throws {
        let encoder = APICoding.encoder
        for value in values {
            FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("prbar-review: \(message)\n".utf8))
    }
}
