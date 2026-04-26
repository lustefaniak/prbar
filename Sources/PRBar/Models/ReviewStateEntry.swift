import Foundation
import SwiftData

/// SwiftData persistence cell for `ReviewState`. The full `ReviewState`
/// graph (status, AggregatedReview, prior review, etc.) is stored as a
/// JSON blob — relational queries against review internals aren't a
/// thing the app needs, and the alternative (modeling every nested
/// struct as a `@Model`) buys nothing while costing migration risk.
@Model
final class ReviewStateEntry {
    /// Stable PR node id. Acts as the cache key.
    @Attribute(.unique) var prNodeId: String = ""

    /// JSON-encoded `ReviewState`.
    var payload: Data = Data()

    /// Mirrored timestamp so SwiftData can sort cheaply without
    /// decoding every payload.
    var triggeredAt: Date = Date()

    init(prNodeId: String, payload: Data, triggeredAt: Date) {
        self.prNodeId = prNodeId
        self.payload = payload
        self.triggeredAt = triggeredAt
    }
}
