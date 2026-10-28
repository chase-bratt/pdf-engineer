import Foundation

/// A single reversible mutation of a document.
///
/// This is the *only* mutation path. A menu click, a keyboard
/// shortcut, and an MCP tool call from Claude all construct a `Command` and hand
/// it to a ``CommandStack``. That is what makes the trust model
/// enforceable rather than aspirational: Claude has no privileged route that
/// bypasses undo or the audit log.
///
/// The state is generic so the stack can be unit-tested without PDFKit, and so
/// the same machinery can drive sub-document state later.
public protocol Command<State>: Sendable {
    associatedtype State: Sendable

    /// Human-readable description, shown in **both** the undo menu and Claude's
    /// consent prompt. One source of truth, so the two can never disagree about
    /// what an operation does.
    var summary: String { get }

    /// Whether this command destroys information.
    ///
    /// Drives consent: destructive commands require
    /// explicit per-call confirmation that is never remembered.
    var isDestructive: Bool { get }

    /// Returns the new state. Must not mutate `state` — the project's
    /// immutability rule, and what makes snapshots cheap and undo exact.
    func apply(to state: State) throws -> State

    /// The command that reverses this one, given the state *before* `apply`.
    ///
    /// Taking the pre-state as a parameter is what lets a destructive command
    /// capture what it is about to discard (a deleted page, an overwritten
    /// value) so the inverse can restore it.
    func inverse(for state: State) throws -> any Command<State>
}

/// Who initiated a command.
///
/// Claude's edits must be visibly labelled in the undo history, so the user can always see — and reverse — what the assistant did.
public enum CommandOrigin: String, Sendable, Equatable, Codable {
    /// A direct user action: click, shortcut, drag.
    case user
    /// An MCP tool call from Claude.
    case assistant
    /// An automatic system action, e.g. a migration or repair on open.
    case system
}

/// Errors raised by the command machinery.
public enum CommandError: Error, Equatable, Sendable {
    case nothingToUndo
    case nothingToRedo
    /// A command's precondition no longer holds — typically because the document
    /// changed between the command being built and applied.
    case preconditionFailed(String)
}

extension CommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingToUndo: return "There is nothing to undo."
        case .nothingToRedo: return "There is nothing to redo."
        case let .preconditionFailed(reason):
            return "The operation is no longer valid: \(reason)"
        }
    }
}

/// One entry in the audit log.
///
/// Every tool call must be recorded and user-inspectable. This is the record for the mutation half of that.
public struct CommandRecord: Sendable, Equatable {
    public let summary: String
    public let isDestructive: Bool
    public let origin: CommandOrigin

    public init(summary: String, isDestructive: Bool, origin: CommandOrigin) {
        self.summary = summary
        self.isDestructive = isDestructive
        self.origin = origin
    }
}
