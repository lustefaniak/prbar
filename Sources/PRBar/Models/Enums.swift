import Foundation

enum PRRole: String, Codable, Sendable, Hashable, CaseIterable {
    case authored
    case reviewRequested
    case both
    case other
}
