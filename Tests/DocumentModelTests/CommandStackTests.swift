import Testing
@testable import DocumentModel

/// Every mutation is a `Command` with an inverse, so undo works
/// identically whether a human clicked or Claude called an MCP tool.
///
/// A fake command over a trivial state keeps these tests about the *stack's*
/// semantics rather than PDF behaviour.
@Suite("CommandStack")
struct CommandStackTests {

    /// Appends a string. Its inverse removes the last element.
    struct Append: Command {
        let value: String
        var summary: String { "Append \(value)" }
        var isDestructive: Bool { false }

        func apply(to state: [String]) throws -> [String] { state + [value] }
        func inverse(for state: [String]) throws -> any Command<[String]> { RemoveLast() }
    }

    struct RemoveLast: Command {
        var summary: String { "Remove last" }
        var isDestructive: Bool { true }

        func apply(to state: [String]) throws -> [String] {
            guard !state.isEmpty else { throw CommandError.preconditionFailed("empty") }
            return state.dropLast()
        }
        func inverse(for state: [String]) throws -> any Command<[String]> {
            guard let last = state.last else { throw CommandError.preconditionFailed("empty") }
            return Append(value: last)
        }
    }

    /// Always throws — used to prove a failed command does not corrupt the stack.
    struct Failing: Command {
        var summary: String { "Fail" }
        var isDestructive: Bool { false }
        func apply(to state: [String]) throws -> [String] {
            throw CommandError.preconditionFailed("intentional")
        }
        func inverse(for state: [String]) throws -> any Command<[String]> { self }
    }

    @Test("a new stack has nothing to undo or redo")
    func emptyStack() {
        let stack = CommandStack<[String]>(initial: [])
        #expect(stack.state.isEmpty)
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.undoSummary == nil)
    }

    @Test("apply advances the state")
    func applyAdvancesState() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"))
        #expect(stack.state == ["a"])
        #expect(stack.canUndo)
    }

    @Test("undo restores the previous state")
    func undoRestores() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"))
        try stack.apply(Append(value: "b"))
        #expect(stack.state == ["a", "b"])

        try stack.undo()
        #expect(stack.state == ["a"])
        try stack.undo()
        #expect(stack.state == [])
        #expect(!stack.canUndo)
    }

    @Test("redo reapplies an undone command")
    func redoReapplies() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"))
        try stack.undo()
        #expect(stack.state == [])

        #expect(stack.canRedo)
        try stack.redo()
        #expect(stack.state == ["a"])
    }

    @Test("a new command after undo clears the redo stack")
    func newCommandClearsRedo() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"))
        try stack.undo()
        #expect(stack.canRedo)

        try stack.apply(Append(value: "b"))
        // Standard undo semantics: branching discards the old redo branch.
        #expect(!stack.canRedo)
        #expect(stack.state == ["b"])
    }

    @Test("undo/redo round trips repeatedly without drift")
    func repeatedRoundTrip() throws {
        var stack = CommandStack<[String]>(initial: ["seed"])
        try stack.apply(Append(value: "x"))

        for _ in 0..<5 {
            try stack.undo()
            #expect(stack.state == ["seed"])
            try stack.redo()
            #expect(stack.state == ["seed", "x"])
        }
    }

    @Test("a failing command leaves the state and stack untouched")
    func failedCommandIsAtomic() throws {
        var stack = CommandStack<[String]>(initial: ["a"])

        #expect(throws: CommandError.self) { try stack.apply(Failing()) }

        // Never lose data silently.
        #expect(stack.state == ["a"])
        #expect(!stack.canUndo, "a failed command must not become undoable")
    }

    @Test("undo with nothing to undo throws rather than trapping")
    func undoEmptyThrows() {
        var stack = CommandStack<[String]>(initial: [])
        #expect(throws: CommandError.nothingToUndo) { try stack.undo() }
    }

    @Test("redo with nothing to redo throws rather than trapping")
    func redoEmptyThrows() {
        var stack = CommandStack<[String]>(initial: [])
        #expect(throws: CommandError.nothingToRedo) { try stack.redo() }
    }

    @Test("summaries drive the undo menu and the consent prompt")
    func summariesAreExposed() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"))

        // One source of truth for the undo menu title and Claude's consent text.
        #expect(stack.undoSummary == "Append a")
        try stack.undo()
        #expect(stack.redoSummary == "Append a")
    }

    @Test("origin is recorded so AI edits are visibly labelled")
    func originIsRecorded() throws {
        var stack = CommandStack<[String]>(initial: [])
        try stack.apply(Append(value: "a"), origin: .assistant)
        try stack.apply(Append(value: "b"), origin: .user)

        // Claude's edits enter the same undo stack,
        // visibly labelled as AI-originated.
        #expect(stack.history.map(\.origin) == [.assistant, .user])
    }

    @Test("history records destructiveness for the audit log")
    func historyRecordsDestructiveness() throws {
        var stack = CommandStack<[String]>(initial: ["a"])
        try stack.apply(RemoveLast(), origin: .assistant)

        let entry = try #require(stack.history.last)
        #expect(entry.isDestructive)
        #expect(entry.summary == "Remove last")
    }

    @Test("history is capped to bound memory on long sessions")
    func historyIsCapped() throws {
        var stack = CommandStack<[String]>(initial: [], historyLimit: 3)
        for i in 0..<10 { try stack.apply(Append(value: "\(i)")) }

        // Oldest entries drop out; the most recent remain undoable.
        #expect(stack.history.count == 3)
        #expect(stack.state.count == 10, "capping history must not alter state")
    }
}
