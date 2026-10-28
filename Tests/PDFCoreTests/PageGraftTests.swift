import Testing
import PDFKit
@testable import PDFCore

/// The page-ownership trap.
///
/// `PDFDocument.h` warns, verbatim, above `insertPage:atIndex:`:
///
/// > when inserting a PDFPage, you have to be careful if that page came from
/// > another PDFDocument. PDFPage's have a notion of a single document that owns
/// > them [...] You'll want to call -[PDFPage copy] first.
///
/// ## What was actually measured on macOS 27.2
///
/// The header implies the source document loses the page. **It does not**, as of
/// macOS 27.2 / PDFKit in the 27.0 SDK: `pageCount` is unchanged and both
/// documents save correctly to disk. The hazard is subtler and is about
/// *aliasing* rather than loss:
///
/// - After a naive cross-document `insert`, the same `PDFPage` **instance** is
///   reachable from both documents, and `page.document` points at the
///   destination.
/// - Mutating that page (e.g. `rotation`) therefore changes **both** documents.
///   This was measured: rotating the donated page to 90° left the source's
///   page 0 also reporting 90°.
/// - With `copy()` first, the source stays at 0° and only the destination
///   rotates — the documents are independent.
///
/// So `PageGraft` is justified, but for the aliasing reason, not the
/// page-count reason. These tests assert the measured behaviour; if a future OS
/// starts removing the page from the source, `naiveInsertAliasesPages` will
/// fail and the discrepancy gets re-examined rather than silently absorbed.
@Suite("PageGraft")
struct PageGraftTests {

    /// Builds an in-memory PDF whose pages carry extractable identifying text,
    /// so a page can be told apart from its neighbours after a move.
    ///
    /// Note: `CGPDFContext` emits a blank page if asked for zero pages, so the
    /// minimum meaningful `pageCount` here is 1.
    private func makeDocument(pageCount: Int, tag: String) throws -> PDFDocument {
        precondition(pageCount >= 1, "CGPDFContext always emits at least one page")

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

    /// Extracted page text, trimmed — the identity of each page.
    private func pageLabels(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
        }
    }

    // MARK: - The hazard

    @Test("naive cross-document insert aliases one page into two documents")
    func naiveInsertAliasesPages() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        let donated = try #require(source.page(at: 0))
        destination.insert(donated, at: destination.pageCount)

        // Measured: the source keeps its page count, contrary to the header's implication.
        #expect(source.pageCount == 2, "source unexpectedly lost a page — see PageGraft's ownership notes")
        // But ownership has moved, which is what makes the two documents alias.
        #expect(donated.document === destination)

