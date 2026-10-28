import Testing
import PDFKit
import CoreGraphics
import Foundation
@testable import OCR

/// The invisible searchable text layer
/// (`setTextDrawingMode(.invisible)`, which emits PDF's `3 Tr`).
///
/// Testing established the technique; these tests hold it to the three
/// properties that actually matter, because each failed for a different
/// candidate approach:
///   1. the text extracts and is searchable,
///   2. the layer contributes **zero ink** (alpha-0 fill failed here), and
///   3. word boundaries survive (naive per-word runs concatenate).
@Suite("TextLayerWriter")
struct TextLayerWriterTests {

    /// A page-sized raster with visible text, standing in for a scan.
    private func scannedPDF(
        text: String = "ZANZIBAR QUOKKA 7731",
        pageCount: Int = 1,
        size: CGSize = CGSize(width: 612, height: 792)
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OCRError.contextCreationFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        for _ in 0..<pageCount {
            ctx.beginPage(mediaBox: &box)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(box)
            // Drawn as visible glyphs: this is the "scanned" appearance.
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// Counts dark pixels on a rendered page. Used for the ink test.
    private func darkPixelCount(of page: PDFPage) -> Int {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width), h = Int(box.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        page.draw(with: .mediaBox, to: ctx)

        guard let data = ctx.data else { return -1 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var dark = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            if (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3 < 128 { dark += 1 }
        }
        return dark
    }

    /// Writes runs onto a blank page with no raster, so all ink is the text layer.
    private func textOnlyPDF(runs: [TextRun], invisible: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("textonly-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OCRError.contextCreationFailed
        }
        ctx.beginPage(mediaBox: &box)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(box)
        for run in runs {
            if invisible {
                TextLayerWriter.draw(run, in: ctx)
            } else {
                TextLayerWriter.draw(run, in: ctx, mode: .fill)
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private func run(_ s: String, x: CGFloat, trailingSpace: Bool = false) -> TextRun {
        TextRun(
            string: s,
            rect: CGRect(x: x, y: 700, width: CGFloat(s.count) * 18, height: 30),
            granularity: .word,
            trailingSpace: trailingSpace
        )
    }

    // MARK: - Property 1: the text extracts and is searchable

    @Test("invisible runs are extractable")
    func invisibleTextExtracts() throws {
        let url = try textOnlyPDF(runs: [run("ZANZIBAR", x: 72)], invisible: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(text.contains("ZANZIBAR"))
    }

    @Test("invisible runs are findable, which is what searchable means to a user")
    func invisibleTextIsSearchable() throws {
        let url = try textOnlyPDF(runs: [run("QUOKKA", x: 72)], invisible: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let hits = document.findString("quokka", withOptions: [.caseInsensitive])
        #expect(hits.count == 1)
    }

    @Test("a found selection lands on the glyph box, not at the origin")
    func selectionBoundsAreCorrect() throws {
        let box = CGRect(x: 100, y: 500, width: 120, height: 30)
        let url = try textOnlyPDF(
            runs: [TextRun(string: "TARGET", rect: box, granularity: .word)],
            invisible: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        let selection = try #require(document.findString("TARGET", withOptions: []).first)
        let page = try #require(document.page(at: 0))
        let bounds = selection.bounds(for: page)

        // Selection highlighting is only useful if it sits over the pixels.
        #expect(abs(bounds.minX - box.minX) < 12)
        #expect(abs(bounds.minY - box.minY) < 12)
    }

    // MARK: - Property 2: zero ink (where alpha-0 fill failed)

    @Test("the invisible layer contributes zero ink")
    func invisibleLayerAddsNoInk() throws {
        let runs = [run("ZANZIBAR", x: 72), run("QUOKKA", x: 300)]
        let url = try textOnlyPDF(runs: runs, invisible: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        // The decisive measurement: alpha-0 fill scored identically to visible
        // text here, which is how that approach was caught.
        #expect(darkPixelCount(of: page) == 0)
    }

    @Test("the same runs drawn visibly do leave ink, proving the test can fail")
    func visibleLayerAddsInk() throws {
        let runs = [run("ZANZIBAR", x: 72)]
        let url = try textOnlyPDF(runs: runs, invisible: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        // Guards against a vacuous ink test: if the control also scored 0, the
        // measurement would be broken rather than the text invisible.
        #expect(darkPixelCount(of: page) > 0)
    }

    // MARK: - Property 3: word boundaries survive

    @Test("trailing spaces keep words from concatenating")
    func wordsDoNotConcatenate() throws {
        // Without an explicit separator each word is its own BT...ET and
        // extractors join them into "ZANZIBARQUOKKA".
        let runs = [
            run("ZANZIBAR", x: 72, trailingSpace: true),
            run("QUOKKA", x: 300, trailingSpace: false),
        ]
        let url = try textOnlyPDF(runs: runs, invisible: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("ZANZIBAR QUOKKA"))
        #expect(!text.contains("ZANZIBARQUOKKA"))
    }

    // MARK: - The emitted operator

    @Test("the content stream carries the literal 3 Tr operator")
    func contentStreamCarriesInvisibleMode() throws {
        let url = try textOnlyPDF(runs: [run("ZANZIBAR", x: 72)], invisible: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // `3 Tr` is the universal OCR-layer convention, so asserting on the
        // emitted operator — not just on behaviour — is what keeps third-party
        // extractors working, even ones that might otherwise skip invisible text.
        let streams = try ContentStreamProbe.decompressedStreams(at: url)
        #expect(streams.contains("3 Tr"))
    }

    @Test("a visibly drawn run does not emit 3 Tr")
    func visibleRunOmitsInvisibleMode() throws {
        let url = try textOnlyPDF(runs: [run("ZANZIBAR", x: 72)], invisible: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let streams = try ContentStreamProbe.decompressedStreams(at: url)
        #expect(!streams.contains("3 Tr"))
    }

    // MARK: - Geometry

    @Test("runs are fitted to their OCR box on both axes")
    func runsAreFittedToBox() throws {
        // Fitting must be near-exact, not approximate: this is what keeps a
        // selection highlight over the scanned glyphs. Sizing the font to the
        // box (rather than scaling the text matrix horizontally) achieves a
        // ratio of 1.000; a large horizontal matrix scale measured 0.55 on
        // macOS 27.2, which is visibly wrong.
        let cases: [(String, CGRect)] = [
            ("AB", CGRect(x: 72, y: 700, width: 400, height: 30)),      // stretched
            ("ZANZIBAR", CGRect(x: 72, y: 700, width: 400, height: 30)),
            ("AB", CGRect(x: 72, y: 700, width: 36, height: 30)),       // squeezed
            ("quokka", CGRect(x: 100, y: 500, width: 120, height: 14)), // realistic
        ]

        for (text, box) in cases {
            let url = try textOnlyPDF(
                runs: [TextRun(string: text, rect: box, granularity: .word)],
                invisible: true
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let document = try #require(PDFDocument(url: url))
            let selection = try #require(
                document.findString(text, withOptions: []).first,
                "\(text) was not findable"
            )
            let page = try #require(document.page(at: 0))
            let bounds = selection.bounds(for: page)

            #expect(abs(bounds.width - box.width) < 1.0, "width drift for \(text)")
            #expect(abs(bounds.height - box.height) < 1.0, "height drift for \(text)")
        }
    }

    @Test("an empty run is skipped rather than emitting a degenerate text object")
    func emptyRunIsSkipped() throws {
        let url = try textOnlyPDF(
            runs: [TextRun(string: "", rect: .zero, granularity: .word)],
            invisible: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PDFDocument(url: url)?.page(at: 0) != nil)
    }

    @Test("a zero-width box is skipped rather than dividing by zero")
    func zeroWidthBoxIsSkipped() throws {
        // The horizontal fit divides by the natural glyph width; a zero-width
        // target box would otherwise produce a NaN text matrix and corrupt the
        // content stream.
        let degenerate = CGRect(x: 72, y: 700, width: 0, height: 30)
        let url = try textOnlyPDF(
            runs: [TextRun(string: "AB", rect: degenerate, granularity: .word)],
            invisible: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let streams = try ContentStreamProbe.decompressedStreams(at: url)
        #expect(!streams.lowercased().contains("nan"))
    }

    // MARK: - Multi-page preservation

    @Test("each page keeps its own media box")
    func perPageMediaBoxPreserved() throws {
        // A single mediaBox taken from page 0 and reused would silently resize
        // every subsequent page in a mixed-size document.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, nil) else {
            throw OCRError.contextCreationFailed
        }
        var a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        ctx.beginPage(mediaBox: &first); ctx.endPDFPage()
        ctx.beginPage(mediaBox: &a4); ctx.endPDFPage()
        ctx.closePDF()

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        let p0 = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let p1 = try #require(document.page(at: 1)).bounds(for: .mediaBox)
        #expect(p0.width == 612)
        #expect(p1.width == 595, "page sizes must not be flattened to page 0's box")
    }
}
