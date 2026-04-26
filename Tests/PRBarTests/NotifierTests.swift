import XCTest
@testable import PRBar

@MainActor
final class NotifierTests: XCTestCase {
    func testCoalescedDeliveryAfterDebounceWindow() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(80)

        notifier.enqueue([event(node: "A"), event(node: "B")])
        notifier.enqueue([event(node: "C")])  // resets the timer

        try await Task.sleep(for: .milliseconds(180))

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, "all events should coalesce into one delivery")
        XCTAssertEqual(calls.first?.map(\.prNodeId), ["A", "B", "C"])
    }

    func testDuplicateEventsNotEnqueuedTwice() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(50)

        notifier.enqueue([event(node: "A")])
        notifier.enqueue([event(node: "A")])  // dup
        notifier.enqueue([event(node: "B")])

        try await Task.sleep(for: .milliseconds(120))

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.map(\.prNodeId), ["A", "B"])
    }

    func testSuppressedWhilePopoverVisible() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(50)
        notifier.postPopoverCloseDelay = .milliseconds(20)
        notifier.setPopoverVisible(true)

        notifier.enqueue([event(node: "A")])
        try await Task.sleep(for: .milliseconds(120))

        var calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "should not deliver while popover visible")

        notifier.setPopoverVisible(false)
        try await Task.sleep(for: .milliseconds(80))

        calls = await recorder.calls
        XCTAssertEqual(calls.count, 1, "delivery should fire shortly after popover closes")
        XCTAssertEqual(calls.first?.map(\.prNodeId), ["A"])
    }

    func testEmptyEnqueueIsNoOp() async throws {
        let recorder = RecordingDeliverer()
        let notifier = Notifier(deliverer: recorder)
        notifier.debounceWindow = .milliseconds(40)

        notifier.enqueue([])
        try await Task.sleep(for: .milliseconds(80))

        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTitleAndBodyForMixedEvents() {
        let events = [
            event(node: "A", kind: .readyToMerge),
            event(node: "B", kind: .newReviewRequest),
            event(node: "C", kind: .newReviewRequest),
        ]
        XCTAssertEqual(
            UNNotificationDeliverer.title(for: events),
            "PRBar: 1 ready to merge, 2 reviews"
        )
        XCTAssertEqual(
            UNNotificationDeliverer.category(for: events),
            "merge_ready",
            "merge_ready outranks reviews_ready"
        )
    }

    // MARK: helpers

    private func event(
        node: String,
        kind: NotificationEvent.Kind = .readyToMerge
    ) -> NotificationEvent {
        NotificationEvent(
            kind: kind,
            prNodeId: node,
            prTitle: "title \(node)",
            prRepo: "o/r",
            prNumber: 1,
            prURL: URL(string: "https://github.com/o/r/pull/1")!
        )
    }
}

private actor RecordingDeliverer: NotificationDeliverer {
    private(set) var calls: [[NotificationEvent]] = []
    func requestAuthorization() async {}
    func deliver(_ events: [NotificationEvent]) async {
        calls.append(events)
    }
}
