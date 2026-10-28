import Testing
import PDFKit
import Foundation
@testable import Assistant
@testable import DocumentModel

/// Undo of a replacement must remove that replacement's overlays and nothing
/// else — not the user's notes, not another replacement with the same text.
@Suite("ReplaceTextCommand")
struct ReplaceTextCommandTests {

    private func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        context.beginPage(mediaBox: &box)
        let line = NSAttributedString(string: "alpha beta gamma", attributes: [.font: font])
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func freeTexts(_ state: DocumentState) -> [PDFAnnotation] {
        state.document.page(at: 0)?.annotations.filter { $0.type == "FreeText" } ?? []
    }

    @Test("undo leaves a user's FreeText note with the same contents alone")
    func undoSparesUserNote() throws {
        let document = try makeDocument()
        let note = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 80, height: 20), forType: .freeText, withProperties: nil
        )
        note.contents = "DELTA"
        try #require(document.page(at: 0)).addAnnotation(note)

        var stack = CommandStack(initial: DocumentState(document: document))
        try stack.apply(ReplaceTextCommand(find: "beta", replacement: "DELTA"))
        #expect(freeTexts(stack.state).count == 2)

        try stack.undo()
        let remaining = freeTexts(stack.state)
        #expect(remaining.count == 1)
        #expect(remaining.first === note)
    }

    @Test("undo removes only its own replacement, not an earlier identical one")
    func undoIsPerCommand() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument()))
        try stack.apply(ReplaceTextCommand(find: "alpha", replacement: "X"))
        try stack.apply(ReplaceTextCommand(find: "gamma", replacement: "X"))
        #expect(freeTexts(stack.state).count == 2)

        try stack.undo()
        #expect(freeTexts(stack.state).count == 1)

        // Redo re-creates the overlay with the same tag, so undo still works.
        try stack.redo()
        #expect(freeTexts(stack.state).count == 2)
        try stack.undo()
        try stack.undo()
        #expect(freeTexts(stack.state).isEmpty)
    }

    @Test("each command gets a distinct tag")
    func tagsAreUnique() {
        let first = ReplaceTextCommand(find: "a", replacement: "b")
        let second = ReplaceTextCommand(find: "a", replacement: "b")
        #expect(first.tag != second.tag)
        #expect(first.tag.hasPrefix(ReplaceTextCommand.tagPrefix))
    }
}
