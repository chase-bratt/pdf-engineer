import AppKit
import DocumentModel
import PDFKit

/// What each tool builds when the user clicks or finishes a drag.
extension EditorPDFView {

    // MARK: - Edit Text

    /// Click a line of text (including OCR'd text) to retype it.
    func beginTextEdit(on page: PDFPage, at point: CGPoint) {
        guard let line = page.selectionForLine(at: point),
              let original = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty
        else {
            controller?.status("No text there — click directly on a line of text to edit it.")
            NSSound.beep()
            return
        }
        let lineBounds = line.bounds(for: page)
        // A little vertical room so ascenders and descenders aren't clipped by
        // the text box's internal padding.
        let bounds = lineBounds.insetBy(dx: -1, dy: -max(1.5, lineBounds.height * 0.12))
        // Reuse the original font exactly when the page records it; OCR'd scans
        // don't, so they size the tool bar's font to the line instead.
        let originalFont = line.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let font: NSFont
        if let originalFont, originalFont.pointSize >= 4 {
            font = originalFont
        } else {
            let size = max(5, min(lineBounds.height * 0.74, 72))
            let family = tools?.fontFamily ?? "Helvetica"
            font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? .systemFont(ofSize: size)
        }
        let background = Self.backgroundColor(of: page, around: bounds)
        let textColor = tools?.nsTextColor ?? .black

        presentEditor(on: page, rect: bounds, text: original, font: font, color: textColor,
                      background: background, multiline: false) { [weak self] text in
            guard let self, text != original, let index = self.index(of: page) else { return }
            let width = max(bounds.width, Self.width(of: text, font: font) + 4)
            let cover = TextEdit.coverAnnotation(
                bounds: CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                text: text, font: font, textColor: textColor, background: background
            )
            self.controller?.perform(AddAnnotationCommand(pageIndex: index, annotation: cover, summary: "Edit Text"))
        }
    }

    /// Re-edit a text box or an earlier text edit in place.
    func beginEditing(existing annotation: PDFAnnotation, on page: PDFPage) {
        let font = annotation.font ?? tools?.font ?? .systemFont(ofSize: 12)
        let before = AnnotationAppearance(of: annotation)
        presentEditor(on: page, rect: annotation.bounds, text: annotation.contents ?? "", font: font,
                      color: annotation.fontColor ?? .black, background: annotation.color,
                      multiline: annotation.userName != TextEdit.marker) { [weak self] text in
            guard let self, text != before.contents, let index = self.index(of: page) else { return }
            var after = before
            after.contents = text
            after.bounds.size.width = max(before.bounds.width, Self.width(of: text, font: font) + 4)
            self.controller?.perform(UpdateAnnotationCommand(
                pageIndex: index, annotation: annotation, from: before, to: after, summary: "Edit Text"))
        }
    }

    // MARK: - Add Text and Note

    func beginNewText(on page: PDFPage, at point: CGPoint) {
        guard let tools else { return }
        let font = tools.font
        let rect = CGRect(x: point.x, y: point.y - font.pointSize * 1.2, width: 160, height: font.pointSize * 1.4)
        presentEditor(on: page, rect: rect, text: "", font: font, color: tools.nsTextColor,
                      background: nil, multiline: true) { [weak self] text in
            guard let self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let index = self.index(of: page) else { return }
            let measured = Self.size(of: text, font: font)
            let bounds = CGRect(x: rect.minX, y: rect.maxY - measured.height - 4,
                                width: max(40, measured.width + 8), height: measured.height + 4)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = font
            annotation.fontColor = tools.nsTextColor
            annotation.color = .clear
            annotation.alignment = tools.alignment
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            self.controller?.perform(AddAnnotationCommand(pageIndex: index, annotation: annotation, summary: "Add Text"))
        }
    }

