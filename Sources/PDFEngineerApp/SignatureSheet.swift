import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Create, pick, and manage signatures.
///
/// Presented as a sheet. Choosing a saved signature, or saving a new one,
/// hands the image to `onChoose` and dismisses; placing it on the page is the
/// caller's job, so this view never touches a document.
struct SignatureSheet: View {
    @ObservedObject var store: SignatureStore
    let onChoose: (NSImage) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case draw = "Draw", type = "Type", image = "Image"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .draw
    @State private var ink: SignatureInk = .black
    @State private var strokes: [[CGPoint]] = []
    @State private var typedName = ""
    @State private var fontChoice = SignatureFont.choices[0]
    @State private var importedImage: NSImage?
    @State private var removeWhite = true
    @State private var errorMessage: String?
    @FocusState private var focusedSignature: SavedSignature.ID?

    /// Fixed so a drawn signature's stroke width means the same thing every time.
    static let canvasSize = CGSize(width: 480, height: 170)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signature").font(.title2.bold())

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            editor
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            controls

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }

            savedGrid

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Use", action: saveAndUse)
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentImage() == nil)
            }
        }
        .padding(20)
        .frame(width: Self.canvasSize.width + 40)
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        switch mode {
        case .draw:
            ZStack(alignment: .bottomLeading) {
                SignatureCanvas(strokes: $strokes, color: ink.nsColor)
                if strokes.isEmpty {
                    Text("Sign here with the mouse or trackpad")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.quaternary).frame(height: 1)
                    .padding(.horizontal, 24).padding(.bottom, 36)
                    .allowsHitTesting(false)
            }
        case .type:
            Text(typedName.isEmpty ? "Your Name" : typedName)
                .font(Font(fontChoice.nsFont(size: 56)))
                .foregroundStyle(typedName.isEmpty ? Color.secondary.opacity(0.4) : Color(nsColor: ink.nsColor))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .padding(.horizontal, 16)
        case .image:
            if let preview = processedImport() {
                Image(nsImage: preview).resizable().scaledToFit().padding(12)
            } else {
                Button("Choose PNG or JPEG…", action: importImage)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 12) {
            switch mode {
            case .draw:
                inkPicker
                Spacer()
                Button("Clear") { strokes = [] }.disabled(strokes.isEmpty)
            case .type:
                TextField("Full name", text: $typedName).textFieldStyle(.roundedBorder)
                Picker("Style", selection: $fontChoice) {
                    ForEach(SignatureFont.choices) { Text($0.label).tag($0) }
                }
                .frame(width: 170)
                inkPicker
            case .image:
                Toggle("Remove white background", isOn: $removeWhite)
                Spacer()
                if importedImage != nil {
                    Button("Choose Another…", action: importImage)
                }
            }
        }
    }

    private var inkPicker: some View {
        Picker("Ink", selection: $ink) {
            ForEach(SignatureInk.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 130)
    }

    // MARK: Saved signatures

    @ViewBuilder private var savedGrid: some View {
        if !store.signatures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved").font(.headline)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(store.signatures) { signature in
                            savedTile(signature)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 150)
                Text("Click to use. Press ⌫ or right-click to delete.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func savedTile(_ signature: SavedSignature) -> some View {
        Image(nsImage: signature.image)
            .resizable()
            .scaledToFit()
            .padding(8)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    focusedSignature == signature.id ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: focusedSignature == signature.id ? 2 : 1
                )
            )
            .contentShape(Rectangle())
            .focusable()
            .focused($focusedSignature, equals: signature.id)
            .onTapGesture { choose(signature.image) }
            .onKeyPress(.delete) {
                store.delete(signature)
                return .handled
            }
            .contextMenu {
                Button("Use Signature") { choose(signature.image) }
                Divider()
                Button("Delete", role: .destructive) { store.delete(signature) }
            }
            .accessibilityLabel("Saved signature")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Actions

    private func choose(_ image: NSImage) {
        onChoose(image)
        dismiss()
    }

    private func saveAndUse() {
        guard let image = currentImage() else { return }
        do {
            let saved = try store.add(image)
            choose(saved.image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The image the current tab would save, or `nil` if it is still blank.
    private func currentImage() -> NSImage? {
        switch mode {
        case .draw:
            return SignatureRenderer.render(strokes: strokes, color: ink.nsColor, canvas: Self.canvasSize)
        case .type:
            let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return SignatureRenderer.render(text: name, font: fontChoice.nsFont(size: 72), color: ink.nsColor)
        case .image:
            return processedImport()
        }
    }

    private func processedImport() -> NSImage? {
        guard let importedImage else { return nil }
        return removeWhite ? (importedImage.removingWhiteBackground() ?? importedImage) : importedImage
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image of your signature"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Re-encoding through PNG normalises JPEG/colour-profile quirks and
        // gives every saved signature the same format.
        guard let image = NSImage(contentsOf: url),
              let png = image.pngData(),
              let normalised = NSImage(data: png)
        else {
            errorMessage = "\(url.lastPathComponent) could not be read as an image. Choose a PNG or JPEG file."
            return
        }
        errorMessage = nil
        importedImage = normalised
    }
}

// MARK: - Ink and fonts

enum SignatureInk: String, CaseIterable, Identifiable {
    case black, blue
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .black: return .black
        // A ballpoint blue: dark enough to read as ink, distinct from black.
        case .blue: return NSColor(srgbRed: 0.05, green: 0.18, blue: 0.62, alpha: 1)
        }
    }
}

