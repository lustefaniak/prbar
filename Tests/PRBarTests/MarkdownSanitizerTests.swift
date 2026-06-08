import XCTest
@testable import PRBar

final class MarkdownSanitizerTests: XCTestCase {
    func testStripsHTMLComments() {
        let input = "before <!-- Sticky Pull Request Comment marker --> after"
        XCTAssertEqual(MarkdownSanitizer.sanitize(input), "before  after")
    }

    func testStripsMultiLineComment() {
        let input = "a\n<!--\nhidden\nmetadata\n-->\nb"
        XCTAssertFalse(MarkdownSanitizer.sanitize(input).contains("hidden"))
        XCTAssertTrue(MarkdownSanitizer.sanitize(input).contains("a"))
        XCTAssertTrue(MarkdownSanitizer.sanitize(input).contains("b"))
    }

    func testConvertsAnchorToMarkdownLink() {
        let input = #"<a href="https://linear.app/acme/issue/ABC-123">ABC-123 Do the thing</a>"#
        XCTAssertEqual(
            MarkdownSanitizer.sanitize(input),
            "[ABC-123 Do the thing](https://linear.app/acme/issue/ABC-123)"
        )
    }

    func testStripsWrapperTagsKeepingText() {
        let input = "<details>\n<summary>Title</summary>\n<p>\nBody text\n</p>\n</details>"
        let out = MarkdownSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("Title"))
        XCTAssertTrue(out.contains("Body text"))
        XCTAssertFalse(out.contains("<details>"))
        XCTAssertFalse(out.contains("<summary>"))
        XCTAssertFalse(out.contains("<p>"))
    }

    func testConvertsBrToNewline() {
        let input = "line one<br>line two<br/>line three"
        XCTAssertEqual(MarkdownSanitizer.sanitize(input), "line one\nline two\nline three")
    }

    func testProtectsFencedCodeBlock() {
        let input = "text\n```\n<div>literal</div>\n<!-- keep -->\n```\nmore"
        let out = MarkdownSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("<div>literal</div>"))
        XCTAssertTrue(out.contains("<!-- keep -->"))
    }

    func testProtectsInlineCodeSpan() {
        let input = "use `<br>` to break and `<!-- x -->` is a comment"
        let out = MarkdownSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("`<br>`"))
        XCTAssertTrue(out.contains("`<!-- x -->`"))
    }

    func testPreservesGFMAutolink() {
        let input = "see <https://example.com> for details"
        XCTAssertEqual(MarkdownSanitizer.sanitize(input), "see <https://example.com> for details")
    }

    func testLinearLinkbackComment() {
        // Shape of a real linear-code linkback comment (generic content).
        let input = """
        <!-- linear-linkback -->
        <details>
        <summary><a href="https://linear.app/acme/issue/ABC-123/do-thing">ABC-123 Do the thing</a></summary>
        <p>

        Some description of the work.

        </p>
        </details>
        """
        let out = MarkdownSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("linear-linkback"))
        XCTAssertFalse(out.contains("<details>"))
        XCTAssertTrue(out.contains("[ABC-123 Do the thing](https://linear.app/acme/issue/ABC-123/do-thing)"))
        XCTAssertTrue(out.contains("Some description of the work."))
    }

    func testPlainTextUnchanged() {
        let input = "A normal comment with **bold** and a [link](https://example.com)."
        XCTAssertEqual(MarkdownSanitizer.sanitize(input), input)
    }
}
