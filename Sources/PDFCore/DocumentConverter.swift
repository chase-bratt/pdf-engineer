import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Converts word-processor documents, plain text and images to PDF.
///
/// ## Why AppKit text import
///
/// `NSAttributedString` already reads `.docx`, `.doc`, `.rtf`, `.rtfd` and
/// `.odt` — the same importers TextEdit uses — so no third-party parser is
/// needed and the result has real, selectable text. The cost is fidelity:
/// AppKit keeps paragraphs, fonts, colours, lists, simple tables and inline
/// images, but not headers/footers, footnotes, section page sizes, floating
/// shapes or tracked changes.
///
/// ## Why TextKit 1 pagination
///
/// One `NSLayoutManager` flowing into a chain of page-sized `NSTextContainer`s
/// is the only AppKit layout path that both paginates and draws
/// `NSTextAttachment` images headlessly. `NSPrintOperation` would paginate,
/// but it needs a running app's run loop (see ``PDFPaginator``), so it is not
/// usable from tests, helpers or the MCP server.
///
/// ## Concurrency
///
/// AppKit text layout and `NSGraphicsContext` are main-thread APIs, hence
/// `@MainActor`. The format checks are pure and stay `nonisolated`.
///
/// HTML is deliberately not handled here: ``HTMLConverter`` renders it with
/// WebKit, which understands CSS that AppKit's HTML importer ignores.
@MainActor
public enum DocumentConverter {

