import Testing
import PDFKit
import Foundation
@testable import PDFCore
@testable import DocumentModel

/// Dirty tracking and atomic saving — the two things a user relies on when
/// deciding whether it is safe to close a window.
@Suite("DocumentSession")
@MainActor
struct DocumentSessionTests {

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for index in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            let label = NSAttributedString(string: "S-\(index)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 15, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        return document
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Dirty tracking

    @Test("a new session is clean")
    func startsClean() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 2))
        #expect(!session.hasUnsavedChanges)
    }

    @Test("undoing back to the saved state reports clean; redo reports dirty")
    func undoToSavedPointIsClean() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 2))

        try session.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        #expect(session.hasUnsavedChanges)

        try session.undo()
        #expect(!session.hasUnsavedChanges, "undo back to the opened state must be clean")

        try session.redo()
        #expect(session.hasUnsavedChanges)
    }

    @Test("after saving, undo makes the session dirty and redo makes it clean")
    func savedPointMovesWithSave() throws {
        let directory = try temporaryDirectory()
        let session = DocumentSession(document: try makeDocument(pageCount: 3))

        try session.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        try session.save(to: directory.appendingPathComponent("a.pdf"))
        #expect(!session.hasUnsavedChanges)

        try session.undo()
        #expect(session.hasUnsavedChanges, "the file on disk has the rotation; memory does not")
        try session.redo()
        #expect(!session.hasUnsavedChanges)
    }

    @Test("a new edit after undo is dirty even at the saved depth")
    func branchingEditIsDirty() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 3))

        try session.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        try session.undo()
        try session.apply(RotatePagesCommand(pageIndices: [1], degrees: 90))
        try session.undo()
        #expect(!session.hasUnsavedChanges)

        let saved = try temporaryDirectory().appendingPathComponent("b.pdf")
        try session.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        try session.save(to: saved)
        try session.undo()
        // Same undo depth as the save, but a different document.
        try session.apply(DeletePagesCommand(pageIndices: [2]))
        #expect(session.hasUnsavedChanges)
    }

    @Test("replacing the document wholesale is unsaved until written")
    func replacementIsDirty() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 1))
        session.replaceDocument(with: try makeDocument(pageCount: 2))
        #expect(session.hasUnsavedChanges)
    }

    // MARK: - Saving

    @Test("save writes over the file the session was opened from")
    func saveInPlace() throws {
        let url = try temporaryDirectory().appendingPathComponent("doc.pdf")
        #expect(try makeDocument(pageCount: 3).write(to: url))

        let session = try DocumentSession(contentsOf: url)
        try session.apply(DeletePagesCommand(pageIndices: [1]))
        try session.save()

        let reloaded = try #require(PDFDocument(url: url))
        #expect(reloaded.pageCount == 2)
        #expect(!session.hasUnsavedChanges)

        // No staging files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["doc.pdf"])
    }

    @Test("save without a location is an actionable error, not a load failure")
    func saveWithoutURL() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 1))
        #expect(throws: SessionError.noFileLocation) { try session.save() }
    }

    @Test("a failed write reports writeFailed and keeps the session dirty")
    func failedWrite() throws {
        let session = DocumentSession(document: try makeDocument(pageCount: 1))
        try session.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.pdf")

        #expect(throws: PDFCoreError.writeFailed(path: missing.path)) {
            try session.save(to: missing)
        }
        #expect(session.hasUnsavedChanges)
        #expect(session.url == nil)
    }
}

@Suite("CommandStack versions")
struct CommandStackVersionTests {

    struct Append: Command {
        let value: Int
        var summary: String { "Append" }
        var isDestructive: Bool { false }
        func apply(to state: [Int]) throws -> [Int] { state + [value] }
        func inverse(for state: [Int]) throws -> any Command<[Int]> { Drop() }
    }

    struct Drop: Command {
        var summary: String { "Drop" }
        var isDestructive: Bool { false }
        func apply(to state: [Int]) throws -> [Int] { Array(state.dropLast()) }
        func inverse(for state: [Int]) throws -> any Command<[Int]> { Append(value: state.last ?? 0) }
    }

    @Test("undo and redo return to the same version; new edits get new ones")
    func versionsTrackHistory() throws {
        var stack = CommandStack(initial: [Int]())
        let initial = stack.stateVersion

        try stack.apply(Append(value: 1))
        let afterFirst = stack.stateVersion
        #expect(afterFirst != initial)

        try stack.undo()
        #expect(stack.stateVersion == initial)
        try stack.redo()
        #expect(stack.stateVersion == afterFirst)

        try stack.undo()
        try stack.apply(Append(value: 2))
        #expect(stack.stateVersion != afterFirst)
        #expect(stack.stateVersion != initial)
    }

    @Test("trimming history never makes the floor look like the initial state")
    func trimmingMovesTheFloor() throws {
        var stack = CommandStack(initial: [Int](), historyLimit: 2)
        let initial = stack.stateVersion
        for value in 1...3 { try stack.apply(Append(value: value)) }
        try stack.undo()
        try stack.undo()
        #expect(!stack.canUndo)
        #expect(stack.state == [1])
        #expect(stack.stateVersion != initial)
    }
}
