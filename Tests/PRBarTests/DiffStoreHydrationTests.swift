import XCTest
@testable import PRBar

/// Hoisted out of the test class: the fetcher closure is `@Sendable` and
/// cannot reach a `@MainActor`-isolated static.
private let hydrationFixtureDiff = """
diff --git a/foo.go b/foo.go
index abc..def 100644
--- a/foo.go
+++ b/foo.go
@@ -1,3 +1,4 @@
 package foo
+import "log"

 func Bar() {}
"""

/// The window between opening a PR and its cached diff reaching memory.
///
/// `PRDetailView.postableInlineComments` anchors a review's annotations
/// against the parsed hunks and yields nothing while `status(for:)` is
/// anything but `.loaded`. Hydration is asynchronous, so that window is
/// real — and a review posted inside it carries none of its findings.
/// GitHub has no way to add line comments to a review after submission,
/// so the loss is permanent.
@MainActor
final class DiffStoreHydrationTests: XCTestCase {
    private let annotations = [
        DiffAnnotation(path: "foo.go", lineStart: 2, lineEnd: 2, severity: .warning, body: "unused import")
    ]

    /// A store that has the diff on disk but not yet in memory reports
    /// `.idle`, so the mapping produces zero comments for annotations that
    /// map cleanly once the same diff is loaded.
    func testCachedDiffIsNotVisibleUntilHydrationCompletes() async throws {
        let container = PRBarModelContainer.inMemory()
        let pr = makePR()

        // First session: fetch once so the parsed diff is written through.
        let warm = DiffStore(diffFetcher: { _, _, _ in hydrationFixtureDiff }, container: container)
        warm.ensureLoaded(for: pr)
        try await waitUntil { if case .loaded = warm.status(for: pr) { return true }; return false }

        guard case .loaded(let hunks) = warm.status(for: pr) else {
            return XCTFail("expected the warm store to hold hunks")
        }
        XCTAssertEqual(
            InlineCommentMapper.map(annotations: annotations, hunks: hunks).count, 1,
            "the annotation anchors cleanly once hunks are in hand"
        )

        // Second session over the same store: the row is on disk, but a
        // fresh instance has nothing in memory until `ensureLoaded` lands.
        let cold = DiffStore(diffFetcher: { _, _, _ in
            XCTFail("hydration should come off disk, not a refetch")
            return ""
        }, container: container)

        XCTAssertEqual(cold.status(for: pr), .idle, "the cold window this test exists for")

        // What the post path would send if the user acted right now.
        let postableWhileCold: [GHClient.InlineComment]
        if case .loaded(let h) = cold.status(for: pr) {
            postableWhileCold = InlineCommentMapper.map(annotations: annotations, hunks: h)
        } else {
            postableWhileCold = []
        }
        XCTAssertTrue(
            postableWhileCold.isEmpty,
            "a review posted in this window carries none of its annotations"
        )

        // And it does resolve — the window is transient, which is exactly
        // why the post controls have to wait it out rather than refuse.
        cold.ensureLoaded(for: pr)
        try await waitUntil { if case .loaded = cold.status(for: pr) { return true }; return false }
    }

    // MARK: helpers

    private func makePR() -> InboxPR {
        InboxPR(
            nodeId: "PR_1",
            owner: "getsynq", repo: "cloud", number: 1,
            title: "t", body: "",
            url: URL(string: "https://github.com/getsynq/cloud/pull/1")!,
            author: "alice",
            headRef: "h", baseRef: "main", headSha: "abc1234",
            isDraft: false,
            role: .reviewRequested,
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
            reviewDecision: "REVIEW_REQUIRED", checkRollupState: "SUCCESS",
            totalAdditions: 1, totalDeletions: 0, changedFiles: 1,
            hasAutoMerge: false, autoMergeEnabledBy: nil,
            allCheckSummaries: [],
            allowedMergeMethods: [.squash],
            autoMergeAllowed: true, deleteBranchOnMerge: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout.components.seconds))
        while !condition() {
            if Date() > deadline { return XCTFail("waitUntil timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