    /// Why a conversion failed, phrased so a user knows what to do next.
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        /// The file extension is not one this converter reads.
        case unsupportedFormat(String)
        /// The file exists in a supported format but could not be decoded.
        case unreadable(String)
        /// Layout needed more than ``DocumentConverter/maxPages`` pages.
        case tooManyPages
        /// The PDF could not be produced or assembled.
        case writeFailed
        /// `pdfData(combining:)` was given no files.
        case noInputs
        /// An image's header declares more than ``DocumentConverter/maxImagePixels``.
        case imageTooLarge(name: String, width: Int, height: Int)
        /// A multi-frame image has more than ``DocumentConverter/maxImageFrames`` frames.
        case tooManyFrames(name: String, count: Int)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedFormat(ext):
                let shown = ext.isEmpty ? "files without an extension" : ".\(ext) files"
                return "\(shown) can't be converted to PDF. Supported: Word (.docx, .doc), RTF, OpenDocument text, plain text, Markdown, CSV and common image formats. Convert HTML with the web page importer."
            case let .unreadable(name):
                return "\(name) could not be read. It may be damaged, password-protected, or saved in a newer format — try re-saving it from the app that created it."
            case .tooManyPages:
                return "The document would be longer than \(DocumentConverter.maxPages) pages. Split it into smaller files and convert them separately."
            case .writeFailed:
                return "The PDF could not be created. Check that there is free disk space and try again."
            case .noInputs:
                return "No files were given to combine. Choose at least one file."
            case let .imageTooLarge(name, width, height):
                let megapixels = (Double(width) * Double(height) / 1_000_000).rounded()
                return "\(name) is \(width) × \(height) pixels (\(Int(megapixels).formatted()) megapixels), more than the \(DocumentConverter.maxImagePixels / 1_000_000)-megapixel limit. Reduce its size in Preview (Tools › Adjust Size) and convert it again."
            case let .tooManyFrames(name, count):
                return "\(name) has \(count.formatted()) frames; at most \(DocumentConverter.maxImageFrames) can be converted. Split it into smaller files and convert them separately."
            }
        }
    }

    /// US Letter, in points.
    public nonisolated static let letter = CGSize(width: 612, height: 792)

    /// Hard cap on output length. A runaway layout (e.g. a multi-megabyte log
    /// file) would otherwise consume memory until the process is killed.
    public nonisolated static let maxPages = 2000

    /// Longest side of an image page, in points (≈ A3). Larger photos are
    /// scaled down so a 12-megapixel image is not a 4000-point-wide page.
    public nonisolated static let maxImageSide: CGFloat = 1190

    /// Largest image accepted, in pixels, judged from the file's header.
    ///
    /// A few kilobytes of PNG or TIFF can declare 100,000 × 100,000 pixels; a
    /// full decode of that needs tens of gigabytes and gets the process
    /// killed. 100 megapixels is above any camera or scanner page a user is
    /// likely to convert.
    public nonisolated static let maxImagePixels = 100_000_000

    /// Most frames read from a multi-frame image (TIFF). Each frame is a page
    /// and a separate decode, so this bounds the work a crafted file can demand
    /// well below ``maxPages``.
    public nonisolated static let maxImageFrames = 500

    /// Rejects an image whose declared size is over ``maxImagePixels``, before
    /// anything is decoded.
    ///
    /// Non-positive sizes are rejected as unreadable rather than passed on:
    /// they cannot come from a valid header.
    public nonisolated static func checkImageDimensions(width: Int, height: Int, name: String) throws {
        guard width > 0, height > 0 else { throw Error.unreadable(name) }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxImagePixels else {
            throw Error.imageTooLarge(name: name, width: width, height: height)
        }
    }

    // MARK: - Supported formats

    private nonisolated static let textTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML,
        "doc": .docFormat,
        "rtf": .rtf,
        "rtfd": .rtfd,
        "odt": .openDocument,
    ]

    private nonisolated static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv",
    ]

    private nonisolated static let candidateImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    /// Formats whose every frame becomes a page. For GIF, frames are animation,
    /// not pages, so only the first is used.
    private nonisolated static let multiPageImageExtensions: Set<String> = ["tiff", "tif"]

    /// Image extensions ImageIO on *this* system can decode. Asked of ImageIO
    /// rather than hard-coded so e.g. WebP is only offered where it works.
    private nonisolated static let imageExtensions: Set<String> = {
        let readable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        return candidateImageExtensions.filter { ext in
            guard let type = UTType(filenameExtension: ext) else { return false }
            return readable.contains(type.identifier)
        }
    }()

    /// Every lowercase extension ``pdfData(from:pageSize:margins:)`` accepts.
    public nonisolated static let supportedExtensions: Set<String> =
        Set(textTypes.keys).union(plainTextExtensions).union(imageExtensions)

    /// Whether `url`'s extension is one this converter handles.
    public nonisolated static func canConvert(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Conversion

    /// Converts one document or image to PDF data.
    ///
    /// - Parameters:
    ///   - url: A local file with a ``supportedExtensions`` extension.
    ///   - pageSize: Page size for text documents. Ignored for images, whose
    ///     pages are sized to the picture.
    ///   - margins: Inset on every side of text pages.
    public static func pdfData(
        from url: URL,
        pageSize: CGSize = letter,
        margins: CGFloat = 54
    ) throws -> Data {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw Error.unsupportedFormat(ext) }

        if imageExtensions.contains(ext) {
            return try ImagePDFRenderer.render(
                url: url,
                allFrames: multiPageImageExtensions.contains(ext),
                maxSide: maxImageSide,
                maxPages: maxPages
            )
        }
        let text = try loadText(from: url, ext: ext)
        return try TextPDFRenderer.render(
            text, name: url.lastPathComponent, pageSize: pageSize, margins: margins, maxPages: maxPages
        )
    }

    /// Converts each file and concatenates the results into one PDF.
    ///
    /// PDFs pass through page by page. HTML is rejected: WebKit conversion is
    /// asynchronous, so convert it with ``HTMLConverter`` first and pass the
    /// resulting PDF.
    public static func pdfData(combining urls: [URL]) throws -> Data {
        guard !urls.isEmpty else { throw Error.noInputs }
        let combined = PDFDocument()

        for url in urls {
            let source = try pdfDocument(for: url)
            for index in 0..<source.pageCount {
                guard combined.pageCount < maxPages else { throw Error.tooManyPages }
                guard let page = source.page(at: index)?.copy() as? PDFPage else {
                    throw Error.unreadable(url.lastPathComponent)
                }
                combined.insert(page, at: combined.pageCount)
            }
        }
        guard let data = combined.dataRepresentation() else { throw Error.writeFailed }
        return data
    }

    private static func pdfDocument(for url: URL) throws -> PDFDocument {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw Error.unreadable(url.lastPathComponent)
            }
            return document
        }
        guard let document = PDFDocument(data: try pdfData(from: url)) else {
            throw Error.writeFailed
        }
        return document
    }

    // MARK: - Text loading

    private static func loadText(from url: URL, ext: String) throws -> NSAttributedString {
        if let type = textTypes[ext] {
            do {
                return try NSAttributedString(
                    url: url,
                    options: [.documentType: type],
                    documentAttributes: nil
                )
            } catch {
                throw Error.unreadable(url.lastPathComponent)
            }
        }
        return try loadPlainText(from: url, monospaced: ext == "csv")
    }

    /// Plain text is decoded here rather than by the `.plain` importer so a
    /// non-UTF-8 file falls back to encoding detection instead of failing, and
    /// so it gets a readable font instead of AppKit's 12pt Helvetica default.
    /// CSV uses a monospaced font so columns line up.
    private static func loadPlainText(from url: URL, monospaced: Bool) throws -> NSAttributedString {
        let string: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            string = utf8
        } else {
            var detected = String.Encoding.utf8
            guard let fallback = try? String(contentsOf: url, usedEncoding: &detected) else {
                throw Error.unreadable(url.lastPathComponent)
            }
            string = fallback
        }
        let font = monospaced
            ? (NSFont(name: "Menlo", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular))
            : NSFont.systemFont(ofSize: 11)
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
    }
}

// MARK: - Text rendering

/// Lays an attributed string out across page-sized containers and draws each
/// container onto its own PDF page.
@MainActor
private enum TextPDFRenderer {

    /// Containers in a row that receive no glyphs before layout is declared
    /// stuck. TextKit leaves a container empty when the next line or
    /// attachment cannot fit at all; without this check such a document would
    /// spin until the page cap and report the wrong error.
    private static let maxEmptyContainers = 3

