import AppKit
import PDFCore
import PDFKit

// Annotation commands: the single undoable path for every drawing and markup
// tool (text boxes, shapes, ink, notes, white-out, edited text).
//
// They hold the `PDFAnnotation` instance itself, so undo and redo add and
// remove the *same* object and never touch annotations the user made
// elsewhere. `@unchecked Sendable` under the same invariant as
// ``DocumentState``: the annotation is confined to the actor that owns the
// document and is never read from another isolation domain.

// MARK: - Add

public struct AddAnnotationCommand: Command, @unchecked Sendable {
    public typealias State = DocumentState

    let pageIndex: Int
    let annotation: PDFAnnotation
    public let summary: String

    public init(pageIndex: Int, annotation: PDFAnnotation, summary: String) {
        self.pageIndex = pageIndex
        self.annotation = annotation
        self.summary = summary
    }

    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try PageIndexValidation.validate([pageIndex], in: state.document)
        guard let page = state.document.page(at: pageIndex) else { return state }
        page.addAnnotation(annotation)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        RemoveAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: "Remove \(summary)")
    }
}

// MARK: - Remove

public struct RemoveAnnotationCommand: Command, @unchecked Sendable {
    public typealias State = DocumentState

    let pageIndex: Int
    let annotation: PDFAnnotation
    public let summary: String

    public init(pageIndex: Int, annotation: PDFAnnotation, summary: String = "Delete Annotation") {
        self.pageIndex = pageIndex
        self.annotation = annotation
        self.summary = summary
    }

    /// Fully reversible: undo puts the identical annotation back.
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try PageIndexValidation.validate([pageIndex], in: state.document)
        guard let page = state.document.page(at: pageIndex),
              page.annotations.contains(where: { $0 === annotation })
        else {
            throw CommandError.preconditionFailed("that annotation is no longer on page \(pageIndex + 1)")
        }
        page.removeAnnotation(annotation)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        AddAnnotationCommand(pageIndex: pageIndex, annotation: annotation, summary: summary)
    }
}

// MARK: - Update (move, resize, restyle, retype)

/// The editable properties of an annotation, captured so a change can be reversed.
public struct AnnotationAppearance: @unchecked Sendable {
    public var bounds: CGRect
    public var contents: String?
    public var font: NSFont?
    public var fontColor: NSColor?
    public var color: NSColor
    public var interiorColor: NSColor?
    public var lineWidth: CGFloat
    public var alignment: NSTextAlignment

    public init(of annotation: PDFAnnotation) {
        bounds = annotation.bounds
        contents = annotation.contents
        font = annotation.font
        fontColor = annotation.fontColor
        color = annotation.color
        interiorColor = annotation.interiorColor
        lineWidth = annotation.border?.lineWidth ?? 0
        alignment = annotation.alignment
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        annotation.contents = contents
        if let font { annotation.font = font }
        if let fontColor { annotation.fontColor = fontColor }
        annotation.color = color
        annotation.interiorColor = interiorColor
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.alignment = alignment
    }
}

/// Changes an annotation from one appearance to another.
///
/// Both ends are explicit, because the UI mutates an annotation live while it
/// is dragged; by the time this command is built, "the current state" is
/// already the destination, so the origin must be captured up front.
public struct UpdateAnnotationCommand: Command, @unchecked Sendable {
    public typealias State = DocumentState

    let pageIndex: Int
    let annotation: PDFAnnotation
    let from: AnnotationAppearance
    let to: AnnotationAppearance
    public let summary: String

    public init(pageIndex: Int, annotation: PDFAnnotation, from: AnnotationAppearance,
                to: AnnotationAppearance, summary: String) {
        self.pageIndex = pageIndex
        self.annotation = annotation
        self.from = from
        self.to = to
        self.summary = summary
    }

    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try PageIndexValidation.validate([pageIndex], in: state.document)
        guard let page = state.document.page(at: pageIndex),
              page.annotations.contains(where: { $0 === annotation })
        else {
            throw CommandError.preconditionFailed("that annotation is no longer on page \(pageIndex + 1)")
        }
        to.apply(to: annotation)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        UpdateAnnotationCommand(pageIndex: pageIndex, annotation: annotation, from: to, to: from, summary: summary)
    }
}

// MARK: - Edited text

public enum TextEdit {
    /// The tag every edited-text cover carries, so it can be told apart from ordinary text boxes.
    public static let marker = "pdf-engineer.edited-text"

    /// Builds the annotation that replaces a line of text: an opaque box in the
    /// page's background colour with the new text drawn on it.
    ///
    /// PDFKit cannot rewrite text inside a page's content stream, so editing
    /// covers the original line and draws the replacement over it. The
    /// original glyphs remain in the file underneath, which is why this is
    /// never presented as redaction.
    public static func coverAnnotation(bounds: CGRect, text: String, font: NSFont,
                                       textColor: NSColor, background: NSColor,
                                       alignment: NSTextAlignment = .left) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = textColor
        annotation.color = background
        annotation.alignment = alignment
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.userName = marker
        return annotation
    }
}
