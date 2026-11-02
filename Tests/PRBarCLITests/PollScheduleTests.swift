import XCTest
@testable import PRBarCore

final class PollScheduleTests: XCTestCase {
    private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!
    private let utc = TimeZone(identifier: "UTC")!

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

    private func entry(_ cron: String, _ timezone: String? = "Europe/Copenhagen") throws -> PollSchedule.Entry {
        try PollSchedule.Entry(cron: CronExpression(cron), timezone: timezone)
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
    }

    func testStepForms() throws {
        // `a/n` runs to the end of the field.
        XCTAssertEqual(try next("50/5 * * * *", after: "2026-11-02 13:56"), local("2026-11-02 14:50"))
        // `a-b/n` steps from a, within the range.
        XCTAssertEqual(try next("10-30/10 * * * *", after: "2026-11-02 13:31"), local("2026-11-02 14:10"))
        XCTAssertEqual(try next("10-30/10 * * * *", after: "2026-11-02 13:15"), local("2026-11-02 13:20"))
        XCTAssertEqual(try next("0 9-17/4 * * *", after: "2026-11-02 13:30"), local("2026-11-02 17:00"))
    }

    func testRestrictedDayOfMonthAndWeekMatchEither() throws {
        // The 15th, or any Monday: the Monday comes first.
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-11-01 10:00"), local("2026-11-02 09:00"))
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-11-09 10:00"), local("2026-11-15 09:00"))
    }

    func testAStarredDayFieldIsUnrestricted() throws {
        // `*/2` starts with `*`, so both day fields must match: an odd-numbered
        // Monday. The 2nd is an even Monday, the 3rd an odd Tuesday.
        XCTAssertEqual(try next("0 9 */2 * 1", after: "2026-11-01 10:00"), local("2026-11-09 09:00"))
    }

    func testTimeZoneDecidesTheHour() throws {
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        let cron = try CronExpression("0 8 * * *")
        // The same instant, two zones: 08:00 is 02:15 UTC in Kathmandu (+05:45)
        // and 07:00 UTC in Copenhagen in winter.
        XCTAssertEqual(cron.next(after: local("2026-11-02 00:00", utc), in: kathmandu), local("2026-11-02 02:15", utc))
        XCTAssertEqual(cron.next(after: local("2026-11-02 00:00", utc), in: copenhagen), local("2026-11-02 07:00", utc))
    }

    func testDaylightSavingSkipsTheMissingHour() throws {
        // The spring-forward night has no 02:00-02:59 in Copenhagen.
        XCTAssertEqual(try next("30 2 * * *", after: "2027-03-28 01:00"), local("2027-03-29 02:30"))
        XCTAssertEqual(try next("*/30 * * * *", after: "2027-03-28 01:45"), local("2027-03-28 03:00"))
    }

    func testClocksChangingAtMidnightDontSkipADay() throws {
        // Santiago's clocks jump from midnight to 01:00 on Sunday 6 September,
        // so that day starts at 01:00; the following Monday still has a 00:00.
        let santiago = TimeZone(identifier: "America/Santiago")!
        XCTAssertEqual(try next("0 0 * * 1", after: "2026-09-06 12:00", zone: santiago), local("2026-09-07 00:00", santiago))
    }

