import XCTest
@testable import PRBar

/// The marker is the whole cross-instance contract: whichever PRBar posts
/// first writes it, every other requested reviewer's PRBar reads it out of
/// the review bodies the poll already fetches and skips its own run. Both
/// halves have to agree on the format forever, so it is pinned here.
final class PRBarVerdictMarkerTests: XCTestCase {

    func testEmitIsTheAgreedFormat() {
        XCTAssertEqual(
            PRBarVerdictMarker.emit(sha: "deadbeef"),
            "<!-- prbar:verdict sha=deadbeef v=1 -->"
        )
    }

    func testMatchesOnlyTheSameSha() {
        let body = PRBarVerdictMarker.append(to: "Looks fine.", sha: "aaa111")
        XCTAssertTrue(PRBarVerdictMarker.matches(sha: "aaa111", in: body))
        XCTAssertFalse(PRBarVerdictMarker.matches(sha: "bbb222", in: body))
    }

    /// A push moves the head SHA, no marker matches, every instance
    /// re-triages. That re-arming is the reason the key is the SHA.
    func testNewShaDoesNotMatchAnOlderMarker() {
        let body = PRBarVerdictMarker.append(to: "", sha: "old")
        XCTAssertFalse(PRBarVerdictMarker.matches(sha: "new", in: body))
    }

    func testUnmarkedBodyDoesNotMatch() {
        XCTAssertFalse(PRBarVerdictMarker.matches(sha: "aaa111", in: "Looks fine."))
    }

    /// An empty SHA would otherwise match every body carrying any marker
    /// (and produce a marker matching nothing on the way out).
    func testEmptyShaNeitherMatchesNorMarks() {
        XCTAssertFalse(PRBarVerdictMarker.matches(sha: "", in: PRBarVerdictMarker.emit(sha: "x")))
        XCTAssertEqual(PRBarVerdictMarker.append(to: "body", sha: ""), "body")
    }

    /// A share whose findings all landed inline posts an empty body, so the
    /// marker has to survive being the entire body.
    func testAppendToEmptyBodyIsTheBareMarker() {
        XCTAssertEqual(
            PRBarVerdictMarker.append(to: "", sha: "abc"),
            "<!-- prbar:verdict sha=abc v=1 -->"
        )
    }

    /// Matching stops at the SHA so a future `v=2` instance still dedups
    /// against the reviews a `v=1` instance posted, and vice versa.
    func testMatchIsVersionTolerant() {
        let futureMarker = "<!-- prbar:verdict sha=abc v=2 extra=1 -->"
        XCTAssertTrue(PRBarVerdictMarker.matches(sha: "abc", in: futureMarker))
    }

    func testStripLeavesTheHumanBodyBehind() {
        let body = PRBarVerdictMarker.append(to: "Looks fine.", sha: "abc")
        XCTAssertEqual(PRBarVerdictMarker.strip(from: body), "Looks fine.")
    }

    /// The case that keeps a share out of the activity timeline: strip has
    /// to take a marker-only body back to empty, or `InboxPR` stops
    /// dropping it and renders a blank review row.
    func testStripTakesMarkerOnlyBodyToEmpty() {
        XCTAssertEqual(PRBarVerdictMarker.strip(from: PRBarVerdictMarker.emit(sha: "abc")), "")
    }

    func testStripIsANoOpOnAnUnmarkedBody() {
        XCTAssertEqual(PRBarVerdictMarker.strip(from: "Looks fine."), "Looks fine.")
    }

    func testStripRemovesEveryMarker() {
        let doubled = PRBarVerdictMarker.emit(sha: "a") + "\n\nHi\n\n" + PRBarVerdictMarker.emit(sha: "b")
        XCTAssertEqual(PRBarVerdictMarker.strip(from: doubled), "Hi")
    }

    /// A malformed marker (no closing `-->`, e.g. truncated by a paste)
    /// must not eat the rest of the body.
    func testStripLeavesAnUnterminatedMarkerAlone() {
        let body = "Looks fine. <!-- prbar:verdict sha=abc v=1"
        XCTAssertEqual(PRBarVerdictMarker.strip(from: body), body)
    }
}
