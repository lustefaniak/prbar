import Foundation

struct Hunk: Sendable, Hashable, Codable {
    let filePath: String      // e.g. "kernel-billing/audit/log.go"
    let oldStart: Int         // 1-indexed line number in the old file
    let oldCount: Int
    let newStart: Int         // 1-indexed line number in the new file
    let newCount: Int
    let lines: [DiffLine]
}

enum DiffLine: Sendable, Hashable, Codable {
    case context(String)
    case added(String)
    case removed(String)

    var prefix: Character {
        switch self {
        case .context: return " "
        case .added:   return "+"
        case .removed: return "-"
        }
    }

    var content: String {
        switch self {
        case .context(let s), .added(let s), .removed(let s):
            return s
        }
    }
}