/// A handwriting-style font, with a fallback so the Type tab works even on a
/// system where the named font is missing.
struct SignatureFont: Hashable, Identifiable {
    let label: String
    let postScriptNames: [String]
    var id: String { label }

    static let choices: [SignatureFont] = [
        SignatureFont(label: "Snell Roundhand", postScriptNames: ["SnellRoundhand", "Snell Roundhand"]),
        SignatureFont(label: "Apple Chancery", postScriptNames: ["Apple-Chancery", "Apple Chancery"]),
        SignatureFont(label: "Noteworthy", postScriptNames: ["Noteworthy-Light", "Noteworthy"]),
    ]

    func nsFont(size: CGFloat) -> NSFont {
        for name in postScriptNames {
            if let font = NSFont(name: name, size: size) { return font }
        }
        let system = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(system, toHaveTrait: .italicFontMask)
    }
}

// MARK: - Rendering

/// Renders strokes or text to a transparent image at 2x, so the stamp stays
/// crisp when the PDF is zoomed or printed.
enum SignatureRenderer {
    static let scale: CGFloat = 2
    static let lineWidth: CGFloat = 3

    static func render(strokes: [[CGPoint]], color: NSColor, canvas: CGSize) -> NSImage? {
        guard strokes.contains(where: { !$0.isEmpty }) else { return nil }
        return draw(size: canvas) { context in
            context.addPath(SignaturePath.path(for: strokes))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    static func render(text: String, font: NSFont, color: NSColor) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bounds = string.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Script fonts swash well outside their nominal box, so give generous room;
        // the store trims it back to the ink.
        let margin = font.pointSize * 0.5
        let size = CGSize(width: ceil(bounds.width + margin * 2), height: ceil(bounds.height + margin * 2))
        return draw(size: size) { context in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.current = previous
        }
    }

    /// Draws into a transparent bitmap of `size` points at ``scale``.
    private static func draw(size: CGSize, _ body: (CGContext) -> Void) -> NSImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        body(context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

/// Smooths raw mouse samples into curves.
enum SignaturePath {
    /// Quadratic curves through the midpoints of successive samples, with each
    /// sample as the control point. Mouse events arrive at uneven spacing, and
    /// straight segments between them look jagged; this keeps the curve
    /// continuous in direction without lagging behind the pointer.
    static func path(for strokes: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: first)
            if stroke.count == 1 {
                // A tap is a dot: a zero-length line with round caps.
                path.addLine(to: first)
                continue
            }
            for index in 1..<stroke.count {
                let previous = stroke[index - 1], current = stroke[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: mid, control: previous)
            }
            if let last = stroke.last { path.addLine(to: last) }
        }
        return path
    }
}

// MARK: - Drawing canvas

/// An AppKit view that captures mouse and trackpad strokes.
///
/// AppKit rather than a SwiftUI `DragGesture` because mouse events give every
/// sample (including coalesced trackpad ones) with no gesture-recognition
/// threshold swallowing the start of a stroke.
struct SignatureCanvas: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    let color: NSColor

    func makeNSView(context: Context) -> SignatureCanvasNSView {
        let view = SignatureCanvasNSView()
        view.onCommit = { strokes = $0 }
        return view
    }

    func updateNSView(_ view: SignatureCanvasNSView, context: Context) {
        view.onCommit = { strokes = $0 }
        if view.strokes != strokes { view.strokes = strokes }
        if view.inkColor != color { view.inkColor = color }
    }
}

final class SignatureCanvasNSView: NSView {
    var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    var inkColor: NSColor = .black { didSet { needsDisplay = true } }
    /// Called with the full stroke list when a stroke finishes.
    var onCommit: (([[CGPoint]]) -> Void)?

    private var current: [CGPoint] = []

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        current = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Skip sub-point jitter, which only adds kinks.
        if let last = current.last, hypot(point.x - last.x, point.y - last.y) < 0.75 { return }
        current = current + [point]
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !current.isEmpty else { return }
        let finished = strokes + [current]
        current = []
        strokes = finished
        onCommit?(finished)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(SignaturePath.path(for: current.isEmpty ? strokes : strokes + [current]))
        context.setStrokeColor(inkColor.cgColor)
        context.setLineWidth(SignatureRenderer.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}
