import Foundation

enum PRRole: String, Codable, Sendable, Hashable, CaseIterable {
    case authored
    case reviewRequested
    case both
    case other
}

enum MergeMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case squash
    case merge
    case rebase

    var ghFlag: String {
        switch self {
        case .squash: return "--squash"
        case .merge: return "--merge"
        case .rebase: return "--rebase"
        }
    }

    var displayName: String {
        switch self {
        case .squash: return "Squash and merge"
        case .merge:  return "Create a merge commit"
        case .rebase: return "Rebase and merge"
        }
    }
}
