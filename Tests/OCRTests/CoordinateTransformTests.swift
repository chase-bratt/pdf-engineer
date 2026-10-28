import Testing
import CoreGraphics
@testable import OCR

/// Vision reports normalised coordinates with the origin
/// at the **bottom-left** and values in 0...1; PDF user space is in points with
/// the origin also bottom-left but scaled to the page box.
///
/// The spec calls this "a classic off-by-a-flip bug" and mandates a dedicated
/// test. Getting it wrong puts the invisible OCR text layer in the wrong place,
/// which is invisible in testing precisely because the text is invisible.
@Suite("CoordinateTransform")
struct CoordinateTransformTests {

    /// A 612x792 page: US Letter at 72 dpi, the overwhelmingly common case.
    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    @Test("the full unit square maps to the whole page")
    func fullPageMaps() {
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            pageBox: letter
        )
        #expect(box == letter)
    }

    @Test("a bottom-left quadrant stays bottom-left")
    func bottomLeftStaysBottomLeft() {
        // Vision's origin is bottom-left, and so is PDF user space, so a
        // bottom-left observation must NOT be flipped to the top.
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            pageBox: letter
        )
        #expect(box == CGRect(x: 0, y: 0, width: 306, height: 396))
    }

    @Test("a top-left quadrant maps to the upper half")
    func topLeftMapsUp() {
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            pageBox: letter
        )
        #expect(box == CGRect(x: 0, y: 396, width: 306, height: 396))
    }

    @Test("a non-zero page origin is respected")
    func respectsPageOrigin() {
        // Cropped pages have a non-zero MediaBox/CropBox origin. Ignoring it
        // offsets every word on the page.
        let cropped = CGRect(x: 20, y: 30, width: 200, height: 400)
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            pageBox: cropped
        )
        #expect(box == cropped)
    }

    @Test("a centred observation maps to the page centre")
    func centreMapsToCentre() {
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            pageBox: letter
        )
        #expect(box.midX == letter.midX)
        #expect(box.midY == letter.midY)
    }

    @Test("round-tripping a rect returns the original")
    func roundTrips() {
        let original = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        let pdf = CoordinateTransform.pdfRect(fromNormalized: original, pageBox: letter)
        let back = CoordinateTransform.normalizedRect(fromPDF: pdf, pageBox: letter)

        #expect(abs(back.origin.x - original.origin.x) < 1e-9)
        #expect(abs(back.origin.y - original.origin.y) < 1e-9)
        #expect(abs(back.width - original.width) < 1e-9)
        #expect(abs(back.height - original.height) < 1e-9)
    }

    @Test("round-tripping through a cropped page also returns the original")
    func roundTripsWithOrigin() {
        let cropped = CGRect(x: 15, y: 25, width: 300, height: 500)
        let original = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)

        let pdf = CoordinateTransform.pdfRect(fromNormalized: original, pageBox: cropped)
        let back = CoordinateTransform.normalizedRect(fromPDF: pdf, pageBox: cropped)

        #expect(abs(back.origin.x - original.origin.x) < 1e-9)
        #expect(abs(back.origin.y - original.origin.y) < 1e-9)
    }

    @Test("a degenerate page box yields zero rather than NaN")
    func degeneratePageBox() {
        // A zero-size box would divide by zero on the way back. Guard it,
        // because NaN coordinates silently corrupt a content stream.
        let back = CoordinateTransform.normalizedRect(
            fromPDF: CGRect(x: 0, y: 0, width: 10, height: 10),
            pageBox: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(back == .zero)
        #expect(!back.origin.x.isNaN)
    }

    @Test("a zero-height observation keeps its baseline position")
    func zeroHeightObservation() {
        // Vision can report a degenerate box for a single thin mark.
        let box = CoordinateTransform.pdfRect(
            fromNormalized: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0),
            pageBox: letter
        )
        #expect(box.height == 0)
        #expect(box.origin.y == 396)
    }

    // MARK: - Scale, for rasterisation

    @Test("rendering scale converts points to pixels at a target dpi")
    func renderScale() {
        // PDF user space is 72 units per inch by definition, so 300 dpi is a
        // scale of 300/72. Compared with a tolerance: the ratio is not exactly
        // representable in binary floating point.
        #expect(abs(CoordinateTransform.renderScale(forDPI: 300) - 300.0 / 72.0) < 1e-12)
        #expect(CoordinateTransform.renderScale(forDPI: 72) == 1.0)
    }

    @Test("pixel size is exact at common resolutions despite the inexact ratio")
    func pixelSizeIsExact() {
        // Regression: computing `points * (dpi/72)` yields 3301 for US Letter
        // at 300 dpi because the ratio is inexact and ceil amplifies it. The
        // division must come last.
        for dpi in [72.0, 150.0, 200.0, 300.0, 600.0] as [CGFloat] {
            let size = CoordinateTransform.pixelSize(pageBox: letter, dpi: dpi)
            #expect(size.width == (612 * dpi / 72).rounded(.down))
            #expect(size.height == (792 * dpi / 72).rounded(.down))
        }
    }

    @Test("pixel size for a page at a given dpi rounds up")
    func pixelSize() {
        let size = CoordinateTransform.pixelSize(pageBox: letter, dpi: 300)
        // 612pt = 8.5in -> 2550px; 792pt = 11in -> 3300px.
        #expect(size.width == 2550)
        #expect(size.height == 3300)
    }

    @Test("a non-integral page size rounds up rather than truncating")
    func pixelSizeRoundsUp() {
        // Truncating would crop the last partial pixel row, losing a sliver of
        // the scan — and with it any text sitting on that edge.
        let odd = CGRect(x: 0, y: 0, width: 100.5, height: 50.25)
        let size = CoordinateTransform.pixelSize(pageBox: odd, dpi: 72)
        #expect(size.width == 101)
        #expect(size.height == 51)
    }
}
