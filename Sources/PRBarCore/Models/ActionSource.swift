import Foundation

/// Where an action originated. Drives which `ActionLogKind` is recorded
/// and whether cost is logged (an automated post carries the AI cost).
enum ActionSource: Sendable, Equatable {
    case manual
    /// Posted by the auto-approve / auto-deny policy rather than a user click.
    case automated
    /// Posted by the share-findings policy — automated, but deliberately
    /// carrying no verdict. Separate from `.automated` only so the action
    /// log can tell it apart; it posts the same COMMENT event an auto-deny
    /// would.
    case sharedFindings

    /// True for every write PRBar made on its own initiative.
    var isAutomated: Bool { self != .manual }
}
