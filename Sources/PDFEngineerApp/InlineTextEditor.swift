import AppKit

/// A borderless text view laid over the page for typing new or edited text.
///
/// Return commits (⇧↩ adds a line in multi-line mode), Esc cancels, and
/// clicking elsewhere commits — the same rules as Acrobat's text tools.
@MainActor
final class InlineTextEditor: NSTextView {

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isFinished = false
    let multiline: Bool

    init(frame: NSRect, text: String, font: NSFont, color: NSColor, background: NSColor?, multiline: Bool) {
        self.multiline = multiline
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        string = text
        self.font = font
        textColor = color
        insertionPointColor = .controlAccentColor
        drawsBackground = true
        backgroundColor = (background ?? .white).withAlphaComponent(0.96)
        isRichText = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = true
        textContainerInset = NSSize(width: 1, height: 0)
        textContainer?.lineFragmentPadding = 0
        maxSize = NSSize(width: 4000, height: 4000)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 2
        selectAll(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        multiline = true
        super.init(frame: frameRect, textContainer: container)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            cancel()
        case 36, 76: // Return / Enter
            if multiline && event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                commit()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        sizeToFitText()
    }

    /// Grows to fit what's typed, so long replacements are visible while editing.
    func sizeToFitText() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let width = max(frame.width, ceil(used.width) + 8)
        let height = max(frame.height, ceil(used.height) + 2)
        if width != frame.width || height != frame.height {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    func commit() {
        guard !isFinished else { return }
        isFinished = true
        onCommit?(string)
        removeFromSuperview()
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel?()
        removeFromSuperview()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // Clicking anywhere else (another page, the sidebar) commits the text.
        if resigned { DispatchQueue.main.async { [weak self] in self?.commit() } }
        return resigned
    }
}

/// Draws in-progress shapes and the selected annotation's outline above the page.
@MainActor
final class CanvasOverlayView: NSView {

    /// Shapes to draw, already converted to this view's coordinates.
    var previewRect: NSRect?
    var previewOval = false
    var previewLine: (NSPoint, NSPoint)?
    var previewPath: [NSPoint] = []
    var selectionRect: NSRect?
    var strokeColor: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var drawsFlipped = false

    override var isFlipped: Bool { drawsFlipped }

    /// Purely visual: clicks go straight through to the PDF view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        strokeColor.setStroke()
        if let rect = previewRect {
            let path = previewOval ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        }
        if let (start, end) = previewLine {
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.stroke()
        }
        if previewPath.count > 1 {
            let path = NSBezierPath()
            path.move(to: previewPath[0])
            previewPath.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        if let rect = selectionRect {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        }
    }
}
