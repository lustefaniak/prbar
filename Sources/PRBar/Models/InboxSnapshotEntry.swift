import Foundation
import SwiftData

/// SwiftData persistence cell for one cached `InboxPR`. The full PR
/// struct (including nested check summaries, labels, etc.) is JSON-
/// encoded into `payload` so the cache survives `InboxPR` shape changes
/// without a SwiftData schema migration each time.
@Model
final class InboxSnapshotEntry {
    @Attribute(.unique) var prNodeId: String = ""
    var payload: Data = Data()
    /// `updatedAt` mirror so SwiftData can sort cheaply if needed later
    /// (the load path returns the full set so today this isn't read).
    var updatedAt: Date = Date()

    init(prNodeId: String, payload: Data, updatedAt: Date) {
        self.prNodeId = prNodeId
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
