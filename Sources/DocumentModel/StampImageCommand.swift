import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFKit

// Image stamping — the building block for signatures.
//
// ## Why the image is baked into page content
//
// The obvious approach, a `PDFAnnotation` subclass that draws the image in
// `draw(with:in:)`, does not survive a save: PDFKit writes the annotation's
// dictionary but not a custom-drawn appearance stream, so the signature
// vanishes the moment the file is reopened anywhere else. Stamping therefore
// re-renders the page with the image as ordinary page content, which every PDF
// reader displays.
//
// Baking is *not* flattening: the page's existing annotations (links,
// highlights, notes) are lifted off before the re-render and moved onto the new
// page, so they stay live and editable rather than becoming pixels.

// MARK: - Stamp

/// Draws a PNG image into a rectangle on one page, as part of the page content.
public struct StampImageCommand: Command {
    public typealias State = DocumentState

    let pageIndex: Int
    let rect: CGRect
    let imagePNG: Data
    public let summary: String

    /// - Parameters:
    ///   - pageIndex: Zero-based page to stamp.
    ///   - rect: Target rectangle in page space — PDF points in the page's
    ///     user space, origin bottom-left, exactly as `PDFView.convert(_:to:)`
    ///     and `PDFAnnotation.bounds` use. The image is aspect-fitted and
    ///     centred inside it, so a loose drag rectangle never distorts a
    ///     signature.
    ///   - imagePNG: Encoded image. PNG is expected so transparency survives;
    ///     any format ImageIO decodes is accepted.
    ///   - summary: Undo-menu and consent text. Defaults to "Sign" because
    ///     signing is the reason this command exists.
    public init(pageIndex: Int, rect: CGRect, imagePNG: Data, summary: String = "Sign") {
        self.pageIndex = pageIndex
        self.rect = rect
        self.imagePNG = imagePNG
        self.summary = summary
    }

    /// Fully undoable: the inverse swaps the untouched original page back in.
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        // Validate everything before touching the document, so bad input can
        // never leave a page half-replaced.
        let document = state.document
        let page = try Self.page(at: pageIndex, in: document)
        try Self.validate(rect: rect, pageIndex: pageIndex)
        let image = try Self.decode(imagePNG)

        let stamped = try Self.render(page: page, stampedWith: image, in: rect, pageIndex: pageIndex)

        // Detach first, then re-attach, so each annotation has exactly one
        // owning page at every moment.
        let annotations = page.annotations
        for annotation in annotations {
            page.removeAnnotation(annotation)
        }
        for annotation in annotations {
            stamped.addAnnotation(annotation)
        }

