import Testing
import PDFKit
import Foundation
@testable import PDFCore

/// Atomic writing, output naming, extraction, and the pagination edge cases.
@Suite("AtomicPDFWriter and pagination")
struct AtomicWriteAndPaginationTests {

    private func makeDocument(labels: [String], size: CGSize = CGSize(width: 200, height: 200)) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }
        var box = CGRect(origin: .zero, size: size)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for label in labels {
            context.beginPage(mediaBox: &box)
            let line = NSAttributedString(string: label, attributes: [.font: font])
            context.textPosition = CGPoint(x: 15, y: 15)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        return document
    }

    private func pageLabels(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Writing

    @Test("write replaces an existing file and leaves no staging file")
    func writeReplaces() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("out.pdf")
        try AtomicPDFWriter.write(try makeDocument(labels: ["A"]), to: url)
        try AtomicPDFWriter.write(try makeDocument(labels: ["B", "C"]), to: url)

        #expect(PDFDocument(url: url)?.pageCount == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["out.pdf"])
    }

    @Test("writing over the file a document was loaded from is safe")
    func writeOverOwnSource() throws {
        let url = try temporaryDirectory().appendingPathComponent("self.pdf")
        try AtomicPDFWriter.write(try makeDocument(labels: ["A", "B", "C"]), to: url)

        let loaded = try #require(PDFDocument(url: url))
        loaded.removePage(at: 0)
        try AtomicPDFWriter.write(loaded, to: url)

        #expect(pageLabels(try #require(PDFDocument(url: url))) == ["B", "C"])
    }

    @Test("a failed write throws writeFailed with the destination path")
    func writeFailure() throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.pdf")
        #expect(throws: PDFCoreError.writeFailed(path: url.path)) {
            try AtomicPDFWriter.write(try makeDocument(labels: ["A"]), to: url)
        }
    }

    @Test("same-file detection sees through dot segments and symlinks")
    func sameFile() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("a.pdf")
        try AtomicPDFWriter.write(try makeDocument(labels: ["A"]), to: file)
        let link = directory.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let dotted = URL(fileURLWithPath: directory.path + "/./sub/../a.pdf")
        #expect(AtomicPDFWriter.isSameFile(file, dotted))
        #expect(AtomicPDFWriter.isSameFile(file, link))
        #expect(!AtomicPDFWriter.isSameFile(file, directory.appendingPathComponent("b.pdf")))
    }

    @Test("writeNew never overwrites: it picks -extract, then -extract-2")
    func writeNewPicksFreeName() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("report.pdf")

        let first = try AtomicPDFWriter.writeNew(try makeDocument(labels: ["A"]), nextTo: source, suffix: "extract")
        let second = try AtomicPDFWriter.writeNew(try makeDocument(labels: ["B"]), nextTo: source, suffix: "extract")

        #expect(first.lastPathComponent == "report-extract.pdf")
        #expect(second.lastPathComponent == "report-extract-2.pdf")
        #expect(pageLabels(try #require(PDFDocument(url: first))) == ["A"])
    }

    @Test("extract copies the selected pages in order without touching the source")
    func extractPages() throws {
        let source = try makeDocument(labels: ["P1", "P2", "P3", "P4"])
        let extracted = try AtomicPDFWriter.extract(
            pages: try PageRange.parse("2,4", pageCount: 4), from: source
        )
        #expect(pageLabels(extracted) == ["P2", "P4"])
        #expect(source.pageCount == 4)
    }

    // MARK: - Pagination

    @Test("sheet count has no trailing overlap-only sheet")
    func sheetCountIsExact() {
        // 792 + 780: exactly two sheets of content with a 12pt overlap. The old
        // ceil(height / advance) formula said three.
        #expect(PDFPaginator.sheetCount(scaledHeight: 1572, sheetHeight: 792, advance: 780) == 2)
        #expect(PDFPaginator.sheetCount(scaledHeight: 1573, sheetHeight: 792, advance: 780) == 3)
        #expect(PDFPaginator.sheetCount(scaledHeight: 500, sheetHeight: 792, advance: 780) == 1)
    }

    @Test("a page exactly two sheets tall paginates to two sheets")
    func paginateExactFit() throws {
        let tall = try makeDocument(labels: ["x"], size: CGSize(width: 612, height: 1572))
        let data = try #require(PDFPaginator.paginate(tall))
        #expect(PDFDocument(data: data)?.pageCount == 2)
    }

    @Test("a zero-width page does not crash pagination")
    func zeroWidthPage() throws {
        let document = try makeDocument(labels: ["x"])
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 0, height: 5000), for: .mediaBox)

        // Previously: scale = 612 / 0 = inf, and the sheet count trapped.
        #expect(PDFPaginator.paginate(document) != nil)
    }
}
