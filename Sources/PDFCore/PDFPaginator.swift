import CoreGraphics
import Foundation
import PDFKit

/// Slices one tall page into letter- or A4-sized sheets.
///
/// ## Why this exists
///
/// `WKWebView.createPDF` renders a whole page as a **single tall page** rather
/// than paginated sheets — measured: 120 paragraphs all landed on page 1, and
/// CSS `page-break-before` is ignored. Content is preserved and searchable, but
/// a 10,000-point-tall page prints badly and makes page operations meaningless.
///
/// `NSPrintOperation` does paginate, but it needs AppKit's run loop to drive it;
/// called outside a running app it spins and writes an unbounded file (measured:
/// 1.35 GB before being killed). It is not usable from a helper or CLI.
///
/// So pagination is done here instead: draw the source page into each sheet at
/// a descending vertical offset, so each sheet shows one band of the original.
/// Deterministic, testable, and no run-loop dependency.
public enum PDFPaginator {

    /// Standard sheet sizes in PDF points (72 per inch).
    public struct SheetSize: Sendable {
        public let width: CGFloat
        public let height: CGFloat

        public static let letter = SheetSize(width: 612, height: 792)
        public static let a4 = SheetSize(width: 595, height: 842)

        public init(width: CGFloat, height: CGFloat) {
            self.width = width
            self.height = height
        }
    }

    /// Slices every page of `document` that is taller than one sheet.
    ///
    /// Pages that already fit are copied through untouched, so running this on
    /// an ordinary PDF is a no-op rather than a re-layout.
    ///
    /// - Parameters:
    ///   - document: Source document.
    ///   - sheet: Target sheet size in points.
    ///   - overlap: Points of vertical overlap between consecutive sheets. A
    ///     small overlap keeps a line of text from being sliced exactly in half
    ///     at a boundary and becoming unreadable on both sheets.
    /// - Returns: PDF data, or nil if a context could not be created.
    public static func paginate(
        _ document: PDFDocument,
        sheet: SheetSize = .letter,
        overlap: CGFloat = 12
    ) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { return nil }

        var sheetBox = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        guard let context = CGContext(consumer: consumer, mediaBox: &sheetBox, nil) else {
            return nil
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let source = page.bounds(for: .mediaBox)

            // A zero-width page has no width to scale to (scale would be
            // infinite and the geometry NaN), so it is copied through as-is.
            let hasArea = source.width > 0 && source.height > 0

            // Scale to fit the sheet's width, so nothing is cropped horizontally.
            let scale = hasArea ? sheet.width / source.width : 1
            let scaledHeight = source.height * scale

            if !hasArea || scaledHeight <= sheet.height + 1 {
                // Already fits: copy through, preserving its own box.
                var box = source
                context.beginPage(mediaBox: &box)
                page.draw(with: .mediaBox, to: context)
                context.endPage()
                continue
            }

            // Advance by less than a full sheet so consecutive sheets overlap.
            let advance = max(sheet.height - overlap, 1)
            let sheetCount = sheetCount(scaledHeight: scaledHeight, sheetHeight: sheet.height, advance: advance)

            for sheetIndex in 0..<sheetCount {
                context.beginPage(mediaBox: &sheetBox)
                context.saveGState()

                // Clip to the sheet so a tall page cannot bleed outside it.
                context.clip(to: sheetBox)

                // PDF user space has its origin bottom-left, so the FIRST sheet
                // shows the TOP of the page — which is the largest y. Translate
                // down from the top of the scaled content for each subsequent
                // sheet.
                let fromTop = CGFloat(sheetIndex) * advance
                context.translateBy(x: 0, y: -(scaledHeight - sheet.height - fromTop))
                context.scaleBy(x: scale, y: scale)
                // Undo the source page's own origin, which need not be zero.
                context.translateBy(x: -source.origin.x, y: -source.origin.y)

                page.draw(with: .mediaBox, to: context)

                context.restoreGState()
                context.endPage()
            }
        }

        context.closePDF()
        return output as Data
    }

    /// Number of sheets needed to cover `scaledHeight`.
    ///
    /// The first sheet covers `sheetHeight`; each further sheet adds only
    /// `advance` of new content. `ceil(scaledHeight / advance)` over-counts and
    /// can emit a trailing sheet containing nothing but overlap.
    static func sheetCount(scaledHeight: CGFloat, sheetHeight: CGFloat, advance: CGFloat) -> Int {
        guard scaledHeight > sheetHeight, advance > 0 else { return 1 }
        return max(1, 1 + Int(ceil((scaledHeight - sheetHeight) / advance)))
    }

    /// Whether any page is taller than one sheet, i.e. whether pagination would
    /// change anything.
    public static func needsPagination(
        _ document: PDFDocument,
        sheet: SheetSize = .letter
    ) -> Bool {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0 else { continue }
            let scaledHeight = bounds.height * (sheet.width / bounds.width)
            if scaledHeight > sheet.height + 1 { return true }
        }
        return false
    }
}
