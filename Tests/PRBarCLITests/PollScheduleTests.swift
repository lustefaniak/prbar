import XCTest
@testable import PRBarCore

final class PollScheduleTests: XCTestCase {
    private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!

    /// A `yyyy-MM-dd HH:mm` wall-clock time in `zone` (Copenhagen unless given) as an absolute date.
    private func local(_ text: String, _ zone: TimeZone? = nil) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone ?? copenhagen
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    private func next(_ cron: String, after: String, zone: TimeZone? = nil) throws -> Date? {
        try CronExpression(cron).next(after: local(after, zone), in: zone ?? copenhagen)
    }

    func testStepsAndRangesWithinTheWorkday() throws {
        XCTAssertEqual(try next("*/5 8-17 * * 1-5", after: "2026-11-02 13:07"), local("2026-11-02 13:10"))
        // Strictly after: a time that matches itself moves on.
        XCTAssertEqual(try next("*/5 8-17 * * 1-5", after: "2026-11-02 13:10"), local("2026-11-02 13:15"))
        // After 17:55 the next one is the following morning.
        XCTAssertEqual(try next("*/5 8-17 * * 1-5", after: "2026-11-02 17:56"), local("2026-11-03 08:00"))
        // Friday evening to Monday morning.
        XCTAssertEqual(try next("*/5 8-17 * * 1-5", after: "2026-11-06 18:00"), local("2026-11-09 08:00"))
    }

    func testListsMonthsAndSunday() throws {
        XCTAssertEqual(try next("0,30 9 * * *", after: "2026-11-02 09:00"), local("2026-11-02 09:30"))
        XCTAssertEqual(try next("0 0 1 1 *", after: "2026-11-02 13:07"), local("2027-01-01 00:00"))
        // 7 is Sunday, like 0.
        XCTAssertEqual(try next("0 12 * * 7", after: "2026-11-02 13:07"), local("2026-11-08 12:00"))
        XCTAssertEqual(try next("0 12 * * 0", after: "2026-11-02 13:07"), local("2026-11-08 12:00"))
        // `a/n` runs to the end of the field.
        XCTAssertEqual(try next("50/5 * * * *", after: "2026-11-02 13:56"), local("2026-11-02 14:50"))
    }

    func testRestrictedDayOfMonthAndWeekMatchEither() throws {
        // The 15th, or any Monday: the Monday comes first.
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-11-01 10:00"), local("2026-11-02 09:00"))
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-11-09 10:00"), local("2026-11-15 09:00"))
    }

    func testTimeZoneDecidesTheHour() throws {
        let utc = TimeZone(identifier: "UTC")!
        // 08:00 in Copenhagen is 07:00 UTC in winter.
        let next = try CronExpression("0 8 * * *").next(after: local("2026-11-02 06:00", utc), in: copenhagen)
        XCTAssertEqual(next, local("2026-11-02 07:00", utc))
    }

    func testDaylightSavingSkipsTheMissingHour() throws {
        // The spring-forward night has no 02:00-02:59 in Copenhagen.
        XCTAssertEqual(try next("30 2 * * *", after: "2027-03-28 01:00"), local("2027-03-29 02:30"))
        XCTAssertEqual(try next("*/30 * * * *", after: "2027-03-28 01:45"), local("2027-03-28 03:00"))
    }

