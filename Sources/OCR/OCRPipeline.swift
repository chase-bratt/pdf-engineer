import CoreGraphics
import Foundation
import PDFCore
import PDFKit
import Vision

/// Runs Vision over a PDF and writes back an invisible searchable text layer.
///
/// The pipeline is: classify → rasterise → recognise → write an invisible
/// text layer (text render mode 3, `3 Tr`).
public enum OCRPipeline {

    /// Progress for the UI and for MCP progress notifications.
    public struct Progress: Sendable {
        public let pageIndex: Int
        public let pageCount: Int
        public let runsFound: Int
    }

    public struct Result: Sendable {
        public let pagesProcessed: Int
        public let pagesSkipped: Int
        public let runsWritten: Int
        /// True when any page fell back to line-level boxes because
        /// `container.text.words` was nil.
        public let usedLineFallback: Bool
    }

    /// Resolution for rasterising before recognition.
    ///
    /// 200 dpi is the usual accuracy/speed sweet spot for OCR: 300 is slower
    /// with little gain on clean scans, and 150 starts losing small type.
    public static let defaultDPI: CGFloat = 200

    /// Adds an invisible text layer to every page that needs one.
    ///
    /// - Parameters:
    ///   - input: The document to read.
    ///   - output: Where the new PDF is written. The input is never modified —
    ///     `CGPDFContext` can only write a fresh file, and that also means a
    ///     failed run cannot damage the user's document.
    ///   - dpi: Rasterisation resolution.
    ///   - skipPagesWithText: When true (the default), pages that already have
    ///     a text layer are copied through untouched. Re-OCRing born-digital
    ///     text replaces good text with guesses.
    ///   - onProgress: Called on the main actor after each page.
    public static func addTextLayer(
        from input: URL,
        to output: URL,
        dpi: CGFloat = defaultDPI,
        skipPagesWithText: Bool = true,
        onProgress: (@Sendable @MainActor (Progress) -> Void)? = nil
    ) async throws -> Result {
        guard let document = PDFDocument(url: input) else {
            throw OCRError.documentLoadFailed
        }
        guard !AtomicPDFWriter.isSameFile(input, output) else {
            // CGPDFContext truncates its file on creation; pointed at the input
            // it would destroy the document PDFKit is still lazily reading.
            throw PDFCoreError.outputIsInput(path: output.path)
        }

        // Render into a staging file and only move a finished result into
        // place, so a cancelled or failed run never leaves a truncated PDF.
        let staging = AtomicPDFWriter.temporaryURL(near: output)
        defer { try? FileManager.default.removeItem(at: staging) }

        var firstBox = document.page(at: 0).map(displayBox(for:))
            ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(staging as CFURL, mediaBox: &firstBox, nil) else {
            throw OCRError.contextCreationFailed
        }

        var processed = 0, skipped = 0, written = 0, fallback = false

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            // Each page keeps its own box: reusing page 0's would silently
            // resize every page in a mixed-size document. The box is the page
            // *as displayed* — cropped and rotated — because that is what
            // `draw(with: .cropBox, to:)` renders (it applies the rotation and
            // moves the crop origin to zero). The output page therefore looks
            // identical with rotation 0, and the text layer is laid out in the
            // same space the raster was recognised in.
            var box = displayBox(for: page)
            context.beginPage(mediaBox: &box)
            page.draw(with: .cropBox, to: context)

            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if skipPagesWithText, !existing.isEmpty {
                skipped += 1
                context.endPDFPage()
                let p = Progress(pageIndex: index, pageCount: document.pageCount, runsFound: 0)
                if let onProgress { await MainActor.run { onProgress(p) } }
                continue
            }

            if let image = rasterize(page: page, dpi: dpi) {
                let recognized = try await recognize(image: image, pageBox: box)
                TextLayerWriter.draw(recognized.runs, in: context)
                written += recognized.runs.count
                fallback = fallback || recognized.usedLineFallback
                processed += 1

                let p = Progress(
                    pageIndex: index, pageCount: document.pageCount,
                    runsFound: recognized.runs.count
                )
                if let onProgress { await MainActor.run { onProgress(p) } }
            }

            context.endPDFPage()
            try Task.checkCancellation()
        }

