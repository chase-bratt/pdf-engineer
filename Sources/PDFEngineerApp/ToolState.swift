import AppKit
import PDFKit
import SwiftUI

/// The active editing tool and its style settings, shared by the tool bar and the canvas.
@MainActor
final class ToolState: ObservableObject {

    enum Tool: String, CaseIterable, Identifiable {
        case select, editText, addText, highlight, underline, strikeOut
        case draw, rectangle, oval, line, arrow, note, whiteOut, sign

        var id: String { rawValue }

        var title: String {
            switch self {
            case .select: return "Select"
            case .editText: return "Edit Text"
            case .addText: return "Add Text"
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strikeOut: return "Strike Through"
            case .draw: return "Draw"
            case .rectangle: return "Rectangle"
            case .oval: return "Oval"
            case .line: return "Line"
            case .arrow: return "Arrow"
            case .note: return "Note"
            case .whiteOut: return "White-Out"
            case .sign: return "Sign"
            }
        }

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .editText: return "character.cursor.ibeam"
            case .addText: return "textformat"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strikeOut: return "strikethrough"
            case .draw: return "scribble"
            case .rectangle: return "rectangle"
            case .oval: return "oval"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .note: return "note.text"
            case .whiteOut: return "eraser"
            case .sign: return "signature"
            }
        }

        /// Shortcut shown in tooltips and used by the Tools menu.
        var key: KeyEquivalent? {
            switch self {
            case .select: return "v"
            case .editText: return "e"
            case .addText: return "t"
            case .draw: return "d"
            case .rectangle: return "r"
            case .note: return "n"
            default: return nil
            }
        }

        var usesFont: Bool { self == .editText || self == .addText }
        var usesStroke: Bool { [.draw, .rectangle, .oval, .line, .arrow].contains(self) }
        var usesFill: Bool { self == .rectangle || self == .oval }
        var isMarkup: Bool { self == .highlight || self == .underline || self == .strikeOut }
        /// Tools that let PDFKit's own text selection run (markup needs it).
        var allowsTextSelection: Bool { self == .select || isMarkup }
    }

    @Published var tool: Tool = .select

    // Text
    @Published var fontFamily = "Helvetica"
    @Published var fontSize: Double = 12
    @Published var bold = false
    @Published var italic = false
    @Published var alignment: NSTextAlignment = .left
    @Published var textColor: Color = .black

    // Shapes and ink
    @Published var strokeColor: Color = .red
    @Published var fillEnabled = false
    @Published var fillColor: Color = Color(nsColor: .systemYellow).opacity(0.35)
    @Published var lineWidth: Double = 2

    /// The annotation picked with the Select tool, if any, and its page.
    @Published var selectedAnnotation: SelectedAnnotation?

    struct SelectedAnnotation: Equatable {
        let annotation: PDFAnnotationRef
        let pageIndex: Int
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.annotation.object === rhs.annotation.object }
    }

    /// The signature waiting to be placed with the Sign tool.
    @Published var pendingSignature: NSImage?

    static let fontFamilies: [String] = {
        let preferred = ["Helvetica", "Helvetica Neue", "Arial", "Times New Roman", "Georgia",
                         "Courier New", "Menlo", "Avenir Next", "Gill Sans", "Palatino", "Verdana"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.filter(installed.contains)
    }()

    /// The font the text tools will use, with bold/italic applied when the family supports them.
    var font: NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let size = CGFloat(max(4, min(fontSize, 200)))
        return NSFontManager.shared.font(withFamily: fontFamily, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    var nsTextColor: NSColor { NSColor(textColor) }
    var nsStrokeColor: NSColor { NSColor(strokeColor) }
    var nsFillColor: NSColor? { fillEnabled ? NSColor(fillColor) : nil }

    /// Loads a text box's style into the controls, so editing it starts from what it looks like.
    func adopt(fontOf annotation: PDFAnnotationRef) {
        guard let font = annotation.object.font else { return }
        fontFamily = font.familyName ?? fontFamily
        fontSize = Double(font.pointSize)
        let traits = NSFontManager.shared.traits(of: font)
        bold = traits.contains(.boldFontMask)
        italic = traits.contains(.italicFontMask)
        alignment = annotation.object.alignment
        if let color = annotation.object.fontColor { textColor = Color(nsColor: color) }
    }
}

/// Identity wrapper so a `PDFAnnotation` can live in published, equatable state.
struct PDFAnnotationRef {
    let object: PDFAnnotation
}
