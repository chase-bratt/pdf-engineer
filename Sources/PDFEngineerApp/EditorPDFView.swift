import AppKit
import DocumentModel
import PDFKit

/// `PDFView` with Acrobat-style editing tools.
///
/// PDFKit gives selection, scrolling and zoom; this subclass adds the tools
/// from ``ToolState``. Every change is built as a `Command` and handed to the
/// controller, so it is undoable and audit-logged like any other edit. During
/// a drag the overlay shows a preview; nothing touches the document until the
/// mouse is released.
@MainActor
final class EditorPDFView: PDFView {

    weak var controller: AppController?
    var tools: ToolState?

    let overlay = CanvasOverlayView()
    private var editor: InlineTextEditor?
    var currentEditor: InlineTextEditor? { editor }
    func setEditor(_ value: InlineTextEditor?) { editor = value }

    /// Where a shape or ink drag started.
    private var dragPage: PDFPage?
    private var dragStart: CGPoint = .zero
    private var dragCurrent: CGPoint = .zero
    private var inkPoints: [CGPoint] = []

    /// An annotation being moved with the Select tool.
    private var moving: (annotation: PDFAnnotation, page: PDFPage, origin: CGPoint, before: AnnotationAppearance)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.drawsFlipped = isFlipped
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var tool: ToolState.Tool { tools?.tool ?? .select }

    // MARK: - Coordinates

    private func location(of event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }

