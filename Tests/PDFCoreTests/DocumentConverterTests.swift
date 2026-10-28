import AppKit
import Foundation
import PDFKit
import Testing
@testable import PDFCore

/// Document/image → PDF conversion and annotation flattening. All inputs are
/// generated at runtime so no binary fixtures live in the repo.
@MainActor
@Suite("DocumentConverter and PDFFlattener")
struct DocumentConverterTests {

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Enough distinct paragraphs to overflow one Letter page several times,
    /// with unique first and last words to prove nothing was dropped.
    private func longText() -> String {
        let body = (1...120).map {
            "Paragraph \($0) of filler text that wraps across the line to take up vertical space on the page."
        }
        return (["Aardvarkstart opens the document."] + body + ["Zebrafinish closes the document."])
            .joined(separator: "\n\n")
    }

    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PDFCoreError.contextCreationFailed }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw PDFCoreError.contextCreationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PDFCoreError.writeFailed(path: url.path) }
    }

    /// A valid all-black 1-bit PNG of the given size: about 50 KB on disk for
    /// 20,000 × 20,000, which decodes to 1.6 GB of RGBA.
    ///
    /// Not header-only: ImageIO validates the compressed stream before it
    /// reports a size, so a truncated file is simply unreadable and would not
    /// exercise the size guard. Every byte of the raw image is zero (filter
    /// byte included), which keeps the zlib Adler-32 trivially computable.
    private func bombPNG(width: UInt32, height: UInt32) throws -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
        }
        let rawCount = (1 + (Int(width) + 7) / 8) * Int(height)
        let deflated = try (Data(count: rawCount) as NSData).compressed(using: .zlib) as Data
        // Adler-32 of n zero bytes: a = 1, b = n mod 65521.
        let adler = UInt32(rawCount % 65_521) << 16 | 1
        let zlib = [0x78, 0x9C] + Array(deflated) + bigEndian(adler)
        // 1-bit greyscale, no interlace.
        let ihdr = bigEndian(width) + bigEndian(height) + [1, 0, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private func document(_ data: Data) throws -> PDFDocument {
        try #require(PDFDocument(data: data))
    }

    private func allText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Formats

    @Test("supported extensions exclude HTML and include the core formats")
    func supportedExtensions() {
        let supported = DocumentConverter.supportedExtensions
        #expect(!supported.contains("html"))
        #expect(!supported.contains("htm"))
        for ext in ["docx", "doc", "rtf", "rtfd", "odt", "txt", "md", "csv", "png", "jpg", "tiff"] {
            #expect(supported.contains(ext), "\(ext) should be supported")
        }
        #expect(DocumentConverter.canConvert(URL(fileURLWithPath: "/tmp/Report.DOCX")))
        #expect(!DocumentConverter.canConvert(URL(fileURLWithPath: "/tmp/page.html")))
    }

    @Test("unsupported extension throws unsupportedFormat")
    func unsupportedThrows() throws {
        let url = try temporaryDirectory().appendingPathComponent("data.xyz")
        try Data("hello".utf8).write(to: url)
        #expect(throws: DocumentConverter.Error.unsupportedFormat("xyz")) {
            try DocumentConverter.pdfData(from: url)
        }
    }

    @Test("combining rejects HTML with unsupportedFormat")
    func combiningRejectsHTML() throws {
        let url = try temporaryDirectory().appendingPathComponent("page.html")
        try Data("<p>hi</p>".utf8).write(to: url)
        #expect(throws: DocumentConverter.Error.unsupportedFormat("html")) {
            try DocumentConverter.pdfData(combining: [url])
        }
    }

    // MARK: - Text

    @Test("long RTF paginates onto several Letter pages with nothing lost")
    func rtfPaginates() throws {
        let url = try temporaryDirectory().appendingPathComponent("long.rtf")
        let source = attributed(longText())
        let rtf = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try rtf.write(to: url)

        let pdf = try document(try DocumentConverter.pdfData(from: url))
        #expect(pdf.pageCount >= 2)
        #expect(pdf.page(at: 0)?.string?.contains("Aardvarkstart") == true)
        #expect(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Zebrafinish") == true)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    }

    @Test("plain text converts with its content searchable")
    func plainText() throws {
        let url = try temporaryDirectory().appendingPathComponent("notes.txt")
        try Data("Hello plain text world".utf8).write(to: url)
        let pdf = try document(try DocumentConverter.pdfData(from: url))
        #expect(pdf.pageCount == 1)
        #expect(allText(pdf).contains("plain text world"))
    }

    @Test("empty text file produces one blank page")
    func emptyText() throws {
        let url = try temporaryDirectory().appendingPathComponent("empty.txt")
        try Data().write(to: url)
        let pdf = try document(try DocumentConverter.pdfData(from: url))
        #expect(pdf.pageCount == 1)
    }

    @Test("docx written by AppKit round-trips into a PDF")
    func docxRoundTrip() throws {
        let url = try temporaryDirectory().appendingPathComponent("memo.docx")
        let source = attributed(longText())
        let docx = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try docx.write(to: url)

        let pdf = try document(try DocumentConverter.pdfData(from: url, pageSize: CGSize(width: 595, height: 842)))
        #expect(pdf.pageCount >= 2)
        let text = allText(pdf)
        #expect(text.contains("Aardvarkstart"))
        #expect(text.contains("Zebrafinish"))
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
    }

    /// RTFD rather than docx: AppKit's docx *writer* drops images, so a docx
    /// round-trip cannot carry one. Reading uses the same attachment path.
    @Test("inline image in RTFD survives conversion")
    func rtfdInlineImage() throws {
        let directory = try temporaryDirectory()
        let png = directory.appendingPathComponent("red.png")
        try writePNG(to: png, width: 100, height: 60)
        let wrapper = FileWrapper(regularFileWithContents: try Data(contentsOf: png))
        wrapper.preferredFilename = "red.png"
        let text = NSMutableAttributedString(attributedString: attributed("Before image\n"))
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        text.append(attributed("\nAfter image"))
        let url = directory.appendingPathComponent("pictures.rtfd")
        let rtfd = try #require(text.rtfdFileWrapper(from: NSRange(location: 0, length: text.length)))
        try rtfd.write(to: url, options: .atomic, originalContentsURL: nil)

        let pdf = try document(try DocumentConverter.pdfData(from: url))
        let page = try #require(pdf.page(at: 0))
        #expect(page.string?.contains("After image") == true)
        let thumbnail = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        let bitmap = try #require(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var coloured = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let colour = bitmap.colorAt(x: x, y: y), colour.saturationComponent > 0.5 { coloured += 1 }
            }
        }
        #expect(coloured > 1000, "the 100×60 image should be drawn on the page")
    }

    @Test("corrupt docx throws unreadable with the file name")
    func corruptDocx() throws {
        let url = try temporaryDirectory().appendingPathComponent("broken.docx")
        try Data("not a zip".utf8).write(to: url)
        #expect(throws: DocumentConverter.Error.unreadable("broken.docx")) {
            try DocumentConverter.pdfData(from: url)
        }
    }

    // MARK: - Images

    @Test("PNG becomes one page sized to the image")
    func pngPage() throws {
        let url = try temporaryDirectory().appendingPathComponent("chart.png")
        try writePNG(to: url, width: 300, height: 200)
        let pdf = try document(try DocumentConverter.pdfData(from: url))
        #expect(pdf.pageCount == 1)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))
    }

    @Test("oversized image is scaled to fit the maximum side")
    func largeImageScaled() throws {
        let url = try temporaryDirectory().appendingPathComponent("big.png")
        try writePNG(to: url, width: 2380, height: 1000)
        let pdf = try document(try DocumentConverter.pdfData(from: url))
        let size = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(size.width == DocumentConverter.maxImageSide)
        #expect(size.height == 500)
    }

    @Test("a small PNG declaring 400 megapixels is refused before decoding")
    func decompressionBombRefused() throws {
        // ~50 KB that decodes to 20,000 × 20,000 pixels: 1.6 GB as RGBA.
        // The declared size must be read and rejected before any decode.
        let url = try temporaryDirectory().appendingPathComponent("bomb.png")
        let bomb = try bombPNG(width: 20_000, height: 20_000)
        #expect(bomb.count < 200_000)
        try bomb.write(to: url)

        #expect(throws: DocumentConverter.Error.imageTooLarge(name: "bomb.png", width: 20_000, height: 20_000)) {
            try DocumentConverter.pdfData(from: url)
        }
        let message = DocumentConverter.Error.imageTooLarge(name: "bomb.png", width: 20_000, height: 20_000)
            .errorDescription ?? ""
        #expect(message.contains("400 megapixels"))
        #expect(message.contains("100-megapixel"))
    }

    @Test("the dimension guard allows up to the limit and rejects overflow and nonsense")
    func dimensionGuard() throws {
        try DocumentConverter.checkImageDimensions(width: 10_000, height: 10_000, name: "ok.png")
        #expect(throws: DocumentConverter.Error.self) {
            try DocumentConverter.checkImageDimensions(width: 10_001, height: 10_000, name: "x.png")
        }
        #expect(throws: DocumentConverter.Error.self) {
            try DocumentConverter.checkImageDimensions(width: Int.max, height: 2, name: "x.png")
        }
        #expect(throws: DocumentConverter.Error.unreadable("x.png")) {
            try DocumentConverter.checkImageDimensions(width: 0, height: 10, name: "x.png")
        }
    }

    @Test("a TIFF with more frames than the cap is refused with the count")
    func tooManyTIFFFrames() throws {
        let url = try temporaryDirectory().appendingPathComponent("frames.tiff")
        let frames = DocumentConverter.maxImageFrames + 1
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, frames, nil)
        else { throw PDFCoreError.contextCreationFailed }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))

        #expect(throws: DocumentConverter.Error.tooManyFrames(name: "frames.tiff", count: frames)) {
            try DocumentConverter.pdfData(from: url)
        }
    }

    // MARK: - Combining

    @Test("combining txt, png and a PDF concatenates every page")
    func combining() throws {
        let directory = try temporaryDirectory()
        let txt = directory.appendingPathComponent("a.txt")
        try Data("First file".utf8).write(to: txt)
        let png = directory.appendingPathComponent("b.png")
        try writePNG(to: png, width: 100, height: 100)

        let rtf = directory.appendingPathComponent("long.rtf")
        let source = attributed(longText())
        try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ).write(to: rtf)
        let generated = try document(try DocumentConverter.pdfData(from: rtf))
        let pdfURL = directory.appendingPathComponent("c.pdf")
        #expect(generated.write(to: pdfURL))

        let combined = try document(try DocumentConverter.pdfData(combining: [txt, png, pdfURL]))
        #expect(combined.pageCount == 1 + 1 + generated.pageCount)
        #expect(combined.page(at: 0)?.string?.contains("First file") == true)
        #expect(combined.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 100))
    }

    @Test("combining nothing throws noInputs")
    func combiningEmpty() {
        #expect(throws: DocumentConverter.Error.noInputs) {
            try DocumentConverter.pdfData(combining: [])
        }
    }

    // MARK: - Flattening

    @Test("flattening bakes in annotations and keeps page count and sizes")
    func flattening() throws {
        let url = try temporaryDirectory().appendingPathComponent("notes.txt")
        try Data(longText().utf8).write(to: url)
        let source = try document(try DocumentConverter.pdfData(from: url))
        let firstPage = try #require(source.page(at: 0))
        let highlight = PDFAnnotation(
            bounds: CGRect(x: 54, y: 700, width: 200, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        highlight.color = .yellow
        firstPage.addAnnotation(highlight)
        // A rotated page must come out landscape-shaped, without /Rotate.
        try #require(source.page(at: 1)).rotation = 90
        #expect(firstPage.annotations.count == 1)

        let flat = try document(try PDFFlattener.flattenedData(from: source))
        #expect(flat.pageCount == source.pageCount)
        for index in 0..<flat.pageCount {
            let page = try #require(flat.page(at: index))
            #expect(page.annotations.isEmpty)
            #expect(page.rotation == 0)
            let original = try #require(source.page(at: index))
            #expect(page.bounds(for: .mediaBox).size == PDFFlattener.visibleSize(of: original))
        }
        #expect(flat.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
        #expect(flat.page(at: 0)?.string?.contains("Aardvarkstart") == true, "text must stay vector")
    }
}
