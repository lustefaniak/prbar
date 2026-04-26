import Foundation
import SwiftData

/// SwiftData persistence cell for one user-edited `RepoConfig`. The
/// config struct is stored as a JSON blob in `payload` so its shape can
/// evolve (adding fields, defaulting old ones) without a SwiftData
/// migration. `orderIndex` preserves the editor's list ordering, which
/// also drives glob-match precedence (most-specific first).
@Model
final class RepoConfigEntry {
    @Attribute(.unique) var id: UUID = UUID()
    var orderIndex: Int = 0
    var payload: Data = Data()

    init(id: UUID = UUID(), orderIndex: Int, payload: Data) {
        self.id = id
        self.orderIndex = orderIndex
        self.payload = payload
    }
}
