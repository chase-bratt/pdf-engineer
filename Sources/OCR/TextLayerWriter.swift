import CoreGraphics
import CoreText
import Foundation

/// One recognised text run, positioned in PDF user space.
public struct TextRun: Sendable, Equatable {

    public let string: String

    /// The box the glyphs must fill, in PDF user space (origin bottom-left).
    /// Taken from Vision's observation, so selection highlighting lands on the
    /// underlying pixels.
    public let rect: CGRect

    /// Word-level when Vision supplied `words`, line-level when it did not.
    ///
    /// `container.text.words` is `[RecognizedTextObservation]?` — genuinely
    /// optional — so the caller must handle both.
    public let granularity: Granularity

    /// Whether a separator must follow this run.
    ///
    /// Each word-granularity run is its own `BT…ET` text object. Without an
    /// explicit space, every extractor concatenates them into
    /// `"ZANZIBARQUOKKA"`. Found the hard way in testing.
    public let trailingSpace: Bool

    public enum Granularity: String, Sendable { case word, line }

    public init(
        string: String,
        rect: CGRect,
        granularity: Granularity,
        trailingSpace: Bool = false
    ) {
        self.string = string
        self.rect = rect
        self.granularity = granularity
        self.trailingSpace = trailingSpace
    }
}

/// Errors from the OCR layer.
public enum OCRError: Error, Equatable, Sendable {
    case contextCreationFailed
    case rasterizationFailed(page: Int)
    case documentLoadFailed
}

extension OCRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "A PDF drawing context could not be created."
        case let .rasterizationFailed(page):
            return "Page \(page + 1) could not be rendered for recognition."
        case .documentLoadFailed:
            return "The document could not be opened."
        }
    }
}

/// Draws invisible-but-searchable text into a PDF context.
///
/// ## How the invisibility works
///
/// `CGContext.setTextDrawingMode(.invisible)` emits PDF text render mode 3
/// (`3 Tr`) — "fill with no paint". The glyphs are present in the content
/// stream, so they select, search, and index, but contribute no ink.
///
/// `kCGTextInvisible` is the 4th `CGTextDrawingMode` enumerator, giving it
/// ordinal 3, and `CGContextSetTextDrawingMode` has been available since
/// macOS 10.0 — both verified in the 27.0 SDK headers.
///
/// ## Approaches that do not work
///
/// Measured in testing, and recorded here because both look plausible:
///
/// - **An alpha-0 fill colour.** The alpha is silently discarded on the way to
///   PDF; the output was byte-identical to a visible control and the text
///   printed over every scan. Never use transparency for this.
/// - **`PDFDocumentSaveTextFromOCROption`.** Real, documented symbol; a silent
///   no-op on macOS 27.2.
public enum TextLayerWriter {

    /// Font used for the invisible layer.
    ///
    /// Choice is nearly free: the glyphs are never painted, so only their
    /// *metrics* matter, and those get rescaled to the OCR box anyway. Helvetica
    /// is universally available, so no embedding is required.
    static let fontName = "Helvetica"

    /// Draws one run.
    ///
    /// - Parameters:
    ///   - run: The text and its target box in PDF user space.
    ///   - context: A PDF context with a page already begun.
    ///   - mode: Defaults to `.invisible`. `.fill` exists so tests can render a
    ///     visible control — without one, an ink test that always reads zero
    ///     would pass vacuously.
    public static func draw(
        _ run: TextRun,
        in context: CGContext,
        mode: CGTextDrawingMode = .invisible
    ) {
        // Skip degenerate runs: an empty string emits a pointless text object,
        // and a zero-size box would make the horizontal fit divide by zero and
        // write NaN into the content stream.
        guard !run.string.isEmpty, run.rect.width > 0, run.rect.height > 0 else { return }

        // Solve for the font size whose NATURAL width equals the target box,
        // then correct the height with a vertical-only matrix scale.
        //
        // Why not simply scale the text matrix horizontally: PDFKit's reported
        // selection bounds do not track a large horizontal textMatrix scale.
        // Measured on macOS 27.2 — fitting "AB" into a 400pt box via a 10x
        // matrix scale yields a selection only 220pt wide (ratio 0.55), so
        // highlighting drifts badly off the glyphs. Sizing the font instead
        // gives an exact match (ratio 1.000), because the width is then carried
        // by the font size, which PDFKit does track.
        let referenceSize: CGFloat = 100
        let probeFont = CTFontCreateWithName(fontName as CFString, referenceSize, nil)
        let probe = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: run.string,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: probeFont]
            )
        )
        let widthAtReference = CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil))
        guard widthAtReference > 0 else { return }

        let fontSize = referenceSize * run.rect.width / widthAtReference
        guard fontSize > 0, fontSize.isFinite else { return }

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: run.string,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
        )

        context.saveGState()
        context.setTextDrawingMode(mode)

        // Vertical only: the font size already fixed the width, so this just
        // squeezes the em box down to the OCR box's height. The factor stays
        // near 1, where PDFKit's geometry remains accurate.
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: run.rect.height / fontSize)
        context.textPosition = CGPoint(x: run.rect.minX, y: run.rect.minY)
        CTLineDraw(line, context)

        if run.trailingSpace {
            // Unscaled, and placed just past the box: carries the word break to
            // extractors without disturbing the fitted glyph positions above.
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: run.rect.maxX, y: run.rect.minY)
            CTLineDraw(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: " ", attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                ),
                context
            )
        }

        context.restoreGState()
    }

    /// Draws every run for one page.
    public static func draw(
        _ runs: [TextRun],
        in context: CGContext,
        mode: CGTextDrawingMode = .invisible
    ) {
        for run in runs { draw(run, in: context, mode: mode) }
    }
}
