import Testing
import PDFKit
@testable import PDFCore
@testable import DocumentModel

@Suite("Annotation commands")
struct AnnotationCommandTests {

    private func makeStack(pages: Int = 2) -> CommandStack<DocumentState> {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            document.insert(page, at: index)
        }
        return CommandStack(initial: DocumentState(document: document))
    }

    private func box() -> PDFAnnotation {
        PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .square, withProperties: nil)
    }

    @Test func addThenUndoRemovesTheSameAnnotation() throws {
        var stack = makeStack()
        let annotation = box()
        try stack.apply(AddAnnotationCommand(pageIndex: 1, annotation: annotation, summary: "Rectangle"))
        #expect(stack.state.document.page(at: 1)?.annotations.first === annotation)
        #expect(stack.undoSummary == "Rectangle")
        try stack.undo()
        #expect(stack.state.document.page(at: 1)?.annotations.isEmpty == true)
        try stack.redo()
        #expect(stack.state.document.page(at: 1)?.annotations.count == 1)
    }

    @Test func removeIsUndoable() throws {
        var stack = makeStack()
        let annotation = box()
        stack.state.document.page(at: 0)?.addAnnotation(annotation)
        try stack.apply(RemoveAnnotationCommand(pageIndex: 0, annotation: annotation))
        #expect(stack.state.document.page(at: 0)?.annotations.isEmpty == true)
        try stack.undo()
        #expect(stack.state.document.page(at: 0)?.annotations.first === annotation)
    }

    @Test func removingAMissingAnnotationFails() {
        var stack = makeStack()
        #expect(throws: CommandError.self) {
            try stack.apply(RemoveAnnotationCommand(pageIndex: 0, annotation: box()))
        }
    }

    @Test func updateMovesAndRestylesWithExactUndo() throws {
        var stack = makeStack()
        let annotation = box()
        stack.state.document.page(at: 0)?.addAnnotation(annotation)
        let before = AnnotationAppearance(of: annotation)
        var after = before
        after.bounds = before.bounds.offsetBy(dx: 40, dy: 25)
        after.color = .systemRed
        after.lineWidth = 4
        try stack.apply(UpdateAnnotationCommand(pageIndex: 0, annotation: annotation, from: before, to: after, summary: "Move"))
        #expect(annotation.bounds.origin == CGPoint(x: 50, y: 35))
        #expect(annotation.border?.lineWidth == 4)
        try stack.undo()
        #expect(annotation.bounds == before.bounds)
        try stack.redo()
        #expect(annotation.bounds.origin == CGPoint(x: 50, y: 35))
    }

    @Test func editedTextCoverIsTaggedAndOpaque() {
        let cover = TextEdit.coverAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 14), text: "Globex",
            font: .systemFont(ofSize: 11), textColor: .black, background: .white
        )
        #expect(cover.type == "FreeText")
        #expect(cover.contents == "Globex")
        #expect(cover.userName == TextEdit.marker)
        #expect(cover.border?.lineWidth == 0)
    }

    @Test func badPageIndexThrows() {
        var stack = makeStack(pages: 1)
        #expect(throws: PDFCoreError.self) {
            try stack.apply(AddAnnotationCommand(pageIndex: 3, annotation: box(), summary: "x"))
        }
    }
}
