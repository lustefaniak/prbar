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

/// A page of review threads plus the context the resolve decision needs:
/// who "we" are, and which commit GitHub read the threads against.
struct ReviewThreadPage: Sendable, Hashable {
    let threads: [ReviewThread]
    let viewerLogin: String
    /// The PR's head at fetch time. Compared against the SHA the triage
    /// ran on — see `ReviewQueueWorker.resolveAddressedThreads`.
    let headRefOid: String
}

/// Pure decision: which review threads a completed triage has earned the
/// right to resolve.
///
/// Resolving is not cosmetic — it collapses the thread for every human on
/// the PR, so the bar is deliberately all-of, not any-of. Four conditions
/// must hold together: PRBar wrote the thread, the PR author replied to
/// it, the anchored code changed, and the triage's findings omit it. Each
/// alone is a weak signal — an author can reply to disagree, `isOutdated`
/// fires on an unrelated edit to the same lines, and a finding can drop
/// out of a review because the model got distracted rather than because
/// the code was fixed.
enum ReviewThreadResolver {
    /// Threads eligible to resolve, given the findings a triage produced.
    ///
    /// - `threads`: every thread on the PR.
    /// - `annotations`: the findings that triage reported.
    /// - `viewerLogin`: the authenticated user. Necessary but not
    ///   sufficient for ownership — see `prAuthor` and the marker check.
    /// - `prAuthor`: the PR's author. Only their reply counts as the
    ///   change having been discussed; another reviewer chiming in, or a
    ///   bot, says nothing about whether *this* finding was addressed.
    static func resolvable(
        threads: [ReviewThread],
        annotations: [DiffAnnotation],
        viewerLogin: String,
        prAuthor: String
    ) -> [ReviewThread] {
        guard !viewerLogin.isEmpty, !prAuthor.isEmpty else { return [] }
        // A PR the viewer authored has no "author replied" signal to read:
        // every reply would be their own. Nothing to resolve here.
        guard prAuthor != viewerLogin else { return [] }
        let raised = Set(annotations.map(key))
        return threads.filter { thread in
            guard !thread.isResolved else { return false }
            // Outdated is GitHub telling us the anchored code changed. A
            // thread on untouched code has nothing to have been fixed.
            guard thread.isOutdated else { return false }
            guard let root = thread.comments.first else { return false }
            // Ownership is two checks, not one. The login proves the
            // authenticated user wrote it; the marker proves *PRBar* did.
            // Without the second, every inline comment the user hand-typed
            // on github.com is a candidate for automatic resolution.
            guard root.authorLogin == viewerLogin else { return false }
            guard root.body.contains(InlineCommentMapper.provenanceMarker) else { return false }
            // The PR author has to have engaged. Without this a force-push
            // alone would silently close every open finding.
            guard thread.comments.dropFirst().contains(where: { $0.authorLogin == prAuthor })
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
    ///
    /// A first line with *interior* bold (`**a** and **b**`) is rejected
    /// for the same reason. Naively stripping the outer pair yields
    /// `a** and **b`, which matches no annotation — and "matches no
    /// annotation" is what this function's caller reads as "the finding is
    /// gone", so a mis-parse resolves the thread instead of keeping it.
    static func title(ofCommentBody body: String) -> String? {
        guard let firstLine = body.split(separator: "\n", maxSplits: 1).first else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 else { return nil }
        let inner = String(trimmed.dropFirst(2).dropLast(2))
        guard !inner.contains("**") else { return nil }
        return inner
    }

    private static func key(_ annotation: DiffAnnotation) -> String {
        key(path: annotation.path, title: annotation.title ?? "")
    }

    private static func key(path: String, title: String) -> String {
        "\(path)\u{1}\(title.trimmingCharacters(in: .whitespaces))"
    }
}