    func index(of page: PDFPage) -> Int? {
        guard let document else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    /// Clamps a page-space point to the page's visible box.
    private func clamp(_ point: CGPoint, to page: PDFPage) -> CGPoint {
        let box = page.bounds(for: displayBox)
        return CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
    }

    var dragRectForFinish: CGRect { dragRect }
    var dragStartPoint: CGPoint { dragStart }
    var dragEndPoint: CGPoint { dragCurrent }
    var inkStrokePoints: [CGPoint] { inkPoints }

    private var dragRect: CGRect {
        CGRect(x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
               width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        editor?.commit()
        guard let (page, point) = location(of: event) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)

        switch tool {
        case .select:
            if let annotation = editableAnnotation(on: page, at: point) {
                select(annotation, on: page)
                if event.clickCount == 2, annotation.type == "FreeText" {
                    beginEditing(existing: annotation, on: page)
                    return
                }
                moving = (annotation, page, point, AnnotationAppearance(of: annotation))
                return
            }
            deselect()
            super.mouseDown(with: event)

        case .highlight, .underline, .strikeOut:
            super.mouseDown(with: event)

        case .editText:
            if let cover = page.annotation(at: point), cover.userName == TextEdit.marker {
                beginEditing(existing: cover, on: page)
            } else {
                beginTextEdit(on: page, at: point)
            }

        case .addText:
            beginNewText(on: page, at: point)

        case .note:
            beginNote(on: page, at: point)

        case .draw, .rectangle, .oval, .line, .arrow, .whiteOut, .sign:
            dragPage = page
            dragStart = clamp(point, to: page)
            dragCurrent = dragStart
            inkPoints = [dragStart]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let moving, let (_, point) = location(of: event) {
            let dx = point.x - moving.origin.x, dy = point.y - moving.origin.y
            moving.annotation.bounds = moving.before.bounds.offsetBy(dx: dx, dy: dy)
            refreshOverlay()
            setNeedsDisplay(bounds)
            return
        }
        guard let page = dragPage, let (_, point) = location(of: event) else {
            return super.mouseDragged(with: event)
        }
        dragCurrent = clamp(point, to: page)
        if tool == .draw { inkPoints.append(dragCurrent) }
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        if let moving {
            self.moving = nil
            let after = AnnotationAppearance(of: moving.annotation)
            if after.bounds != moving.before.bounds, let index = index(of: moving.page) {
                controller?.perform(UpdateAnnotationCommand(
                    pageIndex: index, annotation: moving.annotation,
                    from: moving.before, to: after, summary: "Move Annotation"))
            }
            refreshOverlay()
            return
        }

        if tool.isMarkup {
            super.mouseUp(with: event)
            if let selection = currentSelection, !(selection.string ?? "").isEmpty {
                controller?.addMarkup(tool.markupStyle)
            }
            return
        }

        guard let page = dragPage else { return super.mouseUp(with: event) }
        dragPage = nil
        defer { inkPoints = []; refreshOverlay() }
        guard let index = index(of: page) else { return }
        finishDrag(on: page, pageIndex: index)
    }

    override func mouseMoved(with event: NSEvent) {
        switch tool {
        case .select, .highlight, .underline, .strikeOut:
            super.mouseMoved(with: event)
        case .editText, .addText:
            NSCursor.iBeam.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117] // ⌫, ⌦
        if deleteKeys.contains(event.keyCode), let selected = tools?.selectedAnnotation {
            controller?.perform(RemoveAnnotationCommand(
                pageIndex: selected.pageIndex, annotation: selected.annotation.object))
            deselect()
            return
        }
        // Bare letters pick tools (V, E, T, D, R, N), like Acrobat and Preview.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
           let character = event.charactersIgnoringModifiers?.lowercased().first,
           let picked = ToolState.Tool.allCases.first(where: { $0.key?.character == character }) {
            tools?.tool = picked
            return
        }
        if event.keyCode == 53 { // Esc
            deselect()
            tools?.tool = .select
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Selection

    /// Annotations the user made or can sensibly move; links and form fields are left to PDFKit.
    private func editableAnnotation(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.last { annotation in
            let type = annotation.type ?? ""
            return !["Link", "Widget", "Popup"].contains(type) && annotation.bounds.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    private func select(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard let index = index(of: page) else { return }
        clearSelection()
        tools?.selectedAnnotation = .init(annotation: PDFAnnotationRef(object: annotation), pageIndex: index)
        if annotation.type == "FreeText" { tools?.adopt(fontOf: PDFAnnotationRef(object: annotation)) }
        refreshOverlay()
    }

    func deselect() {
        guard tools?.selectedAnnotation != nil else { return }
        tools?.selectedAnnotation = nil
        refreshOverlay()
    }

    // MARK: - Overlay

    func refreshOverlay() {
        overlay.drawsFlipped = isFlipped
        overlay.strokeColor = tool == .whiteOut ? .systemGray : (tools?.nsStrokeColor ?? .systemRed)
        overlay.lineWidth = CGFloat(tools?.lineWidth ?? 2) * scaleFactor
        overlay.previewRect = nil
        overlay.previewLine = nil
        overlay.previewPath = []
        overlay.previewOval = tool == .oval

        if let page = dragPage {
            switch tool {
            case .draw:
                overlay.previewPath = inkPoints.map { convert($0, from: page) }
            case .line, .arrow:
                overlay.previewLine = (convert(dragStart, from: page), convert(dragCurrent, from: page))
            default:
                overlay.previewRect = convert(dragRect, from: page)
            }
        }
        if let selected = tools?.selectedAnnotation, let page = document?.page(at: selected.pageIndex) {
            overlay.selectionRect = convert(selected.annotation.object.bounds, from: page)
        } else {
            overlay.selectionRect = nil
        }
        overlay.needsDisplay = true
    }
}

extension ToolState.Tool {
    var markupStyle: MarkupStyle {
        switch self {
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        default: return .highlight
        }
    }
}

#if DEBUG
extension EditorPDFView {
    /// Self-test hook: runs a tool's drag handling between two page points,
    /// exactly as a mouse drag would, without posting real input events.
    func debugDrag(_ tool: ToolState.Tool, on page: PDFPage, from start: CGPoint, to end: CGPoint, ink: [CGPoint] = []) {
        tools?.tool = tool
        dragPage = page
        dragStart = start
        dragCurrent = end
        inkPoints = ink.isEmpty ? [start, end] : ink
        guard let index = index(of: page) else { return }
        dragPage = nil
        finishDrag(on: page, pageIndex: index)
        inkPoints = []
    }
}
#endif
