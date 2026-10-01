import Foundation

/// What a coding agent (a client that connected through `prbar-review mcp`)
/// may ask PRBar to do. The server enforces it, so it holds headless too.
enum AgentPermission: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case allow
    /// PRBar asks you before acting. With nobody to ask, it acts as `off`.
    case ask
}

/// The `agents:` block of `prbar.yaml`.
struct AgentPolicy: Sendable, Hashable, Codable {
    enum Capability: String, Sendable, CaseIterable {
        /// Inbox, reviews, history, status.
        case read
        /// Start an AI review.
        case review
        /// Comment, approve, request changes.
        case post
        case merge
    }

    var read: AgentPermission = .allow
    var review: AgentPermission = .allow
    var post: AgentPermission = .ask
    var merge: AgentPermission = .off

    init() {}

    subscript(capability: Capability) -> AgentPermission {
        get {
            switch capability {
            case .read: return read
            case .review: return review
            case .post: return post
            case .merge: return merge
            }
        }
        set {
            switch capability {
            case .read: read = newValue
            case .review: review = newValue
            case .post: post = newValue
            case .merge: merge = newValue
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case read, review, post, merge
    }

    // A value that doesn't parse turns the capability off rather than
    // falling back to its default: for a permission, a typo must not
    // grant more than the user wrote.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases where c.contains(key) {
            let capability = Capability(rawValue: key.rawValue)!
            self[capability] = (try? c.decode(AgentPermission.self, forKey: key)) ?? .off
        }
    }

    /// Only what differs from the shipped defaults, like the rest of the file.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let shipped = AgentPolicy()
        for key in CodingKeys.allCases {
            let capability = Capability(rawValue: key.rawValue)!
            if self[capability] != shipped[capability] {
                try c.encode(self[capability], forKey: key)
            }
        }
    }
}