    func beginNote(on page: PDFPage, at point: CGPoint) {
        let rect = CGRect(x: point.x, y: point.y - 60, width: 200, height: 60)
        presentEditor(on: page, rect: rect, text: "", font: .systemFont(ofSize: 12), color: .black,
                      background: NSColor.systemYellow.withAlphaComponent(0.25), multiline: true) { [weak self] text in
            guard let self, !text.isEmpty, let index = self.index(of: page) else { return }
            let note = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20),
                                     forType: .text, withProperties: nil)
            note.contents = text
            note.color = .systemYellow
            note.iconType = .comment
            self.controller?.perform(AddAnnotationCommand(pageIndex: index, annotation: note, summary: "Add Note"))
        }
    }

    // MARK: - Shapes, ink, white-out, signature

    func finishDrag(on page: PDFPage, pageIndex: Int) {
        guard let tools, let controller else { return }
        let rect = dragRectForFinish
        let stroke = tools.nsStrokeColor
        let width = CGFloat(tools.lineWidth)
        let tooSmall = rect.width < 3 && rect.height < 3

        switch tool {
        case .rectangle, .oval:
            guard !tooSmall else { return }
            let annotation = PDFAnnotation(bounds: rect, forType: tool == .oval ? .circle : .square, withProperties: nil)
            annotation.color = stroke
            annotation.interiorColor = tools.nsFillColor
            annotation.border = Self.border(width)
            controller.perform(AddAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: tool.title))

        case .line, .arrow:
            guard !tooSmall else { return }
            let start = dragStartPoint, end = dragEndPoint
            let bounds = rect.insetBy(dx: -(width * 3 + 6), dy: -(width * 3 + 6))
            let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
            annotation.endLineStyle = tool == .arrow ? .closedArrow : .none
            annotation.color = stroke
            annotation.interiorColor = stroke
            annotation.border = Self.border(width)
            controller.perform(AddAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: tool.title))

        case .draw:
            let points = inkStrokePoints
            guard points.count > 1 else { return }
            let pathBounds = Self.bounds(of: points).insetBy(dx: -width, dy: -width)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: points[0].x - pathBounds.minX, y: points[0].y - pathBounds.minY))
            for point in points.dropFirst() {
                path.line(to: CGPoint(x: point.x - pathBounds.minX, y: point.y - pathBounds.minY))
            }
            let annotation = PDFAnnotation(bounds: pathBounds, forType: .ink, withProperties: nil)
            annotation.add(path)
            annotation.color = stroke
            annotation.border = Self.border(width)
            controller.perform(AddAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: "Drawing"))

        case .whiteOut:
            guard !tooSmall else { return }
            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            let fill = Self.backgroundColor(of: page, around: rect)
            annotation.color = fill
            annotation.interiorColor = fill
            annotation.border = Self.border(0)
            controller.perform(AddAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: "White-Out"))

        case .sign:
            guard let signature = tools.pendingSignature else {
                controller.showingSignatureSheet = true
                return
            }
            // A click places the signature at a natural size; a drag sets the box.
            let aspect = signature.size.height / max(signature.size.width, 1)
            let box = tooSmall
                ? CGRect(x: dragStartPoint.x - 90, y: dragStartPoint.y - 90 * aspect, width: 180, height: 180 * aspect)
                : rect
            controller.placeSignature(signature, in: box, pageIndex: pageIndex)

        default:
            break
        }
    }

    // MARK: - Editor plumbing

    func presentEditor(on page: PDFPage, rect: CGRect, text: String, font: NSFont, color: NSColor,
                       background: NSColor?, multiline: Bool, onCommit: @escaping (String) -> Void) {
        let viewRect = convert(rect, from: page)
        let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scaleFactor) ?? font
        let field = InlineTextEditor(frame: viewRect, text: text, font: scaled, color: color,
                                     background: background, multiline: multiline)
        field.onCommit = { [weak self] value in
            self?.setEditor(nil)
            onCommit(value)
        }
        field.onCancel = { [weak self] in self?.setEditor(nil) }
        addSubview(field)
        field.sizeToFitText()
        window?.makeFirstResponder(field)
        setEditor(field)
    }

    /// Commits any text being typed; called before navigation or tool changes.
    func commitEditing() {
        currentEditor?.commit()
    }

    // MARK: - Helpers

    static func border(_ width: CGFloat) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        return border
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        size(of: text, font: font).width
    }

    static func size(of text: String, font: NSFont) -> CGSize {
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The page's background colour around `rect` (white paper, or the tint of a scan),
    /// so covers for edited text and white-out blend in. Takes the lightest colour on
    /// the rect's edge, since the background is lighter than ink.
    static func backgroundColor(of page: PDFPage, around rect: CGRect) -> NSColor {
        let sample = rect.insetBy(dx: -2, dy: -2)
        let scale: CGFloat = 2
        let width = max(Int(sample.width * scale), 4), height = max(Int(sample.height * scale), 4)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -sample.minX, y: -sample.minY)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .white }

        var best: (lum: Int, r: UInt8, g: UInt8, b: UInt8) = (-1, 255, 255, 255)
        let edgePoints = (0..<width).flatMap { [($0, 0), ($0, height - 1)] }
            + (0..<height).flatMap { [(0, $0), (width - 1, $0)] }
        for (x, y) in edgePoints {
            let offset = (y * width + x) * 4
            let r = data[offset], g = data[offset + 1], b = data[offset + 2]
            let lum = Int(r) * 299 + Int(g) * 587 + Int(b) * 114
            if lum > best.lum { best = (lum, r, g, b) }
        }
        return NSColor(srgbRed: CGFloat(best.r) / 255, green: CGFloat(best.g) / 255, blue: CGFloat(best.b) / 255, alpha: 1)
    }
}
