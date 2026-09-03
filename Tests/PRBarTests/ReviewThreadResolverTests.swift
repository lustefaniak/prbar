import XCTest
@testable import PRBar

/// Resolving collapses a thread for every human on the PR, so each of the
/// three gates gets its own negative case — a regression that drops one
/// would otherwise still pass the happy path.
final class ReviewThreadResolverTests: XCTestCase {
    private let me = "prbar-user"
    private let author = "someone-else"

    func testResolvesWhenAuthorRepliedCodeChangedAndFindingIsGone() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread()],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertEqual(result.map(\.id), ["T1"])
    }

    func testKeepsThreadWhenTheFindingStillStands() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread()],
            annotations: [annotation(path: "a.swift", title: "Unchecked nil")],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty, "the AI still reports it — the author's reply didn't settle it")
    }

    /// Without this gate a force-push alone silently closes every open
    /// finding, because `isOutdated` flips on any edit to those lines.
    func testKeepsThreadWhenNobodyReplied() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(comments: [comment(me, "**Unchecked nil**\n\nboom")])],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testKeepsThreadWhenCodeDidNotChange() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(isOutdated: false)],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testIgnoresThreadsPRBarDidNotOpen() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(comments: [
                comment(author, "**Some human's point**\n\nhmm"),
                comment(me, "fair"),
            ])],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty, "someone else's conversation is not ours to close")
    }

    func testIgnoresAlreadyResolvedThreads() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(isResolved: true)],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A reply from the viewer isn't the author engaging — it's PRBar (or
    /// the user) talking to itself.
    func testSelfReplyDoesNotCount() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(comments: [
                comment(me, "**Unchecked nil**\n\nboom"),
                comment(me, "still think so"),
            ])],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A comment PRBar didn't format can't be correlated to a finding, so
    /// closing it would be a guess.
    func testUncorrelatableCommentIsLeftAlone() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread(comments: [
                comment(me, "just a plain remark, no bold title"),
                comment(author, "ok"),
            ])],
            annotations: [],
            viewerLogin: me
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyViewerLoginResolvesNothing() {
        XCTAssertTrue(
            ReviewThreadResolver.resolvable(threads: [thread()], annotations: [], viewerLogin: "").isEmpty,
            "an unknown viewer would make every thread look like ours"
        )
    }

    /// Same title on a different file is a different finding.
    func testMatchIsPathScoped() {
        let result = ReviewThreadResolver.resolvable(
            threads: [thread()],
            annotations: [annotation(path: "other.swift", title: "Unchecked nil")],
            viewerLogin: me
        )
        XCTAssertEqual(result.map(\.id), ["T1"])
    }

    func testTitleParsing() {
        XCTAssertEqual(ReviewThreadResolver.title(ofCommentBody: "**Boom**\n\nbody"), "Boom")
        XCTAssertNil(ReviewThreadResolver.title(ofCommentBody: "no title here"))
        XCTAssertNil(ReviewThreadResolver.title(ofCommentBody: "****"))
    }

    // MARK: - helpers

    private func thread(
        isResolved: Bool = false,
        isOutdated: Bool = true,
        comments: [ReviewThread.Comment]? = nil
    ) -> ReviewThread {
        ReviewThread(
            id: "T1",
            isResolved: isResolved,
            isOutdated: isOutdated,
            path: "a.swift",
            comments: comments ?? [
                comment(me, "**Unchecked nil**\n\nthis can crash"),
                comment(author, "fixed, thanks"),
            ]
        )
    }

    private func comment(_ login: String, _ body: String) -> ReviewThread.Comment {
        ReviewThread.Comment(authorLogin: login, body: body)
    }

    private func annotation(path: String, title: String) -> DiffAnnotation {
        DiffAnnotation(
            path: path, lineStart: 1, lineEnd: 1, severity: .warning,
            title: title, body: "b"
        )
    }
}
