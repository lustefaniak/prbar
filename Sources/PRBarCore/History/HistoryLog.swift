import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An append-only log of `Record`s as JSON lines, one file per calendar
/// month (UTC): `2026-10.jsonl`. Readable with `cat` / `jq`, cheap to
/// expire (delete a month), and safe for several processes to append to
/// at once — every record is one `write(2)` on an `O_APPEND` file, so
/// lines from the app and the CLI never interleave.
struct JSONLinesLog<Record: Codable & Sendable>: Sendable {
    let directory: URL
    /// Which month a record belongs to.
    let date: @Sendable (Record) -> Date

    init(directory: URL, date: @escaping @Sendable (Record) -> Date) {
        self.directory = directory
        self.date = date
    }

    func append(_ record: Record) throws {
        try appendAll([record])
    }

    /// One write per month file touched.
    func appendAll(_ records: [Record]) throws {
        let encoder = Self.encoder()
        let byMonth = Dictionary(grouping: records) { Self.monthKey(date($0)) }
        for (month, group) in byMonth {
            var data = Data()
            for record in group {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try Self.appendBytes(data, to: url(forMonth: month))
        }
    }

    /// Every record, in file order (oldest month first). Lines that don't
    /// decode are skipped: one bad line must not hide the rest.
    func readAll() -> [Record] {
        read(months: monthKeys())
    }

    /// Records in months that can contain anything at or after `since`.
    /// Callers still filter on the exact date; this only skips whole files.
    func read(since: Date) -> [Record] {
        let first = Self.monthKey(since)
        return read(months: monthKeys().filter { $0 >= first })
    }

    /// Delete month files that end before `cutoff`. Month granularity:
    /// a record can outlive its retention by up to a month.
    /// Returns the records that were in the deleted files.
    @discardableResult
    func prune(before cutoff: Date) -> [Record] {
        let keep = Self.monthKey(cutoff)
        let doomed = monthKeys().filter { $0 < keep }
        let removed = read(months: doomed)
        for month in doomed {
            try? FileManager.default.removeItem(at: url(forMonth: month))
        }
        return removed
    }

    func clear() {
        for month in monthKeys() {
            try? FileManager.default.removeItem(at: url(forMonth: month))
        }
    }

    func monthKeys() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted()
    }

    private func read(months: [String]) -> [Record] {
        let decoder = Self.decoder()
        var out: [Record] = []
        for month in months {
            guard let data = try? Data(contentsOf: url(forMonth: month)) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let record = try? decoder.decode(Record.self, from: Data(line)) {
                    out.append(record)
                }
            }
        }
        return out
    }

    private func url(forMonth month: String) -> URL {
        directory.appendingPathComponent("\(month).jsonl")
    }

    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(HistoryDates.format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = HistoryDates.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(text)")
            }
            return date
        }
        return decoder
    }

    private static func appendBytes(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }
}

/// ISO 8601 with milliseconds, so records sort stably and stay readable.
enum HistoryDates {
    static func format(_ date: Date) -> String {
        formatter().string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        if let date = formatter().date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// Where history files live, shared by the app and the CLI.
enum HistoryLocation {
    static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ConfigLocation.stateDirectory(environment: environment, home: home)
            .appendingPathComponent("history")
    }
}

/// The action log: `history/actions/YYYY-MM.jsonl`.
typealias ActionHistory = JSONLinesLog<ActionRecord>

extension JSONLinesLog where Record == ActionRecord {
    static func actions(in historyDirectory: URL) -> ActionHistory {
        ActionHistory(directory: historyDirectory.appendingPathComponent("actions")) { $0.timestamp }
    }
}

/// The review log: an index in `history/reviews/YYYY-MM.jsonl` plus one
/// `history/reviews/full/<id>.json` per completed review.
struct ReviewHistory: Sendable {
    let index: JSONLinesLog<ReviewRecord>
    let fullDirectory: URL

    init(in historyDirectory: URL) {
        let dir = historyDirectory.appendingPathComponent("reviews")
        index = JSONLinesLog(directory: dir) { $0.triggeredAt }
        fullDirectory = dir.appendingPathComponent("full")
    }

    /// Writes the full review first, so an index line never points at a
    /// file that isn't there.
    func append(_ record: ReviewRecord, review: AggregatedReview?) throws {
        var record = record
        if let review {
            try writeFull(Self.encodeReview(review.strippingRawStreams()), id: record.id)
            record.hasReview = true
        }
        try index.append(record)
    }

    /// For migration: the payload is already-encoded `AggregatedReview`
    /// JSON, written as is.
    func writeFull(_ payload: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: fullDirectory, withIntermediateDirectories: true)
        try payload.write(to: fullURL(id), options: .atomic)
    }

    func review(id: UUID) -> AggregatedReview? {
        guard let data = try? Data(contentsOf: fullURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AggregatedReview.self, from: data)
    }

    func readAll() -> [ReviewRecord] { index.readAll() }

    func prune(before cutoff: Date) {
        for record in index.prune(before: cutoff) where record.hasReview {
            try? FileManager.default.removeItem(at: fullURL(record.id))
        }
    }

    func clear() {
        index.clear()
        try? FileManager.default.removeItem(at: fullDirectory)
    }

    static func encodeReview(_ review: AggregatedReview) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(review)
    }

    private func fullURL(_ id: UUID) -> URL {
        fullDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}
