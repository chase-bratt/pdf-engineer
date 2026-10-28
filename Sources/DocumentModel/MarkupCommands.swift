import AppKit
import PDFCore
import PDFKit

/// Text markup a user can add over selected text.
public enum MarkupStyle: String, Sendable, CaseIterable {
    case highlight, underline, strikeOut

    var annotationSubtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        }
    }

    public var title: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeOut: return "Strike Through"
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .highlight: return NSColor.systemYellow.withAlphaComponent(0.5)
        case .underline: return .systemBlue
        case .strikeOut: return .systemRed
        }
    }
}

/// One line of selected text: the page it is on and its bounds in page space.
public struct MarkupLine: Sendable, Equatable {
    public let pageIndex: Int
    public let bounds: CGRect

    public init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        self.bounds = bounds
    }
}

/// Adds highlight, underline or strike-out annotations, one per selected line.
///
/// Every annotation it creates carries a unique tag in `userName`, so undo
/// removes exactly these annotations and never the user's existing ones.
public struct AddMarkupCommand: Command {
    public typealias State = DocumentState

    public static let tagPrefix = "pdf-engineer.markup."

    let style: MarkupStyle
    let lines: [MarkupLine]
    let tag: String

    public init(style: MarkupStyle, lines: [MarkupLine], tag: String = UUID().uuidString) {
        self.style = style
        self.lines = lines.filter { !$0.bounds.isEmpty }
        self.tag = Self.tagPrefix + tag
    }

    public var summary: String { style.title }
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        guard !lines.isEmpty else {
            throw CommandError.preconditionFailed("select some text first")
        }
        try PageIndexValidation.validate(lines.map(\.pageIndex), in: state.document)
        for line in lines {
            guard let page = state.document.page(at: line.pageIndex) else { continue }
            let annotation = PDFAnnotation(bounds: line.bounds, forType: style.annotationSubtype, withProperties: nil)
            annotation.color = style.defaultColor
            annotation.userName = tag
            page.addAnnotation(annotation)
        }
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        RemoveTaggedAnnotationsCommand(tag: tag, summary: "Remove \(style.title)")
    }
}

/// Removes the annotations a markup command added, identified by tag.
struct RemoveTaggedAnnotationsCommand: Command {
    typealias State = DocumentState

    let tag: String
    let summary: String
    var isDestructive: Bool { false }

    func apply(to state: DocumentState) throws -> DocumentState {
        for index in 0..<state.document.pageCount {
            guard let page = state.document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == tag {
                page.removeAnnotation(annotation)
            }
        }
        return state
    }

    func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // Only ever used as an undo; redo replays the original AddMarkupCommand.
        throw CommandError.preconditionFailed("markup removal cannot be redone directly")
    }
}
