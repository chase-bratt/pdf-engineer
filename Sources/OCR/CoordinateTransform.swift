import CoreGraphics
import Foundation

/// Converts between Vision's normalised image coordinates and PDF user space.
///
/// ## The two coordinate systems
///
/// | | origin | units |
/// |---|---|---|
/// | Vision (`NormalizedRegion`, `boundingBox`) | bottom-left | 0...1 of the image |
/// | PDF user space | bottom-left | points, offset by the page box origin |
///
/// Both are bottom-left, so **there is no vertical flip** between them. That is
/// the trap: AppKit and Core Image are top-left, so the instinct is to flip, and
/// flipping here puts every OCR word on the wrong half of the page. It is
/// subtle enough to warrant a dedicated test, which is
/// `CoordinateTransformTests`.
///
/// A flip *is* required when going to a `CGImage` for rasterisation, but that
/// belongs at the rendering boundary, not here.
public enum CoordinateTransform {

    /// Maps a Vision-normalised rect onto a page.
    ///
    /// - Parameters:
    ///   - normalized: Rect in 0...1, origin bottom-left.
    ///   - pageBox: The page box being OCR'd, in points — usually the CropBox,
    ///     which is what the user sees and what a rasteriser renders.
    /// - Returns: The rect in PDF user space, including the page box's origin.
    public static func pdfRect(fromNormalized normalized: CGRect, pageBox: CGRect) -> CGRect {
        CGRect(
            // The page origin must be added, or every word on a cropped page is
            // offset by the crop.
            x: pageBox.origin.x + normalized.origin.x * pageBox.width,
            y: pageBox.origin.y + normalized.origin.y * pageBox.height,
            width: normalized.width * pageBox.width,
            height: normalized.height * pageBox.height
        )
    }

    /// The inverse of ``pdfRect(fromNormalized:pageBox:)``.
    ///
    /// Used to re-derive a normalised region from stored PDF coordinates, e.g.
    /// when re-running recognition over a region the user selected.
    ///
    /// - Returns: `.zero` for a degenerate page box, rather than NaN — NaN
    ///   coordinates would silently corrupt a content stream.
    public static func normalizedRect(fromPDF rect: CGRect, pageBox: CGRect) -> CGRect {
        guard pageBox.width > 0, pageBox.height > 0 else { return .zero }

        return CGRect(
            x: (rect.origin.x - pageBox.origin.x) / pageBox.width,
            y: (rect.origin.y - pageBox.origin.y) / pageBox.height,
            width: rect.width / pageBox.width,
            height: rect.height / pageBox.height
        )
    }

    /// Scale factor from PDF points to pixels at a target resolution.
    ///
    /// PDF user space is defined as 72 units per inch, so this is `dpi / 72`.
    public static func renderScale(forDPI dpi: CGFloat) -> CGFloat {
        dpi / pointsPerInch
    }

    /// Pixel dimensions for rasterising a page at a target resolution.
    ///
    /// Rounds **up**: truncating would drop the last partial pixel row and with
    /// it any text sitting on that edge of a scan.
    ///
    /// The multiplication is ordered `points * dpi / 72` rather than
    /// `points * (dpi / 72)`. The latter computes an inexact ratio first, and
    /// `ceil` then amplifies it into a whole extra pixel: US Letter at 300 dpi
    /// gives 3301 instead of 3300. Keeping the division last makes the common
    /// resolutions land exactly, and a stray row would otherwise appear on
    /// every rasterised page.
    public static func pixelSize(pageBox: CGRect, dpi: CGFloat) -> CGSize {
        CGSize(
            width: ceil(pageBox.width * dpi / pointsPerInch),
            height: ceil(pageBox.height * dpi / pointsPerInch)
        )
    }

    /// PDF user space is 72 units per inch by definition (ISO 32000-1, 8.3.2.3).
    public static let pointsPerInch: CGFloat = 72.0
}