        // The consequence: mutating the page mutates BOTH documents.
        donated.rotation = 90
        #expect(try #require(destination.page(at: 1)).rotation == 90)
        #expect(
            try #require(source.page(at: 0)).rotation == 90,
            "aliasing did not reproduce; PageGraft's justification needs revisiting"
        )
    }

    // MARK: - The fix

    @Test("graft isolates the two documents from each other")
    func graftIsolatesDocuments() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        try PageGraft.graft(pageAt: 0, from: source, into: destination, at: destination.pageCount)

        let grafted = try #require(destination.page(at: 1))
        grafted.rotation = 90

        // This is the whole point of the type.
        #expect(try #require(source.page(at: 0)).rotation == 0, "mutation leaked into the source")
        #expect(grafted.rotation == 90)
    }

    @Test("graft leaves the source intact and the destination correct")
    func graftPreservesBothDocuments() throws {
        let source = try makeDocument(pageCount: 3, tag: "SRC")
        let destination = try makeDocument(pageCount: 2, tag: "DST")

        try PageGraft.graft(pageAt: 1, from: source, into: destination, at: destination.pageCount)

        #expect(pageLabels(source) == ["SRC-0", "SRC-1", "SRC-2"])
        #expect(pageLabels(destination) == ["DST-0", "DST-1", "SRC-1"])
    }

    @Test("grafted page is not owned by the source")
    func graftedPageIsIndependent() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        try PageGraft.graft(pageAt: 1, from: source, into: destination, at: 1)

        #expect(try #require(destination.page(at: 1)).document !== source)
    }

    @Test("graftAll preserves order rather than reversing it")
    func graftAllPreservesOrder() throws {
        let source = try makeDocument(pageCount: 3, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        try PageGraft.graftAll(from: source, into: destination, at: destination.pageCount)

        #expect(pageLabels(source) == ["SRC-0", "SRC-1", "SRC-2"])
        // Order preserved — a loop inserting repeatedly at one index would reverse.
        #expect(pageLabels(destination) == ["DST-0", "SRC-0", "SRC-1", "SRC-2"])
    }

    @Test("graftAll can insert at the front")
    func graftAllAtFront() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 2, tag: "DST")

        try PageGraft.graftAll(from: source, into: destination, at: 0)

        #expect(pageLabels(destination) == ["SRC-0", "SRC-1", "DST-0", "DST-1"])
    }

    @Test("grafted document survives a save/reload round trip")
    func graftSurvivesRoundTrip() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")
        try PageGraft.graftAll(from: source, into: destination, at: destination.pageCount)

        // Save/reload must be semantically identical.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-roundtrip-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(destination.write(to: url))
        let reloaded = try #require(PDFDocument(url: url))
        #expect(pageLabels(reloaded) == ["DST-0", "SRC-0", "SRC-1"])
    }

    // MARK: - Reordering within one document

    @Test("move reorders without scrambling the pages in between")
    func moveReorders() throws {
        let document = try makeDocument(pageCount: 4, tag: "P")

        // Move the first page to the end. A naive `exchange` would swap P-0 and
        // P-3 and leave the middle wrong.
        try PageGraft.move(pageAt: 0, to: 3, in: document)

        #expect(pageLabels(document) == ["P-1", "P-2", "P-3", "P-0"])
    }

    @Test("move backwards reorders correctly")
    func moveBackwards() throws {
        let document = try makeDocument(pageCount: 4, tag: "P")

        try PageGraft.move(pageAt: 3, to: 0, in: document)

        #expect(pageLabels(document) == ["P-3", "P-0", "P-1", "P-2"])
    }

    @Test("move to the same index is a no-op")
    func moveToSameIndexIsNoOp() throws {
        let document = try makeDocument(pageCount: 3, tag: "P")

        try PageGraft.move(pageAt: 1, to: 1, in: document)

        #expect(pageLabels(document) == ["P-0", "P-1", "P-2"])
    }

    // MARK: - Error handling (never crash)

    @Test("out-of-range source index throws rather than trapping")
    func outOfRangeSourceThrows() throws {
        let source = try makeDocument(pageCount: 1, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        #expect(throws: PDFCoreError.pageIndexOutOfRange(index: 5, pageCount: 1)) {
            try PageGraft.graft(pageAt: 5, from: source, into: destination, at: 0)
        }
    }

    @Test("negative source index throws rather than trapping")
    func negativeSourceIndexThrows() throws {
        let source = try makeDocument(pageCount: 1, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        #expect(throws: PDFCoreError.self) {
            try PageGraft.graft(pageAt: -1, from: source, into: destination, at: 0)
        }
    }

    @Test("out-of-range destination index throws rather than trapping")
    func outOfRangeDestinationThrows() throws {
        let source = try makeDocument(pageCount: 1, tag: "SRC")
        let destination = try makeDocument(pageCount: 1, tag: "DST")

        #expect(throws: PDFCoreError.self) {
            try PageGraft.graft(pageAt: 0, from: source, into: destination, at: 99)
        }
    }

    @Test("appending at exactly pageCount is allowed")
    func appendAtPageCountIsValid() throws {
        let source = try makeDocument(pageCount: 1, tag: "SRC")
        let destination = try makeDocument(pageCount: 2, tag: "DST")

        // `pageCount` is a legal insertion point; `pageCount + 1` is not.
        try PageGraft.graft(pageAt: 0, from: source, into: destination, at: 2)

        #expect(destination.pageCount == 3)
    }

    @Test("a failed graft leaves the destination unmodified")
    func failedGraftLeavesDestinationUntouched() throws {
        let source = try makeDocument(pageCount: 2, tag: "SRC")
        let destination = try makeDocument(pageCount: 2, tag: "DST")

        // Invalid destination index: nothing should be inserted.
        #expect(throws: PDFCoreError.self) {
            try PageGraft.graftAll(from: source, into: destination, at: 99)
        }
        #expect(pageLabels(destination) == ["DST-0", "DST-1"], "partial mutation left behind")
    }

    @Test("error messages are 1-based and actionable")
    func errorMessageIsActionable() {
        let error = PDFCoreError.pageIndexOutOfRange(index: 5, pageCount: 3)

        // MCP errors must be actionable, and they originate here.
        #expect(error.errorDescription == "Page 6 is outside the document's range of 1–3.")
    }
}
