import Testing
import PDFKit
@testable import PDFCore
@testable import DocumentModel

@Suite("Insert, duplicate and markup commands")
struct InsertAndMarkupTests {

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for index in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            let label = NSAttributedString(string: "P-\(index)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 15, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw PDFCoreError.documentLoadFailed }
        return document
    }

    private func labels(_ stack: CommandStack<DocumentState>) -> [String] {
        (0..<stack.state.document.pageCount).map {
            stack.state.document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    @Test func blankPageMatchesNeighbourSizeAndUndoes() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))
        try stack.apply(InsertBlankPageCommand(at: 1))
        #expect(labels(stack) == ["P-0", "", "P-1"])
        #expect(stack.state.document.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 400))
        try stack.undo()
        #expect(labels(stack) == ["P-0", "P-1"])
        try stack.redo()
        #expect(stack.state.document.pageCount == 3)
    }

    @Test func blankPageRejectsBadIndex() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        #expect(throws: PDFCoreError.self) { try stack.apply(InsertBlankPageCommand(at: 5)) }
        #expect(stack.state.document.pageCount == 1)
    }

    @Test func duplicateInsertsCopiesAfterSelection() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 4)))
        try stack.apply(DuplicatePagesCommand(pageIndices: [2, 0]))
        #expect(labels(stack) == ["P-0", "P-1", "P-2", "P-0", "P-2", "P-3"])
        try stack.undo()
        #expect(labels(stack) == ["P-0", "P-1", "P-2", "P-3"])
    }

    @Test func markupAddsTaggedAnnotationsAndUndoRemovesOnlyThem() throws {
        let document = try makeDocument(pageCount: 2)
        let existing = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 5, height: 5), forType: .text, withProperties: nil)
        document.page(at: 0)?.addAnnotation(existing)
        let before = document.page(at: 0)?.annotations.count ?? 0
        var stack = CommandStack(initial: DocumentState(document: document))

        let lines = [MarkupLine(pageIndex: 0, bounds: CGRect(x: 10, y: 90, width: 60, height: 20)),
                     MarkupLine(pageIndex: 1, bounds: CGRect(x: 10, y: 90, width: 60, height: 20))]
        try stack.apply(AddMarkupCommand(style: .highlight, lines: lines))
        #expect(document.page(at: 0)?.annotations.count == before + 1)
        #expect(document.page(at: 1)?.annotations.first?.type == "Highlight")

        try stack.undo()
        #expect(document.page(at: 0)?.annotations.count == before)
        #expect(document.page(at: 0)?.annotations.contains { $0 === existing } == true)
        #expect(document.page(at: 1)?.annotations.isEmpty == true)

        try stack.redo()
        #expect(document.page(at: 1)?.annotations.count == 1)
    }

    @Test func markupNeedsASelection() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        #expect(throws: CommandError.self) { try stack.apply(AddMarkupCommand(style: .underline, lines: [])) }
    }
}
