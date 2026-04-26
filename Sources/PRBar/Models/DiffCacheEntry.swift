import Foundation
import SwiftData

/// SwiftData persistence cell for a parsed unified diff. Keyed by
/// `prNodeId@headSha` so a force-push automatically invalidates (the
/// new SHA simply produces a fresh row). Payload is a JSON-encoded
/// `[Hunk]`.
///
/// Only the `.loaded` terminal state of `DiffStore` is persisted —
/// `.loading` / `.failed` are transient and stay in memory.
@Model
final class DiffCacheEntry {
    @Attribute(.unique) var cacheKey: String = ""
    var payload: Data = Data()
    var savedAt: Date = Date()

    init(cacheKey: String, payload: Data, savedAt: Date) {
        self.cacheKey = cacheKey
        self.payload = payload
        self.savedAt = savedAt
    }
}

/// SwiftData persistence cell for a tailed failed-job log. Keyed by
/// `prNodeId@headSha#jobId` so a job re-run (which mints a fresh jobId)
/// also auto-invalidates.
@Model
final class FailureLogCacheEntry {
    @Attribute(.unique) var cacheKey: String = ""
    var tail: String = ""
    var savedAt: Date = Date()

    init(cacheKey: String, tail: String, savedAt: Date) {
        self.cacheKey = cacheKey
        self.tail = tail
        self.savedAt = savedAt
    }
}
