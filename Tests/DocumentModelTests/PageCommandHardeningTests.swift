import Testing
import PDFKit
@testable import PDFCore
@testable import DocumentModel

/// Input that must be refused rather than half-applied: bad angles and empty
/// merges both used to leave the document or the undo stack in a bad state.
@Suite("PageCommand hardening")
struct PageCommandHardeningTests {

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        for _ in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        return document
    }

    @Test("rotation by a non-multiple of 90 is refused and changes nothing",
          arguments: [45, 1, -91, 3690, Int.max, Int.min])
    func invalidRotationRefused(degrees: Int) throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))

        #expect(throws: RotationError.invalidDegrees(degrees)) {
            try stack.apply(RotatePagesCommand(pageIndices: [0], degrees: degrees))
        }
        #expect(stack.state.document.page(at: 0)?.rotation == 0)
        #expect(!stack.canUndo)
    }

    @Test("the validating initialiser throws at construction")
    func validatingInit() {
        #expect(throws: RotationError.invalidDegrees(30)) {
            _ = try RotatePagesCommand(validatingPageIndices: [0], degrees: 30)
        }
        #expect(throws: Never.self) {
            _ = try RotatePagesCommand(validatingPageIndices: [0], degrees: -3600)
        }
    }

    @Test("the rotation error tells the caller what is allowed")
    func rotationMessage() {
        let message = RotationError.invalidDegrees(45).errorDescription ?? ""
        #expect(message.contains("45"))
        #expect(message.contains("multiple of 90"))
    }

    @Test("normalize is total over Int")
    func normalizeIsSafe() {
        #expect(RotatePagesCommand.normalize(Int.min) >= 0)
        #expect(RotatePagesCommand.normalize(Int.max) < 360)
        #expect(RotatePagesCommand.normalize(-90) == 270)
    }

    @Test("merging an empty document is refused, so undo is never jammed")
    func emptyMergeRefused() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))

        #expect(throws: CommandError.self) {
            try stack.apply(MergeDocumentCommand(incoming: PDFDocument(), at: 1))
        }
        #expect(!stack.canUndo, "a refused merge must not leave an undo entry")
        #expect(stack.state.document.pageCount == 2)
    }
}
