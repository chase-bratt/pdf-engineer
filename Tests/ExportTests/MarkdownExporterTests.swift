import Testing
import PDFKit
import Foundation
@testable import Export

/// Markdown is *derived* from the AST, never the source of
/// truth. These tests cover the structure inference from the text layer, which is
/// where export quality actually comes from, since tagged PDFs are rare.
@Suite("MarkdownExporter")
struct MarkdownExporterTests {

    private func makePDF(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw ExportTestError.contextFailed }

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for text in pages {
            context.beginPage(mediaBox: &box)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
                )
            )
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw ExportTestError.loadFailed
        }
        return document
    }

    enum ExportTestError: Error { case contextFailed, loadFailed }

    // MARK: - Heading inference

    @Test("a numbered section is a heading at its numbering depth")
    func numberedHeadingDepth() {
        #expect(MarkdownExporter.looksLikeHeading("1. Introduction"))
        #expect(MarkdownExporter.headingLevel("1. Introduction") == 1)
        #expect(MarkdownExporter.headingLevel("3.2 Methodology") == 2)
        #expect(MarkdownExporter.headingLevel("1.2.3 Details") == 3)
    }

    @Test("an ALL CAPS short line is a heading")
    func capsHeading() {
        #expect(MarkdownExporter.looksLikeHeading("APPENDIX A"))
    }

    @Test("a sentence is not a heading")
    func sentenceIsNotHeading() {
        // Terminal punctuation is the strongest available signal that a line is
        // prose rather than a heading.
        #expect(!MarkdownExporter.looksLikeHeading("This is a sentence."))
        #expect(!MarkdownExporter.looksLikeHeading("A question?"))
    }

    @Test("a long line is not a heading even without punctuation")
    func longLineIsNotHeading() {
        let long = String(repeating: "word ", count: 30)
        #expect(!MarkdownExporter.looksLikeHeading(long))
    }

    @Test("a bare year is not a heading")
    func bareYearIsNotHeading() {
        // "1984" would otherwise parse as a numbered prefix. The requirement
        // that a space follow the number is what prevents it.
        #expect(!MarkdownExporter.looksLikeHeading("1984"))
    }

    @Test("heading depth is capped at 6")
    func headingDepthCapped() {
        // Markdown has no h7.
        #expect(MarkdownExporter.headingLevel("1.2.3.4.5.6.7.8 Deep") == 6)
    }

    // MARK: - Paragraph assembly

    @Test("wrapped lines are joined into one paragraph")
    func wrappedLinesJoin() {
        // PDFKit breaks text at visual line ends; leaving those breaks would
        // turn every wrapped line into its own Markdown line.
        let result = MarkdownExporter.paragraphs(in: "first line\nsecond line\n\nnext para")
        #expect(result == ["first line second line", "next para"])
    }

    @Test("blank lines separate paragraphs")
    func blankLinesSeparate() {
        #expect(MarkdownExporter.paragraphs(in: "a\n\nb\n\nc").count == 3)
    }

    @Test("empty and whitespace-only input yields no paragraphs")
    func emptyInput() {
        #expect(MarkdownExporter.paragraphs(in: "").isEmpty)
        #expect(MarkdownExporter.paragraphs(in: "   \n\n  \n").isEmpty)
    }

    @Test("CRLF line endings are handled")
    func crlfHandled() {
        #expect(MarkdownExporter.paragraphs(in: "a\r\n\r\nb") == ["a", "b"])
    }

    // MARK: - AST construction

    @Test("every block gets a unique id")
    func blocksHaveUniqueIDs() throws {
        let ast = MarkdownExporter.buildAST(
            from: try makePDF(pages: ["1. One", "2. Two", "3. Three"]),
            filename: "test"
        )
        // Unique ids are the precondition for markdown anchors and the
        // annotation round-trip.
        #expect(ast.hasUniqueBlockIDs)
        #expect(!ast.blocks.isEmpty)
    }

    @Test("blocks record 1-based page numbers")
    func blocksRecordPages() throws {
        let ast = MarkdownExporter.buildAST(
            from: try makePDF(pages: ["Page one text", "Page two text"]),
            filename: "test"
        )
        let pages = Set(ast.blocks.map(\.page))
        #expect(pages == [1, 2], "pages must be 1-based and cover both pages")
    }

    @Test("text-layer blocks are marked as such, not as OCR")
    func provenanceIsTextLayer() throws {
        let ast = MarkdownExporter.buildAST(
            from: try makePDF(pages: ["Some text"]), filename: "test"
        )
        // Conflating extracted text with OCR guesses is how silent
        // corruption enters a pipeline.
        #expect(ast.blocks.allSatisfy { $0.provenance == .textLayer })
    }

    @Test("reading order is sequential and gapless")
    func readingOrderSequential() throws {
        let ast = MarkdownExporter.buildAST(
            from: try makePDF(pages: ["1. A", "2. B", "3. C"]), filename: "test"
        )
        #expect(ast.blocks.map(\.readingOrder) == Array(0..<ast.blocks.count))
    }

    // MARK: - Markdown rendering

    @Test("frontmatter carries the source and page count")
    func frontmatterPresent() throws {
        let markdown = MarkdownExporter.markdown(
            from: try makePDF(pages: ["Hello"]), filename: "report"
        )
        #expect(markdown.hasPrefix("---\n"))
        #expect(markdown.contains("source: \"report\""))
        #expect(markdown.contains("pages: 1"))
        #expect(markdown.contains("schema: docast/1.0"))
    }

    @Test("page markers are emitted so citations survive export")
    func pageMarkersEmitted() throws {
        let markdown = MarkdownExporter.markdown(
            from: try makePDF(pages: ["First", "Second"]), filename: "t"
        )
        // Without these, a flat Markdown dump loses the ability to cite a page.
        #expect(markdown.contains("<!-- page 1 -->"))
        #expect(markdown.contains("<!-- page 2 -->"))
    }

    @Test("headings render with the right number of hashes")
    func headingsRender() throws {
        let markdown = MarkdownExporter.markdown(
            from: try makePDF(pages: ["1. Introduction"]), filename: "t"
        )
        #expect(markdown.contains("# 1. Introduction"))
    }

    @Test("a quote in the filename does not break the YAML")
    func filenameQuotingIsSafe() throws {
        let markdown = MarkdownExporter.markdown(
            from: try makePDF(pages: ["x"]), filename: "re\"port"
        )
        // An unescaped quote would produce invalid YAML frontmatter.
        #expect(markdown.contains(#"source: "re\"port""#))
    }

    @Test("an empty document still produces valid frontmatter")
    func emptyDocumentExports() {
        let ast = MarkdownExporter.buildAST(from: PDFDocument(), filename: "empty")
        let markdown = MarkdownExporter.markdown(from: ast)
        #expect(markdown.contains("pages: 0"))
        #expect(markdown.hasPrefix("---"))
    }
}
