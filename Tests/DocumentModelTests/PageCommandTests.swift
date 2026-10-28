import Testing
import PDFKit
@testable import PDFCore
@testable import DocumentModel

/// Page organization, the app's core workflow, expressed as
/// ``Command``s so every operation is undoable and MCP-reachable.
@Suite("PageCommands")
struct PageCommandTests {

    private func makeDocument(pageCount: Int, tag: String = "P") throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }

        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for index in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            let label = NSAttributedString(
                string: "\(tag)-\(index)",
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
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

    private func labels(_ state: DocumentState) -> [String] {
        (0..<state.document.pageCount).map {
            state.document.page(at: $0)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
        }
    }

    // MARK: - Rotate

    @Test("rotate turns the named pages and leaves the rest alone")
    func rotateTurnsPages() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 3)))

        try stack.apply(RotatePagesCommand(pageIndices: [0, 2], degrees: 90))

        #expect(stack.state.document.page(at: 0)?.rotation == 90)
        #expect(stack.state.document.page(at: 1)?.rotation == 0)
        #expect(stack.state.document.page(at: 2)?.rotation == 90)
    }

    @Test("rotate is undoable back to the original angles")
    func rotateUndo() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))

        try stack.apply(RotatePagesCommand(pageIndices: [0], degrees: 270))
        #expect(stack.state.document.page(at: 0)?.rotation == 270)

        try stack.undo()
        #expect(stack.state.document.page(at: 0)?.rotation == 0)
    }

    @Test("rotation normalises to 0/90/180/270")
    func rotationNormalises() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))

        // 450° is 90°; negative and over-360 values must not reach PDFKit raw.
        try stack.apply(RotatePagesCommand(pageIndices: [0], degrees: 450))
        #expect(stack.state.document.page(at: 0)?.rotation == 90)

        try stack.apply(RotatePagesCommand(pageIndices: [0], degrees: -90))
        #expect(stack.state.document.page(at: 0)?.rotation == 0)
    }

    @Test("rotate rejects an out-of-range page")
    func rotateRejectsBadIndex() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))

        #expect(throws: PDFCoreError.self) {
            try stack.apply(RotatePagesCommand(pageIndices: [7], degrees: 90))
        }
        #expect(!stack.canUndo, "a rejected command must not be undoable")
    }

    @Test("rotate is not destructive")
    func rotateIsNotDestructive() {
        #expect(!RotatePagesCommand(pageIndices: [0], degrees: 90).isDestructive)
    }

    // MARK: - Delete

    @Test("delete removes the named pages")
    func deleteRemovesPages() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 4)))

        try stack.apply(DeletePagesCommand(pageIndices: [1, 2]))

        #expect(labels(stack.state) == ["P-0", "P-3"])
    }

    @Test("delete restores the exact pages and positions on undo")
    func deleteUndoRestores() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 4)))

        try stack.apply(DeletePagesCommand(pageIndices: [0, 2]))
        #expect(labels(stack.state) == ["P-1", "P-3"])

        try stack.undo()
        // Both content and order must come back exactly.
        #expect(labels(stack.state) == ["P-0", "P-1", "P-2", "P-3"])
    }

    @Test("delete is destructive, so it requires explicit consent")
    func deleteIsDestructive() {
        // Destructive => explicit per-call confirmation.
        #expect(DeletePagesCommand(pageIndices: [0]).isDestructive)
    }

    @Test("deleting every page is refused rather than producing an empty PDF")
    func deleteAllRefused() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))

        // A zero-page PDF is not a valid document.
        #expect(throws: CommandError.self) {
            try stack.apply(DeletePagesCommand(pageIndices: [0, 1]))
        }
        #expect(labels(stack.state) == ["P-0", "P-1"])
    }

    @Test("delete reports the page count in its summary")
    func deleteSummary() {
        #expect(DeletePagesCommand(pageIndices: [0]).summary == "Delete 1 Page")
        #expect(DeletePagesCommand(pageIndices: [0, 1]).summary == "Delete 2 Pages")
    }

    // MARK: - Reorder

    @Test("reorder moves a page and preserves the others")
    func reorderMovesPage() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 4)))

        try stack.apply(MovePageCommand(from: 0, to: 3))

        #expect(labels(stack.state) == ["P-1", "P-2", "P-3", "P-0"])
    }

    @Test("reorder is undoable")
    func reorderUndo() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 4)))

        try stack.apply(MovePageCommand(from: 3, to: 0))
        #expect(labels(stack.state) == ["P-3", "P-0", "P-1", "P-2"])

        try stack.undo()
        #expect(labels(stack.state) == ["P-0", "P-1", "P-2", "P-3"])
    }

    // MARK: - Merge

    @Test("merge appends another document's pages")
    func mergeAppends() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2, tag: "A")))
        let incoming = try makeDocument(pageCount: 2, tag: "B")

        try stack.apply(MergeDocumentCommand(incoming: incoming, at: 2))

        #expect(labels(stack.state) == ["A-0", "A-1", "B-0", "B-1"])
    }

    @Test("merge does not alias the source document")
    func mergeDoesNotAliasSource() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1, tag: "A")))
        let incoming = try makeDocument(pageCount: 1, tag: "B")

        try stack.apply(MergeDocumentCommand(incoming: incoming, at: 1))

        // Rotating the merged page must not touch the source.
        stack.state.document.page(at: 1)?.rotation = 90
        #expect(incoming.page(at: 0)?.rotation == 0, "merge aliased the source document")
    }

    @Test("merge is undoable")
    func mergeUndo() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1, tag: "A")))
        let incoming = try makeDocument(pageCount: 2, tag: "B")

        try stack.apply(MergeDocumentCommand(incoming: incoming, at: 1))
        #expect(labels(stack.state) == ["A-0", "B-0", "B-1"])

        try stack.undo()
        #expect(labels(stack.state) == ["A-0"])
    }

    // MARK: - Integration

    @Test("a sequence of operations undoes in reverse order")
    func sequenceUndoesInReverse() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 3)))

        try stack.apply(RotatePagesCommand(pageIndices: [0], degrees: 90))
        try stack.apply(DeletePagesCommand(pageIndices: [2]))
        try stack.apply(MovePageCommand(from: 0, to: 1))
        #expect(labels(stack.state) == ["P-1", "P-0"])

        try stack.undo()
        #expect(labels(stack.state) == ["P-0", "P-1"])
        try stack.undo()
        #expect(labels(stack.state) == ["P-0", "P-1", "P-2"])
        try stack.undo()
        #expect(stack.state.document.page(at: 0)?.rotation == 0)
        #expect(!stack.canUndo)
    }

    @Test("assistant-originated page edits are labelled in history")
    func assistantEditsAreLabelled() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 3)))

        try stack.apply(DeletePagesCommand(pageIndices: [1]), origin: .assistant)

        let entry = try #require(stack.history.last)
        #expect(entry.origin == .assistant)
        #expect(entry.isDestructive)
    }
}
