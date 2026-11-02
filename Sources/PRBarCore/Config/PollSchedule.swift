import Foundation

/// When the poller fetches the inbox: `pollSchedule:` in prbar.yaml. One
/// entry, or a list of them; the inbox is fetched at every time any entry
/// matches. Missing means a fetch every `PRPoller.pollInterval` seconds.
///
/// ```yaml
/// pollSchedule:
///   - cron: "*/5 8-17 * * 1-5"
///     timezone: Europe/Copenhagen
///   - cron: "*/30 * * * *"
/// ```
struct PollSchedule: Sendable, Hashable, Codable {
    struct Entry: Sendable, Hashable, Codable {
        let cron: CronExpression
        /// IANA name as written. Nil: the machine's time zone.
        let timezone: String?
        let zone: TimeZone

        struct UnknownTimeZone: Error, CustomStringConvertible {
            var name: String
            var description: String { "unknown time zone `\(name)`; use an IANA name such as Europe/Copenhagen" }
        }

        init(cron: CronExpression, timezone: String? = nil) throws {
            guard let zone = timezone.map(TimeZone.init(identifier:)) ?? TimeZone.current else {
                throw UnknownTimeZone(name: timezone ?? "")
            }
            self.cron = cron
            self.timezone = timezone
            self.zone = zone
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case cron, timezone
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let cron = try c.decode(CronExpression.self, forKey: .cron)
            do {
                try self.init(cron: cron, timezone: c.decodeIfPresent(String.self, forKey: .timezone))
            } catch let error as UnknownTimeZone {
                throw DecodingError.dataCorruptedError(forKey: .timezone, in: c, debugDescription: error.description)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(cron, forKey: .cron)
            try c.encodeIfPresent(timezone, forKey: .timezone)
        }
    }

    let entries: [Entry]

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        // Pick the shape first, so an error inside a list entry surfaces as
        // itself rather than as "expected a mapping".
        guard var list = try? decoder.unkeyedContainer() else {
            entries = [try Entry(from: decoder)]
            return
        }
        var decoded: [Entry] = []
        while !list.isAtEnd { decoded.append(try list.decode(Entry.self)) }
        guard !decoded.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "an empty list never polls; leave `pollSchedule` out for the default interval"))
        }
        entries = decoded
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if entries.count == 1 { try c.encode(entries[0]) } else { try c.encode(entries) }
    }

    /// The first time after `date` that any entry matches.
    func next(after date: Date) -> Date? {
        entries.compactMap { $0.cron.next(after: date, in: $0.zone) }.min()
    }
}

/// A five-field cron expression: minute, hour, day of month, month, day of
/// week. Each field takes `*`, a number, a range `a-b`, a step (`*/n`,
/// `a-b/n`, `a/n`) or a comma-separated list of those. Day of week runs
/// 0-7 with both 0 and 7 meaning Sunday. As in cron, when both the day of
/// month and the day of week are restricted (neither starts with `*`), a
/// day matching either one matches.
struct CronExpression: Sendable, Hashable, Codable, CustomStringConvertible {
    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    let text: String
    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let daysOfWeek: Set<Int>
    private let dayOfMonthRestricted: Bool
    private let dayOfWeekRestricted: Bool

    var description: String { text }

    init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            throw ParseError(description: "`\(text)` has \(fields.count) fields; a cron expression has five: minute hour day-of-month month day-of-week")
        }
        self.text = text
        minutes = try Self.field(fields[0], name: "minute", 0...59)
        hours = try Self.field(fields[1], name: "hour", 0...23)
        daysOfMonth = try Self.field(fields[2], name: "day of month", 1...31)
        months = try Self.field(fields[3], name: "month", 1...12)
        daysOfWeek = Set(try Self.field(fields[4], name: "day of week", 0...7).map { $0 % 7 })
        dayOfMonthRestricted = !fields[2].hasPrefix("*")
        dayOfWeekRestricted = !fields[4].hasPrefix("*")
        // Every month has every weekday, so only a day of month alone can
        // rule out every date (`0 0 30 2 *`). February counts its 29th.
        let longest = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        if dayOfMonthRestricted, !dayOfWeekRestricted,
           !months.contains(where: { month in daysOfMonth.contains { $0 <= longest[month - 1] } }) {
            throw ParseError(description: "`\(text)` never matches a date")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        do {
            try self.init(c.decode(String.self))
        } catch let error as ParseError {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: error.description)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    private static func field(_ text: String, name: String, _ bounds: ClosedRange<Int>) throws -> Set<Int> {
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw ParseError(description: "\(name) `\(part)` has more than one `/`") }
            var step = 1
            if pieces.count == 2 {
                guard let n = Int(pieces[1]), n > 0 else { throw ParseError(description: "\(name) step `\(pieces[1])` must be a positive number") }
                step = n
            }
            let base = pieces[0]
            let low: Int, high: Int
            if base == "*" {
                (low, high) = (bounds.lowerBound, bounds.upperBound)
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = Int(base[..<dash]), let b = Int(base[base.index(after: dash)...]), a <= b else {
                    throw ParseError(description: "\(name) range `\(base)` must be two numbers, low-high")
                }
                (low, high) = (a, b)
            } else {
                guard let value = Int(base) else { throw ParseError(description: "\(name) `\(base)` is not a number, range or `*`") }
                // `a/n` runs from a to the end of the field, as in cron.
                (low, high) = (value, pieces.count == 2 ? max(value, bounds.upperBound) : value)
            }
            guard bounds.contains(low), bounds.contains(high) else {
                throw ParseError(description: "\(name) `\(part)` is outside \(bounds.lowerBound)-\(bounds.upperBound)")
            }
            values.formUnion(stride(from: low, through: high, by: step))
        }
        return values
    }

    /// Both fields must match, unless both are restricted: then either one
    /// will do. A starred field's values still count (`*/2` is odd days).
    private func dayMatches(dayOfMonth: Int, weekday: Int) -> Bool {
        let dom = daysOfMonth.contains(dayOfMonth)
        let dow = daysOfWeek.contains(weekday)
        return dayOfMonthRestricted && dayOfWeekRestricted ? dom || dow : dom && dow
    }

    /// The first whole minute strictly after `date` that matches, read in
    /// `timeZone`. Nil only if nothing matches within eight years, which
    /// `init` already rules out.
    func next(after date: Date, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = date.timeIntervalSinceReferenceDate
        var t = Date(timeIntervalSinceReferenceDate: (start / 60).rounded(.down) * 60 + 60)
        let limit = date.addingTimeInterval(8 * 366 * 86400)
        // Skips a whole month, day or hour at a time, so even a yearly
        // schedule takes a few hundred steps.
        while t < limit {
            let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: t)
            guard let month = c.month, let day = c.day, let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return nil }
            if !months.contains(month) {
                guard let first = calendar.date(from: DateComponents(year: c.year, month: month, day: 1)),
                      let next = calendar.date(byAdding: .month, value: 1, to: first) else { return nil }
                t = calendar.startOfDay(for: next)
            } else if !dayMatches(dayOfMonth: day, weekday: weekday - 1) {
                // Start of the next day, found from midday: where clocks
                // change at midnight, a day can start at 01:00, and adding a
                // day to that start would skip the next day's 00:xx.
                guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: t),
                      let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon) else { return nil }
                t = calendar.startOfDay(for: tomorrow)
            } else if !hours.contains(hour) {
                t = t.addingTimeInterval(TimeInterval(3600 - minute * 60))
            } else if !minutes.contains(minute) {
                t = t.addingTimeInterval(60)
            } else {
                return t
            }
        }
        return nil
    }
}
