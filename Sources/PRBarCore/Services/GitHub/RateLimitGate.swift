import Foundation

/// Holds every `gh` call in the process back while GitHub says it is rate
/// limited. GitHub warns that "continuing to make requests while you are
/// rate limited may result in the banning of your integration", so a hold
/// covers reads and writes alike, and every `GHClient` shares one gate:
/// the limits belong to the user's token, not to one client.
actor RateLimitGate {
    static let shared = RateLimitGate()

    private(set) var heldUntil: Date?
    /// Rate-limit failures in a row that carried no wait of their own.
    private var unexplainedStreak = 0

    /// Throws while a hold is in force.
    func check(now: Date = Date()) throws {
        if let heldUntil, heldUntil > now {
            throw GHClient.GHError.rateLimited(until: heldUntil)
        }
    }

    /// Reads one response and returns the hold it starts, if any.
    @discardableResult
    func record(_ response: GitHubResponse, failed: Bool, message: String, now: Date = Date()) -> Date? {
        guard let until = Self.holdUntil(
            response, failed: failed, message: message, streak: unexplainedStreak, now: now)
        else {
            if !failed { unexplainedStreak = 0 }
            return nil
        }
        if failed, response.retryAfter == nil, response.remaining != 0 { unexplainedStreak += 1 }
        heldUntil = max(heldUntil ?? until, until)
        return until
    }

    /// GitHub's rules, in its order: `retry-after` when sent; the window's
    /// reset when no requests remain, which can arrive on a response that
    /// succeeded (the last request of the window); otherwise, for a failure
    /// that says it was rate limited, a minute doubling on each one in a row,
    /// up to an hour.
    nonisolated static func holdUntil(
        _ response: GitHubResponse, failed: Bool, message: String, streak: Int, now: Date
    ) -> Date? {
        if failed, let seconds = response.retryAfter {
            return now.addingTimeInterval(max(seconds, 1))
        }
        if response.remaining == 0, let reset = response.reset {
            return max(reset, now.addingTimeInterval(1))
        }
        guard failed, message.localizedCaseInsensitiveContains("rate limit") else { return nil }
        return now.addingTimeInterval(min(60 * pow(2, Double(min(streak, 6))), 3600))
    }
}

/// `gh api -i` output split into the response's status and headers and the
/// body the caller would have read without `-i`. With `--paginate` every
/// page carries its own header block; the last one wins, since that is the
/// page that stopped the run.
struct GitHubResponse: Sendable, Equatable {
    var status: Int?
    /// Lowercased names.
    var headers: [String: String] = [:]
    var body = Data()

    var retryAfter: TimeInterval? { headers["retry-after"].flatMap(TimeInterval.init) }
    var remaining: Int? { headers["x-ratelimit-remaining"].flatMap(Int.init) }
    var reset: Date? { headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) }

    init(status: Int? = nil, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A header block starts with a status line at the very start or right
    /// after a blank line, and ends at the next blank line. Output without
    /// one is all body.
    /// Works on bytes and copies body lines verbatim: splitting a String
    /// would also break on U+2028, U+0085 and the like, which JSON allows
    /// unescaped inside a PR title or body.
    init(includeOutput output: Data) {
        let bytes = [UInt8](output)
        guard bytes.starts(with: Array("HTTP/".utf8)) else {
            body = output
            return
        }
        var kept = Data()
        var inHeaders = false
        var previousBlank = true
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
            var contentEnd = end
            if contentEnd > start, bytes[contentEnd - 1] == 0x0A { contentEnd -= 1 }
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = String(decoding: bytes[start..<contentEnd], as: UTF8.self)[...]
            defer { start = end }
            if inHeaders {
                if line.isEmpty {
                    inHeaders = false
                    previousBlank = true
                } else if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].lowercased()
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if previousBlank, line.hasPrefix("HTTP/"), let code = Self.statusCode(line) {
                status = code
                headers = [:]
                inHeaders = true
                previousBlank = false
                continue
            }
            kept.append(contentsOf: bytes[start..<end])
            previousBlank = line.isEmpty
        }
        body = kept
    }

    private static func statusCode(_ line: Substring) -> Int? {
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}
