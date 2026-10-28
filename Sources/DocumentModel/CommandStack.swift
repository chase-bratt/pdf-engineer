import Foundation

/// Undo/redo over an immutable state, driven by ``Command``.
///
/// One path, one undo stack, one audit log. Deliberately *not*
/// built on `UndoManager` — `UndoManager` is an AppKit object with main-thread
/// and target-lifetime assumptions, whereas this is a `Sendable` value type that
/// an actor can own and a test can exercise without a UI.
///
/// ## Atomicity
///
/// A command that throws leaves the stack byte-identical to before the attempt:
/// the state is only replaced, and the undo entry only recorded, after both
/// `inverse(for:)` and `apply(to:)` have succeeded. A half-applied mutation is
/// never observable, so a failure can never lose data silently.
public struct CommandStack<State: Sendable>: Sendable {

    /// A command paired with the inverse that reverses it.
    private struct Entry: Sendable {
        let command: any Command<State>
        let inverse: any Command<State>
        let record: CommandRecord
        /// Identifies the state this entry produces. Kept across undo/redo,
        /// so redoing returns to the same version it originally created.
        let version: Int
    }

    /// The current state. Replaced wholesale; never mutated in place.
    public private(set) var state: State

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    /// Upper bound on retained undo entries.
    ///
    /// A long OCR-and-edit session on a large document would otherwise retain
    /// every intermediate snapshot. Capping bounds memory; the cap applies to
    /// *history*, never to the state itself.
    private let historyLimit: Int

    /// Version of the state at the bottom of the undo stack: the initial
    /// state, or the result of the newest entry trimmed away by the cap.
    private var baseVersion = 0

    /// Source of fresh versions. Never reused, so a new edit after an undo
    /// gets a different version from the branch it discarded.
    private var nextVersion = 1

    public init(initial: State, historyLimit: Int = 200) {
        precondition(historyLimit > 0, "historyLimit must be positive")
        self.state = initial
        self.historyLimit = historyLimit
    }

    // MARK: - Querying

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Title for the Undo menu item, e.g. "Undo Rotate 3 Pages".
    public var undoSummary: String? { undoStack.last?.record.summary }

    /// Title for the Redo menu item.
    public var redoSummary: String? { redoStack.last?.record.summary }

    /// Identifies the current state, for dirty tracking.
    ///
    /// Equal versions mean the same point in history: undoing back to a
    /// version yields that version again, while any new edit — even after an
    /// undo to the same depth — yields a version never seen before. A plain
    /// undo depth cannot tell those two apart.
    public var stateVersion: Int { undoStack.last?.version ?? baseVersion }

    /// The audit log, oldest first.
    public var history: [CommandRecord] { undoStack.map(\.record) }

    // MARK: - Mutating

    /// Applies a command, recording it for undo.
    ///
    /// - Throws: Whatever the command throws. On any error the stack is
    ///   unchanged.
    public mutating func apply(
        _ command: some Command<State>,
        origin: CommandOrigin = .user
    ) throws {
        // Compute the inverse against the *pre* state, before anything changes,
        // so a destructive command can capture what it is about to discard.
        let inverse = try command.inverse(for: state)
        let newState = try command.apply(to: state)

        // Past this point nothing can fail, so the mutation is atomic.
        state = newState
        undoStack.append(
            Entry(
                command: command,
                inverse: inverse,
                record: CommandRecord(
                    summary: command.summary,
                    isDestructive: command.isDestructive,
                    origin: origin
                ),
                version: nextVersion
            )
        )
        nextVersion += 1
        // Branching: a new command after an undo discards the old redo branch,
        // matching standard editor semantics.
        redoStack.removeAll()
        trimHistory()
    }

    /// Reverses the most recent command.
    public mutating func undo() throws {
        guard let entry = undoStack.last else { throw CommandError.nothingToUndo }

        let restored = try entry.inverse.apply(to: state)

        state = restored
        undoStack.removeLast()
        redoStack.append(entry)
    }

    /// Reapplies the most recently undone command.
    public mutating func redo() throws {
        guard let entry = redoStack.last else { throw CommandError.nothingToRedo }

        // Recompute the inverse against the current state rather than reusing
        // the stale one: the state we are redoing onto is not necessarily the
        // state the original inverse was built for.
        let inverse = try entry.command.inverse(for: state)
        let newState = try entry.command.apply(to: state)

        state = newState
        redoStack.removeLast()
        undoStack.append(
            Entry(
                command: entry.command, inverse: inverse,
                record: entry.record, version: entry.version
            )
        )
        trimHistory()
    }

    // MARK: - Private

    /// Drops the oldest entries once the cap is exceeded.
    private mutating func trimHistory() {
        guard undoStack.count > historyLimit else { return }
        let excess = undoStack.count - historyLimit
        // The trimmed entries' result is now the floor undo can reach.
        baseVersion = undoStack[excess - 1].version
        undoStack.removeFirst(excess)
    }
}