    static func render(
        _ text: NSAttributedString,
        name: String,
        pageSize: CGSize,
        margins: CGFloat,
        maxPages: Int
    ) throws -> Data {
        let textSize = CGSize(
            width: pageSize.width - 2 * margins,
            height: pageSize.height - 2 * margins
        )
        guard textSize.width > 0, textSize.height > 0 else { throw DocumentConverter.Error.writeFailed }

        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let containers = try layOut(layoutManager, name: name, textSize: textSize, maxPages: maxPages)

        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw DocumentConverter.Error.writeFailed }

        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        let origin = CGPoint(x: margins, y: margins)

        for container in containers {
            context.beginPDFPage(nil)
            // AppKit text draws top-down; PDF space is bottom-up. Flip the CTM
            // and tell AppKit the context is flipped so glyphs and attachment
            // images come out upright.
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layoutManager.glyphRange(for: container)
            if range.length > 0 {
                layoutManager.drawBackground(forGlyphRange: range, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            }
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Adds containers until every glyph is placed. An empty string still gets
    /// one container, so it renders as a single blank page.
    private static func layOut(
        _ layoutManager: NSLayoutManager,
        name: String,
        textSize: CGSize,
        maxPages: Int
    ) throws -> [NSTextContainer] {
        var containers: [NSTextContainer] = []
        var emptyRun = 0
        let glyphCount = layoutManager.numberOfGlyphs

        repeat {
            guard containers.count < maxPages else { throw DocumentConverter.Error.tooManyPages }
            let container = NSTextContainer(size: textSize)
            // Zero padding so the margins passed in are the real margins.
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)

            let range = layoutManager.glyphRange(for: container)
            emptyRun = range.length == 0 ? emptyRun + 1 : 0
            guard emptyRun < maxEmptyContainers || glyphCount == 0 else {
                throw DocumentConverter.Error.unreadable(name)
            }
            if NSMaxRange(range) >= glyphCount { break }
        } while true

        return containers
    }
}

// MARK: - Image rendering

/// Draws image frames onto pages sized to each frame.
private enum ImagePDFRenderer {

    static func render(url: URL, allFrames: Bool, maxSide: CGFloat, maxPages: Int) throws -> Data {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DocumentConverter.Error.unreadable(name)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw DocumentConverter.Error.unreadable(name) }
        // HEIC can hold several images (e.g. thumbnails, depth); the primary
        // one is what Photos shows.
        if allFrames, count > DocumentConverter.maxImageFrames {
            throw DocumentConverter.Error.tooManyFrames(name: name, count: count)
        }
        let indices = allFrames ? Array(0..<count) : [CGImageSourceGetPrimaryImageIndex(source)]
        guard indices.count <= maxPages else { throw DocumentConverter.Error.tooManyPages }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw DocumentConverter.Error.writeFailed }

        // Every frame's header is checked before any frame is decoded, so a
        // bomb in frame 40 is refused without first rendering frames 1–39.
        let sizes = try indices.map { try declaredSize(source, at: $0, name: name) }
        let maxDecodeSide = Int(maxSide * 2)

        for (index, size) in zip(indices, sizes) {
            guard let image = orientedImage(source, at: index, size: size, maxDecodeSide: maxDecodeSide) else {
                throw DocumentConverter.Error.unreadable(name)
            }
            var box = CGRect(origin: .zero, size: pageSize(for: image, maxSide: maxSide))
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }

    /// The pixel size a frame's header declares, read without decoding it,
    /// and checked against ``DocumentConverter/maxImagePixels``.
    ///
    /// A frame with no readable size is refused rather than decoded blind:
    /// the size is the only thing standing between a crafted header and a
    /// multi-gigabyte allocation.
    private static func declaredSize(_ source: CGImageSource, at index: Int, name: String) throws -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).flatMap({ $0 as? Int }),
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).flatMap({ $0 as? Int })
        else { throw DocumentConverter.Error.unreadable(name) }
        try DocumentConverter.checkImageDimensions(width: width, height: height, name: name)
        return CGSize(width: width, height: height)
    }

    /// Decodes a frame with its EXIF orientation applied. Requesting a
    /// "thumbnail" is the ImageIO idiom for this: it is the only decode path
    /// that honours `kCGImageSourceCreateThumbnailWithTransform`, so a
    /// portrait phone photo does not come out sideways.
    ///
    /// The thumbnail is capped at `maxDecodeSide` (twice the largest page
    /// side, so it stays sharp at 144 dpi): the page is scaled to
    /// ``DocumentConverter/maxImageSide`` anyway, and decoding beyond that
    /// only costs memory. There is deliberately no full-size fallback.
    private static func orientedImage(
        _ source: CGImageSource,
        at index: Int,
        size: CGSize,
        maxDecodeSide: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(max(size.width, size.height)), maxDecodeSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// One pixel per point (72 dpi), scaled down to fit `maxSide`.
    private static func pageSize(for image: CGImage, maxSide: CGFloat) -> CGSize {
        let size = CGSize(width: image.width, height: image.height)
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return size }
        let scale = maxSide / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