    func testRejectsMalformedExpressions() {
        for bad in ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
                    "*/0 * * * *", "5-1 * * * *", "a * * * *", "1/2/3 * * * *", "1,,2 * * * *"] {
            XCTAssertThrowsError(try CronExpression(bad), bad)
        }
    }

    func testNeverMatchingExpressionHasNoNextDate() throws {
        XCTAssertNil(try next("0 0 30 2 *", after: "2026-11-02 13:07"))
    }

    func testEarliestEntryWins() throws {
        let schedule = PollSchedule([
            .init(cron: try CronExpression("*/5 8-17 * * 1-5"), timezone: "Europe/Copenhagen"),
            .init(cron: try CronExpression("*/30 * * * *"), timezone: "Europe/Copenhagen"),
        ])
        XCTAssertEqual(schedule.next(after: local("2026-11-02 13:07")), local("2026-11-02 13:10"))
        XCTAssertEqual(schedule.next(after: local("2026-11-02 18:07")), local("2026-11-02 18:30"))
        XCTAssertEqual(schedule.next(after: local("2026-11-07 10:01")), local("2026-11-07 10:30"))
    }

    // MARK: - prbar.yaml

    func testSingleEntry() throws {
        let loaded = try ConfigFile.decode("""
        pollSchedule:
          cron: "*/30 * * * *"
          timezone: Europe/Copenhagen
        """)
        XCTAssertEqual(loaded.config.pollSchedule?.entries.map(\.cron.text), ["*/30 * * * *"])
        XCTAssertEqual(loaded.config.pollSchedule?.entries.first?.timezone, "Europe/Copenhagen")
        XCTAssertEqual(loaded.warnings, [])
    }

    func testListOfEntriesAndMissingTimeZone() throws {
        let loaded = try ConfigFile.decode("""
        pollSchedule:
          - cron: "*/5 8-17 * * 1-5"
            timezone: Europe/Copenhagen
          - cron: "*/30 * * * *"
        """)
        XCTAssertEqual(loaded.config.pollSchedule?.entries.count, 2)
        XCTAssertNil(loaded.config.pollSchedule?.entries[1].timezone)
        XCTAssertEqual(loaded.config.pollSchedule?.entries[1].zone, .current)
        XCTAssertEqual(loaded.warnings, [])
    }

    func testMissingMeansNoSchedule() throws {
        XCTAssertNil(try ConfigFile.decode("version: 1").config.pollSchedule)
    }

    func testInvalidEntriesAreRefused() {
        let cases = [
            "pollSchedule:\n  cron: \"* * *\"",
            "pollSchedule:\n  cron: \"*/5 * * * *\"\n  timezone: Mars/Olympus",
            "pollSchedule:\n  cron: \"0 0 30 2 *\"",
            "pollSchedule: []",
            "pollSchedule:\n  timezone: UTC",
        ]
        for text in cases {
            XCTAssertThrowsError(try ConfigFile.decode(text), text) { error in
                guard case ConfigFile.Error.invalid = error else { return XCTFail("\(text): \(error)") }
            }
        }
    }

    func testUnknownKeysInEitherShapeAreReported() throws {
        let single = try ConfigFile.decode("pollSchedule:\n  cron: \"*/5 * * * *\"\n  tz: UTC")
        XCTAssertEqual(single.warnings.count, 1)
        XCTAssertTrue(single.warnings[0].contains("pollSchedule.tz"), single.warnings[0])
        let list = try ConfigFile.decode("pollSchedule:\n  - cron: \"*/5 * * * *\"\n    tz: UTC")
        XCTAssertTrue(list.warnings.first?.contains("pollSchedule[0].tz") ?? false, "\(list.warnings)")
    }

    func testRoundTripKeepsTheShape() throws {
        for text in [
            "pollSchedule:\n  cron: \"*/30 * * * *\"\n",
            "pollSchedule:\n- cron: \"*/5 8-17 * * 1-5\"\n  timezone: Europe/Copenhagen\n- cron: \"*/30 * * * *\"\n",
        ] {
            let config = try ConfigFile.decode(text).config
            let written = try ConfigFile.encode(config)
            XCTAssertEqual(try ConfigFile.decode(written).config, config, written)
            XCTAssertTrue(written.contains(text.hasPrefix("pollSchedule:\n-") ? "pollSchedule:\n- cron" : "pollSchedule:\n  cron"), written)
        }
    }

    // MARK: - poller

    @MainActor
    func testPollerWaitsForTheSchedule() throws {
        let poller = PRPoller(fetcher: { [] })
        let now = local("2026-11-02 13:07")
        XCTAssertEqual(poller.delayUntilNextPoll(now: now), 60, "no schedule: the fixed interval")
        poller.schedule = PollSchedule([.init(cron: try CronExpression("*/5 * * * *"), timezone: "Europe/Copenhagen")])
        XCTAssertEqual(poller.delayUntilNextPoll(now: now), 180)
    }

    @MainActor
    func testScheduleChangeRearmsTheRunningLoop() async throws {
        let counter = Counter()
        let poller = PRPoller(fetcher: { await counter.increment(); return [] })
        // Never within the test: the loop polls once at start, then waits.
        poller.schedule = PollSchedule([.init(cron: try CronExpression("0 0 1 1 *"))])
        poller.start()
        try await waitFor { await counter.value == 1 }
        // A schedule change doesn't poll by itself (the config reload does that).
        poller.schedule = PollSchedule([.init(cron: try CronExpression("0 0 1 6 *"))])
        try await Task.sleep(for: .milliseconds(100))
        let afterChange = await counter.value
        XCTAssertEqual(afterChange, 1)
        // Back to no schedule: the re-armed loop uses the interval.
        poller.pollInterval = 0.02
        poller.schedule = nil
        try await waitFor { await counter.value >= 3 }
        poller.stop()
    }
}

private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition never became true")
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