        document.removePage(at: pageIndex)
        document.insert(stamped, at: pageIndex)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // Runs before `apply`, so the copy is taken while the page — and its
        // annotations — are still pristine.
        let original = try ReplacePageCommand.capture(pageAt: pageIndex, in: state.document)
        try Self.validate(rect: rect, pageIndex: pageIndex)
        _ = try Self.decode(imagePNG)
        return ReplacePageCommand(index: pageIndex, page: original, summary: "Undo \(summary)")
    }

    // MARK: Validation

    static func page(at index: Int, in document: PDFDocument) throws -> PDFPage {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            throw PDFCoreError.pageIndexOutOfRange(index: index, pageCount: document.pageCount)
        }
        return page
    }

    static func validate(rect: CGRect, pageIndex: Int) throws {
        let finite = [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
        guard finite, rect.width > 0, rect.height > 0 else {
            throw StampImageError.emptyRect(pageIndex: pageIndex)
        }
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw StampImageError.unreadableImage }
        return image
    }

    // MARK: Rendering

    /// Renders `page` plus `image` into a fresh single-page PDF.
    ///
    /// The new page keeps the original's boxes and rotation, so it occupies the
    /// same place in layout, printing and thumbnails.
    static func render(
        page: PDFPage, stampedWith image: CGImage, in rect: CGRect, pageIndex: Int
    ) throws -> PDFPage {
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw PDFCoreError.contextCreationFailed }

        context.beginPage(mediaBox: &mediaBox)
        drawOriginal(page, into: context)
        context.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: rect))
        context.endPage()
        context.closePDF()

        // Copied out of the scratch document so the page we insert is owned
        // by nothing else (PageGraft's ownership rule).
        guard let scratch = PDFDocument(data: data as Data),
              let rendered = scratch.page(at: 0)?.copy() as? PDFPage
        else { throw PDFCoreError.pageCopyFailed(index: pageIndex) }

        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            rendered.setBounds(page.bounds(for: box), for: box)
        }
        rendered.rotation = page.rotation
        return rendered
    }

    /// Draws the page's content stream in its own user space.
    ///
    /// `CGContext.drawPDFPage` is preferred because it applies no rotation and
    /// no annotations: rotation is re-applied as `/Rotate` on the new page
    /// (drawing it in would rotate twice), and annotations are moved, not
    /// painted. A page with no backing `CGPDFPage` (one built in memory) falls
    /// back to PDFKit drawing on an unrotated, annotation-free copy.
    private static func drawOriginal(_ page: PDFPage, into context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let cgPage = page.pageRef {
            context.drawPDFPage(cgPage)
            return
        }
        guard let copy = page.copy() as? PDFPage else { return }
        copy.annotations.forEach(copy.removeAnnotation)
        copy.rotation = 0
        let origin = page.bounds(for: .mediaBox).origin
        context.translateBy(x: origin.x, y: origin.y)
        copy.draw(with: .mediaBox, to: context)
    }

    /// The largest rect with `size`'s aspect ratio that fits in `bounds`, centred.
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

/// Rejected stamp input.
public enum StampImageError: Error, Equatable, Sendable, LocalizedError {
    /// The image data could not be decoded.
    case unreadableImage
    /// The target rectangle has no area, or is not a finite rectangle.
    case emptyRect(pageIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The signature image could not be read. Use a PNG or JPEG image, "
                + "or draw or type the signature again."
        case let .emptyRect(pageIndex):
            return "The area chosen on page \(pageIndex + 1) is empty. "
                + "Drag out a box with some width and height to place the image."
        }
    }
}

// MARK: - Replace page

/// Swaps the page at an index for a previously captured page.
///
/// Internal: produced only as an inverse (of ``StampImageCommand`` and of
/// itself), never applied directly by UI or MCP code. Its own inverse captures
/// whatever page it is about to displace, which is what makes redo exact.
struct ReplacePageCommand: Command {
    typealias State = DocumentState

    /// `@unchecked Sendable` under the same invariant as
    /// ``RestorePagesCommand/Entry``: the page is a detached copy owned solely
    /// by the actor that owns the document.
    struct Captured: @unchecked Sendable {
        let page: PDFPage
    }

    let index: Int
    let captured: Captured
    let summary: String

    init(index: Int, page: PDFPage, summary: String) {
        self.index = index
        self.captured = Captured(page: page)
        self.summary = summary
    }

    var isDestructive: Bool { false }

    func apply(to state: DocumentState) throws -> DocumentState {
        let document = state.document
        _ = try StampImageCommand.page(at: index, in: document)
        // Insert a fresh copy each time, so the captured page is never owned by
        // the live document and stays reusable if this command is replayed.
        guard let copy = captured.page.copy() as? PDFPage else {
            throw PDFCoreError.pageCopyFailed(index: index)
        }
        document.removePage(at: index)
        document.insert(copy, at: index)
        return state
    }

    func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        let current = try Self.capture(pageAt: index, in: state.document)
        return ReplacePageCommand(index: index, page: current, summary: summary)
    }

    /// A detached copy of the page, annotations included — `PDFPage.copy()`
    /// deep-copies its annotations, so later edits to the live page cannot
    /// alter what undo restores.
    static func capture(pageAt index: Int, in document: PDFDocument) throws -> PDFPage {
        let page = try StampImageCommand.page(at: index, in: document)
        guard let copy = page.copy() as? PDFPage else {
            throw PDFCoreError.pageCopyFailed(index: index)
        }
        return copy
    }
}