        context.closePDF()

        try finalize(staging: staging, from: document, to: output)
        return Result(
            pagesProcessed: processed, pagesSkipped: skipped,
            runsWritten: written, usedLineFallback: fallback
        )
    }

    /// The page's visible area with its rotation applied, at the origin.
    static func displayBox(for page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 1
            ? CGSize(width: crop.height, height: crop.width)
            : crop.size
        return CGRect(origin: .zero, size: size)
    }

    /// Carries document-level structure across, then moves the result into place.
    ///
    /// `CGPDFContext` writes only page content, so without this pass the OCR'd
    /// copy silently loses its bookmarks and metadata.
    static func finalize(staging: URL, from original: PDFDocument, to output: URL) throws {
        guard let rendered = PDFDocument(url: staging) else {
            throw PDFCoreError.writeFailed(path: output.path)
        }
        // Measured: PDFKit silently drops an `outlineRoot` assigned to a
        // document parsed from a file or data that had no outline — the write
        // succeeds with no /Outlines. A fresh PDFDocument does persist it, so
        // the rendered pages are copied into one first.
        let assembled = PDFDocument()
        try PageGraft.graftAll(from: rendered, into: assembled, at: 0)

        if let attributes = original.documentAttributes {
            assembled.documentAttributes = attributes
        }
        if let outline = original.outlineRoot {
            assembled.outlineRoot = OutlineCopier.copy(outline, from: original, to: assembled)
        }
        try AtomicPDFWriter.write(assembled, to: output)
    }

    // MARK: - Recognition

    struct Recognized: Sendable {
        let runs: [TextRun]
        let usedLineFallback: Bool
    }

    /// Recognises one page image, preferring per-word boxes.
    static func recognize(image: CGImage, pageBox: CGRect) async throws -> Recognized {
        // Note: RecognizeDocumentsRequest has no `recognitionLevel`; text
        // options live under `textRecognitionOptions`. Defaults are good, so
        // nothing is set here rather than guessing at tuning.
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image)

        var runs: [TextRun] = []
        var usedFallback = false

        for observation in observations {
            let container = observation.document.text

            // Prefer words: per-word boxes give selection that lands on the
            // right glyphs. `words` is Optional, so the fallback is required,
            // not defensive.
            if let words = container.words, !words.isEmpty {
                let list = Array(words)
                for (offset, word) in list.enumerated() {
                    let text = word.transcript
                    guard !text.isEmpty else { continue }
                    runs.append(
                        TextRun(
                            string: text,
                            rect: CoordinateTransform.pdfRect(
                                fromNormalized: word.boundingRegion.boundingBox.cgRect,
                                pageBox: pageBox
                            ),
                            granularity: .word,
                            // Every word but the last needs a separator, or
                            // extractors concatenate them.
                            trailingSpace: offset < list.count - 1
                        )
                    )
                }
            } else {
                usedFallback = true
                for line in container.lines {
                    let text = line.transcript
                    guard !text.isEmpty else { continue }
                    runs.append(
                        TextRun(
                            string: text,
                            rect: CoordinateTransform.pdfRect(
                                fromNormalized: line.boundingRegion.boundingBox.cgRect,
                                pageBox: pageBox
                            ),
                            granularity: .line
                        )
                    )
                }
            }
        }
        return Recognized(runs: runs, usedLineFallback: usedFallback)
    }

    /// Rasterises a page to greyscale for recognition.
    ///
    /// Greyscale is enough for OCR and a third of the memory of RGB, which
    /// matters on a 600-page scan.
    static func rasterize(page: PDFPage, dpi: CGFloat) -> CGImage? {
        // Same displayed box the output page uses, so recognised coordinates
        // land on the glyphs they came from.
        let box = displayBox(for: page)
        let size = CoordinateTransform.pixelSize(pageBox: box, dpi: dpi)
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let scale = CoordinateTransform.renderScale(forDPI: dpi)
        context.scaleBy(x: scale, y: scale)
        // No origin translation: `draw(with:to:)` already maps the crop box's
        // origin to zero (and applies rotation), so translating here would
        // shift a cropped page twice.
        page.draw(with: .cropBox, to: context)

        return context.makeImage()
    }
}
