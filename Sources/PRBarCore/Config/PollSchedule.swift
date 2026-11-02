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
        var cron: CronExpression
        /// IANA name. Nil: the machine's time zone.
        var timezone: String?

        init(cron: CronExpression, timezone: String? = nil) {
            self.cron = cron
            self.timezone = timezone
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case cron, timezone
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .cron)
            do {
                cron = try CronExpression(text)
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .cron, in: c, debugDescription: "\(error)")
            }
            timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
            if let timezone, TimeZone(identifier: timezone) == nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .timezone, in: c, debugDescription: "unknown time zone `\(timezone)`; use an IANA name such as Europe/Copenhagen")
            }
            if cron.next(after: Date(), in: zone) == nil {
                throw DecodingError.dataCorruptedError(forKey: .cron, in: c, debugDescription: "`\(text)` never matches a date")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(cron.text, forKey: .cron)
            try c.encodeIfPresent(timezone, forKey: .timezone)
        }

        var zone: TimeZone { timezone.flatMap(TimeZone.init(identifier:)) ?? .current }
    }

    var entries: [Entry]

    init(_ entries: [Entry]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([Entry].self) {
            guard !list.isEmpty else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "an empty list never polls; leave `pollSchedule` out to poll every minute")
            }
            entries = list
        } else {
            entries = [try c.decode(Entry.self)]
        }
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
/// month and the day of week are restricted, a day matching either one
/// matches.
struct CronExpression: Sendable, Hashable, CustomStringConvertible {
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
        dayOfMonthRestricted = fields[2] != "*"
        dayOfWeekRestricted = fields[4] != "*"
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
            let range: ClosedRange<Int>
            let base = pieces[0]
            if base == "*" {
                range = bounds
            } else if let dash = base.firstIndex(of: "-") {
                guard let low = Int(base[..<dash]), let high = Int(base[base.index(after: dash)...]), low <= high else {
                    throw ParseError(description: "\(name) range `\(base)` must be two numbers, low-high")
                }
                range = low...high
            } else {
                guard let value = Int(base) else { throw ParseError(description: "\(name) `\(base)` is not a number, range or `*`") }
                // `a/n` runs from a to the end of the field, as in cron.
                range = pieces.count == 2 ? value...bounds.upperBound : value...value
            }
            guard bounds.contains(range.lowerBound), bounds.contains(range.upperBound) else {
                throw ParseError(description: "\(name) `\(part)` is outside \(bounds.lowerBound)-\(bounds.upperBound)")
            }
            values.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
        }
        return values
    }

    private func dayMatches(dayOfMonth: Int, weekday: Int) -> Bool {
        let dom = daysOfMonth.contains(dayOfMonth)
        let dow = daysOfWeek.contains(weekday)
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return dom || dow
        case (true, false): return dom
        case (false, true): return dow
        case (false, false): return true
        }
    }

    /// The first whole minute strictly after `date` that matches, read in
    /// `timeZone`. Nil when none does within eight years (`0 0 30 2 *`).
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
                t = next
            } else if !dayMatches(dayOfMonth: day, weekday: weekday - 1) {
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: t)) else { return nil }
                t = next
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
