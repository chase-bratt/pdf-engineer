import Testing
import PDFKit
import CoreGraphics
import Foundation
@testable import OCR

/// The OCR pass re-renders every page into a new file. These tests pin down
/// what must survive that: bookmarks, metadata, crop and rotation.
///
/// Every fixture page already has text, so the pipeline copies each page
/// through without running Vision — the document-level handling is what is
/// under test, and it stays fast and deterministic.
@Suite("OCR preservation")
struct OCRPreservationTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Three text pages with an outline, a title, a crop and a rotation.
    private func makeSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OCRError.contextCreationFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for index in 0..<3 {
            context.beginPage(mediaBox: &box)
            let line = NSAttributedString(string: "PAGE\(index + 1)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 120, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPage()
        }
        context.closePDF()

        // Copied into a fresh document: PDFKit only persists an outline
        // assigned to a document it did not parse (see OCRPipeline.finalize).
        let rendered = try #require(PDFDocument(url: url))
        let document = PDFDocument()
        for index in 0..<rendered.pageCount {
            let copy = try #require(rendered.page(at: index)?.copy() as? PDFPage)
            document.insert(copy, at: index)
        }
        let root = PDFOutline()
        for (position, pageIndex) in [0, 2].enumerated() {
            let item = PDFOutline()
            item.label = "Chapter \(position + 1)"
            item.destination = PDFDestination(
                page: try #require(document.page(at: pageIndex)), at: CGPoint(x: 0, y: 600)
            )
            root.insertChild(item, at: position)
        }
        document.outlineRoot = root
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Field Notes"]
        try #require(document.page(at: 1)).setBounds(CGRect(x: 100, y: 200, width: 200, height: 300), for: .cropBox)
        try #require(document.page(at: 2)).rotation = 90

        let saved = directory.appendingPathComponent("source-final.pdf")
        #expect(document.write(to: saved))
        // Guard the fixture itself, so a failure below is about OCR.
        #expect(PDFDocument(url: saved)?.outlineRoot?.numberOfChildren == 2)
        return saved
    }

    @Test("bookmarks and metadata survive, retargeted to the new pages")
    func outlineAndAttributesPreserved() async throws {
        let directory = try temporaryDirectory()
        let source = try makeSource(in: directory)
        let output = directory.appendingPathComponent("out.pdf")

        let result = try await OCRPipeline.addTextLayer(from: source, to: output)
        #expect(result.pagesSkipped == 3)

        let document = try #require(PDFDocument(url: output))
        let root = try #require(document.outlineRoot, "the outline was dropped")
        #expect(root.numberOfChildren == 2)

        let second = try #require(root.child(at: 1))
        #expect(second.label == "Chapter 2")
        let page = try #require(second.destination?.page)
        #expect(document.index(for: page) == 2, "bookmark must point at the third page")

        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        #expect(title == "Field Notes")
    }

    @Test("cropped pages stay cropped and rotated pages keep their orientation")
    func cropAndRotationPreserved() async throws {
        let directory = try temporaryDirectory()
        let source = try makeSource(in: directory)
        let output = directory.appendingPathComponent("out.pdf")

        _ = try await OCRPipeline.addTextLayer(from: source, to: output)
        let document = try #require(PDFDocument(url: output))

        let cropped = try #require(document.page(at: 1))
        #expect(cropped.bounds(for: .mediaBox).size == CGSize(width: 200, height: 300))

        // Rotation is baked into the rendered page: displayed landscape.
        let rotated = try #require(document.page(at: 2))
        let size = rotated.bounds(for: .mediaBox).size
        let displayed = rotated.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        #expect(displayed == CGSize(width: 600, height: 400))
    }

    @Test("OCR refuses to write over its own input")
    func refusesSamePath() async throws {
        let directory = try temporaryDirectory()
        let source = try makeSource(in: directory)
        let before = try Data(contentsOf: source)

        await #expect(throws: (any Error).self) {
            _ = try await OCRPipeline.addTextLayer(from: source, to: source)
        }
        #expect(try Data(contentsOf: source) == before)
    }
}
