import Foundation

/// One GitHub review thread, reduced to what the resolve decision needs.
struct ReviewThread: Sendable, Hashable {
    /// GraphQL node id — what `resolveReviewThread` takes.
    let id: String
    let isResolved: Bool
    /// True once the code the thread anchored to has changed. GitHub's own
    /// signal that the author touched these lines.
    let isOutdated: Bool
    let path: String
    let comments: [Comment]

    struct Comment: Sendable, Hashable {
        let authorLogin: String
        let body: String
    }
}

/// Pure decision: which review threads a completed triage has earned the
/// right to resolve.
///
/// Resolving is not cosmetic — it collapses the thread for every human on
/// the PR, so the bar is deliberately all-of, not any-of. Three conditions
/// must hold together: the author engaged with the thread, the anchored
/// code changed, and the triage's findings omit it. Each alone is a weak
/// signal — an author can reply to disagree, `isOutdated` fires on an
/// unrelated edit to the same lines, and a finding can drop out of a
/// review because the model got distracted rather than because the code
/// was fixed.
enum ReviewThreadResolver {
    /// Threads eligible to resolve, given the findings a triage produced.
    ///
    /// - `threads`: every thread on the PR.
    /// - `annotations`: the findings that triage reported.
    /// - `viewerLogin`: whose threads are ours to close. A thread PRBar
    ///   didn't open is someone else's conversation.
    static func resolvable(
        threads: [ReviewThread],
        annotations: [DiffAnnotation],
        viewerLogin: String
    ) -> [ReviewThread] {
        guard !viewerLogin.isEmpty else { return [] }
        let raised = Set(annotations.map(key))
        return threads.filter { thread in
            guard !thread.isResolved else { return false }
            // Outdated is GitHub telling us the anchored code changed. A
            // thread on untouched code has nothing to have been fixed.
            guard thread.isOutdated else { return false }
            guard let root = thread.comments.first else { return false }
            // Only close threads PRBar opened.
            guard root.authorLogin == viewerLogin else { return false }
            // Somebody other than us has to have engaged. Without this a
            // force-push alone would silently close every open finding.
            guard thread.comments.dropFirst().contains(where: { $0.authorLogin != viewerLogin })
            else { return false }
            // The finding must be absent from what triage reported.
            guard let title = title(ofCommentBody: root.body) else { return false }
            return !raised.contains(key(path: thread.path, title: title))
        }
    }

    /// `InlineCommentMapper` posts each finding as `**<title>**\n\n<body>`,
    /// so the bolded first line is what maps a thread back to the
    /// annotation that created it. A comment without one can't be
    /// correlated, and is left alone rather than guessed at.
    static func title(ofCommentBody body: String) -> String? {
        guard let firstLine = body.split(separator: "\n", maxSplits: 1).first else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 else { return nil }
        return String(trimmed.dropFirst(2).dropLast(2))
    }

    private static func key(_ annotation: DiffAnnotation) -> String {
        key(path: annotation.path, title: annotation.title ?? "")
    }

    private static func key(path: String, title: String) -> String {
        "\(path)\u{1}\(title.trimmingCharacters(in: .whitespaces))"
    }
}