    func testRejectsMalformedExpressions() {
        for bad in ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
                    "*/0 * * * *", "5-1 * * * *", "a * * * *", "1/2/3 * * * *", "1,,2 * * * *",
                    "70/5 * * * *", "* 30/2 * * *"] {
            XCTAssertThrowsError(try CronExpression(bad), bad)
        }
    }

    func testRejectsDatesThatNeverCome() throws {
        XCTAssertThrowsError(try CronExpression("0 0 30 2 *"))
        XCTAssertThrowsError(try CronExpression("0 0 31 4,6,9,11 *"))
        // Leap days come, and a day of week makes any day of month reachable.
        XCTAssertEqual(try next("0 0 29 2 *", after: "2026-11-02 13:07"), local("2028-02-29 00:00"))
        XCTAssertNotNil(try next("0 0 30 2 1", after: "2026-11-02 13:07"))
    }

    func testEarliestEntryWins() throws {
        let schedule = PollSchedule([try entry("*/5 8-17 * * 1-5"), try entry("*/30 * * * *")])
        XCTAssertEqual(schedule.next(after: local("2026-11-02 13:07")), local("2026-11-02 13:10"))
        XCTAssertEqual(schedule.next(after: local("2026-11-02 18:07")), local("2026-11-02 18:30"))
        XCTAssertEqual(schedule.next(after: local("2026-11-07 10:01")), local("2026-11-07 10:30"))
    }

    func testEachEntryReadsItsOwnTimeZone() throws {
        let schedule = PollSchedule([try entry("0 9 * * *", "America/New_York"), try entry("0 9 * * *", "Asia/Kathmandu")])
        // 09:00 in Kathmandu is 03:15 UTC; in New York it is 14:00 UTC.
        XCTAssertEqual(schedule.next(after: local("2026-11-02 00:00", utc)), local("2026-11-02 03:15", utc))
        XCTAssertEqual(schedule.next(after: local("2026-11-02 04:00", utc)), local("2026-11-02 14:00", utc))
    }

    func testUnknownTimeZoneIsRefused() {
        XCTAssertThrowsError(try entry("* * * * *", "Mars/Olympus"))
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
            "pollSchedule: \"*/5 * * * *\"",
        ]
        for text in cases {
            XCTAssertThrowsError(try ConfigFile.decode(text), text) { error in
                guard case ConfigFile.Error.invalid = error else { return XCTFail("\(text): \(error)") }
            }
        }
    }

    func testAnErrorInsideAListNamesTheEntryAndTheProblem() {
        let cases = [
            ("pollSchedule:\n  - cron: \"*/5 * * * *\"\n  - cron: \"* * *\"", "has 3 fields"),
            ("pollSchedule:\n  - cron: \"*/5 * * * *\"\n    timezone: Mars/Olympus", "unknown time zone"),
            ("pollSchedule:\n  - cron: \"0 0 30 2 *\"", "never matches"),
        ]
        for (text, problem) in cases {
            XCTAssertThrowsError(try ConfigFile.decode(text), text) { error in
                guard case let ConfigFile.Error.invalid(_, reason) = error else { return XCTFail("\(text): \(error)") }
                XCTAssertTrue(reason.contains(problem), "\(text): \(reason)")
                XCTAssertTrue(reason.contains("pollSchedule["), "\(text): \(reason)")
            }
        }
    }

    func testUnknownKeysInEitherShapeAreReported() throws {
        let single = try ConfigFile.decode("pollSchedule:\n  cron: \"*/5 * * * *\"\n  tz: UTC")
        XCTAssertEqual(single.warnings.count, 1)
        XCTAssertTrue(single.warnings[0].contains("pollSchedule.tz"), single.warnings[0])
        let list = try ConfigFile.decode("pollSchedule:\n  - cron: \"*/5 * * * *\"\n    tz: UTC")
        XCTAssertEqual(list.warnings.count, 1)
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
            // One entry is written back as a mapping, several as a list.
            let schedule = try XCTUnwrap(config.pollSchedule)
            let json = String(decoding: try JSONEncoder().encode(schedule), as: UTF8.self)
            XCTAssertEqual(json.first, schedule.entries.count == 1 ? "{" : "[", json)
        }
    }

    // MARK: - poller

    @MainActor
    func testPollerWaitsForTheSchedule() throws {
        let poller = PRPoller(fetcher: { [] })
        let now = local("2026-11-02 13:07")
        XCTAssertEqual(poller.nextWait(now: now).delay, 60, "no schedule: the fixed interval")
        XCTAssertNil(poller.nextWait(now: now).at)
        poller.schedule = PollSchedule([try entry("*/5 * * * *")])
        XCTAssertEqual(poller.nextWait(now: now).delay, 180)
        XCTAssertEqual(poller.nextWait(now: now).at, local("2026-11-02 13:10"))
    }

    @MainActor
    func testWakingAMomentEarlyDoesNotPollTheSameTimeTwice() throws {
        let poller = PRPoller(fetcher: { [] })
        poller.schedule = PollSchedule([try entry("*/5 * * * *")])
        let target = local("2026-11-02 13:10")
        XCTAssertEqual(poller.nextWait(now: target.addingTimeInterval(-0.005), after: target).at, local("2026-11-02 13:15"))
    }

    @MainActor
    func testScheduleChangeRearmsTheRunningLoop() async throws {
        let counter = Counter()
        let poller = PRPoller(fetcher: { await counter.increment(); return [] })
        // Leap-day midnights only: the loop polls once at start, then waits.
        poller.schedule = PollSchedule([try entry("0 0 29 2 *")])
        poller.start()
        try await waitFor { await counter.value == 1 }
        // Re-arming waits for the next scheduled time rather than polling at
        // once; the config reload polls on its own.
        poller.schedule = PollSchedule([try entry("30 0 29 2 *")])
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

@MainActor
final class PollScheduleRuntimeTests: XCTestCase {
    func testTheRuntimeFollowsTheScheduleInTheConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prbar.yaml")
        try "pollSchedule:\n  cron: \"*/30 * * * *\"\n".write(to: file, atomically: true, encoding: .utf8)

        let runtime = RuntimeFixtures.make(dir, ownsAutomation: false)
        XCTAssertEqual(runtime.poller.schedule?.entries.map(\.cron.text), ["*/30 * * * *"])

        try "pollSchedule:\n  cron: \"*/5 * * * *\"\n".write(to: file, atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        XCTAssertEqual(runtime.poller.schedule?.entries.map(\.cron.text), ["*/5 * * * *"])

        try "version: 1\n".write(to: file, atomically: true, encoding: .utf8)
        runtime.repoConfigs.reloadIfChanged()
        XCTAssertNil(runtime.poller.schedule)
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
