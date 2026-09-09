import Foundation

/// Whether a review's inline annotations can be posted yet.
///
/// `PRDetailView.postableInlineComments` anchors annotations against the
/// diff's parsed hunks and yields nothing until those hunks are in memory.
/// Hydration is asynchronous — a SQLite read plus a JSON decode of a
/// payload that runs to megabytes, both deliberately off the main actor —
/// so opening a PR and immediately pressing the post button submits the
/// verdict with none of its findings. GitHub has no API to attach line
/// comments to a review after submission, so that loss is permanent and
/// silent: the review lands, it just says nothing.
///
/// Pure so the rule is testable without driving SwiftUI state, the same
/// reason `ReviewAdvance.next` exists.
enum InlineCommentReadiness {
    enum State: Equatable {
        /// No annotations to anchor, so nothing can be dropped. Posting is
        /// unaffected by the diff.
        case nothingToPost
        /// Hunks are in memory; the mapping runs against real data.
        case ready
        /// Still hydrating or fetching. Transient — the fix is to wait it
        /// out, not to refuse the post.
        case waitingForDiff
        /// The diff could not be read at all. Posting stays allowed: a PR
        /// whose diff never loads would otherwise be unreviewable from
        /// PRBar entirely, which is worse than a review without inline
        /// comments the user can see is missing.
        case diffUnavailable
    }

    static func state(annotationCount: Int, diff: DiffStore.LoadStatus) -> State {
        guard annotationCount > 0 else { return .nothingToPost }
        switch diff {
        case .loaded:          return .ready
        case .idle, .loading:  return .waitingForDiff
        case .failed:          return .diffUnavailable
        }
    }
}
