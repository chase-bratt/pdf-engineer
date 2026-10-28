import Testing
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import PDFCore
@testable import DocumentModel

/// Signatures are baked into page content because custom-drawn annotations do
/// not persist their appearance on save. These tests pin the properties that
/// make baking safe: nothing else on the page is lost, and undo is exact.
@Suite("StampImageCommand")
struct StampImageCommandTests {

    /// Clear of the "P-n" label drawn at (15, 100).
    private let stampRect = CGRect(x: 120, y: 20, width: 60, height: 40)

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }

        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for index in 0..<pageCount {
            context.beginPage(mediaBox: &box)
            let label = NSAttributedString(
                string: "P-\(index)",
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 15, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.endPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        return document
    }

    /// A solid red PNG — opaque so the stamped pixel is unambiguous.
    private func redPNG() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PDFCoreError.contextCreationFailed }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                  output, UTType.png.identifier as CFString, 1, nil
              )
        else { throw PDFCoreError.contextCreationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PDFCoreError.contextCreationFailed }
        return output as Data
    }

    /// RGBA of the page pixel at `point` (page space, 1 px per point).
    private func pixel(of page: PDFPage, at point: CGPoint) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 200 * 200 * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 200, height: 200, bitsPerComponent: 8,
                bytesPerRow: 200 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw PDFCoreError.contextCreationFailed }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            page.draw(with: .mediaBox, to: context)
        }
        // Bitmap rows run top-down; page space runs bottom-up.
        let row = 199 - Int(point.y)
        let offset = (row * 200 + Int(point.x)) * 4
        return Array(buffer[offset..<offset + 4])
    }

    private func isWhite(_ rgba: [UInt8]) -> Bool { rgba[0] > 240 && rgba[1] > 240 && rgba[2] > 240 }

    private var stampCentre: CGPoint { CGPoint(x: stampRect.midX, y: stampRect.midY) }

    private func text(_ stack: CommandStack<DocumentState>, page: Int) -> String {
        stack.state.document.page(at: page)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
    }

    @Test("stamping keeps the page count and the page's text")
    func keepsCountAndText() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 3)))

        try stack.apply(StampImageCommand(pageIndex: 1, rect: stampRect, imagePNG: try redPNG()))

        #expect(stack.state.document.pageCount == 3)
        #expect(text(stack, page: 0) == "P-0")
        #expect(text(stack, page: 1) == "P-1")
        #expect(text(stack, page: 2) == "P-2")
    }

    @Test("the image is drawn into the rect as page content")
    func drawsImage() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        let before = try #require(stack.state.document.page(at: 0))
        #expect(isWhite(try pixel(of: before, at: stampCentre)))

        try stack.apply(StampImageCommand(pageIndex: 0, rect: stampRect, imagePNG: try redPNG()))

        let after = try #require(stack.state.document.page(at: 0))
        let rgba = try pixel(of: after, at: stampCentre)
        #expect(rgba[0] > 200 && rgba[1] < 60 && rgba[2] < 60)

        // Survives a save round trip — the whole reason for baking.
        let data = try #require(stack.state.document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data)?.page(at: 0))
        #expect(!isWhite(try pixel(of: reopened, at: stampCentre)))
    }

    @Test("existing annotations stay live, not flattened")
    func annotationsSurvive() throws {
        let document = try makeDocument(pageCount: 1)
        let page = try #require(document.page(at: 0))
        let note = PDFAnnotation(
            bounds: CGRect(x: 10, y: 150, width: 40, height: 20),
            forType: .square, withProperties: nil
        )
        note.contents = "keep me"
        page.addAnnotation(note)
        var stack = CommandStack(initial: DocumentState(document: document))

        try stack.apply(StampImageCommand(pageIndex: 0, rect: stampRect, imagePNG: try redPNG()))

        let stamped = try #require(stack.state.document.page(at: 0))
        #expect(stamped.annotations.count == 1)
        #expect(stamped.annotations.first?.contents == "keep me")
        #expect(stamped.annotations.first?.type == "Square")

        try stack.undo()
        let restored = try #require(stack.state.document.page(at: 0))
        #expect(restored.annotations.count == 1)
        #expect(restored.annotations.first?.contents == "keep me")
    }

    @Test("undo restores the original page and redo re-stamps it")
    func undoRedo() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 2)))
        try stack.apply(StampImageCommand(pageIndex: 1, rect: stampRect, imagePNG: try redPNG()))

        try stack.undo()
        #expect(stack.state.document.pageCount == 2)
        #expect(text(stack, page: 1) == "P-1")
        #expect(isWhite(try pixel(of: try #require(stack.state.document.page(at: 1)), at: stampCentre)))

        try stack.redo()
        #expect(stack.state.document.pageCount == 2)
        #expect(text(stack, page: 1) == "P-1")
        #expect(!isWhite(try pixel(of: try #require(stack.state.document.page(at: 1)), at: stampCentre)))

        try stack.undo()
        #expect(isWhite(try pixel(of: try #require(stack.state.document.page(at: 1)), at: stampCentre)))
    }

    @Test("rotation and boxes carry over to the stamped page")
    func keepsRotation() throws {
        let document = try makeDocument(pageCount: 1)
        document.page(at: 0)?.rotation = 90
        var stack = CommandStack(initial: DocumentState(document: document))

        try stack.apply(StampImageCommand(pageIndex: 0, rect: stampRect, imagePNG: try redPNG()))

        let page = try #require(stack.state.document.page(at: 0))
        #expect(page.rotation == 90)
        #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    @Test("a bad page index throws and changes nothing")
    func rejectsBadIndex() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        let png = try redPNG()

        #expect(throws: PDFCoreError.pageIndexOutOfRange(index: 1, pageCount: 1)) {
            try stack.apply(StampImageCommand(pageIndex: 1, rect: stampRect, imagePNG: png))
        }
        #expect(throws: PDFCoreError.pageIndexOutOfRange(index: -1, pageCount: 1)) {
            try stack.apply(StampImageCommand(pageIndex: -1, rect: stampRect, imagePNG: png))
        }
        #expect(stack.state.document.pageCount == 1)
    }

    @Test("undecodable image data throws and changes nothing")
    func rejectsBadPNG() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        let original = try #require(stack.state.document.page(at: 0))

        #expect(throws: StampImageError.unreadableImage) {
            try stack.apply(StampImageCommand(pageIndex: 0, rect: stampRect, imagePNG: Data("nope".utf8)))
        }
        #expect(stack.state.document.page(at: 0) === original)
    }

    @Test("an empty rect throws with a 1-based page number")
    func rejectsEmptyRect() throws {
        var stack = CommandStack(initial: DocumentState(document: try makeDocument(pageCount: 1)))
        let png = try redPNG()

        #expect(throws: StampImageError.emptyRect(pageIndex: 0)) {
            try stack.apply(StampImageCommand(pageIndex: 0, rect: .zero, imagePNG: png))
        }
        #expect(StampImageError.emptyRect(pageIndex: 0).errorDescription?.contains("page 1") == true)
    }

    @Test("the summary defaults to Sign and is never destructive")
    func summaryAndConsent() throws {
        let command = StampImageCommand(pageIndex: 0, rect: stampRect, imagePNG: Data())
        #expect(command.summary == "Sign")
        #expect(command.isDestructive == false)
    }
}
