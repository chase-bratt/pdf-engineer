import DocumentModel
import Foundation
import PDFCore
import PDFKit

/// Replaces text by covering the original and drawing the replacement over it.
///
/// ## Why it works this way
///
/// PDFKit cannot edit text, and a true
/// in-place edit means tokenising the content stream, mapping glyphs back
/// through font encodings, re-shaping with a possibly-subsetted font that may
/// not even contain the new characters, and re-flowing the lines after. That is
/// a much larger piece of work.
///
/// This is the simplest approach instead: redact-and-overlay. Draw an opaque rectangle over
/// the old text, then draw the new text on top. Honest properties:
///
/// - It always works, on any PDF, with no font archaeology.
/// - The replacement will not match the original's font exactly.
/// - The old glyphs are **painted over, not removed**. The original text is
///   still extractable from the content stream underneath.
///
/// That last point is why this type is **not** a redaction tool and says so.
/// Real redaction removes bytes and is a separate feature.
public struct ReplaceTextCommand: Command, @unchecked Sendable {
    public typealias State = DocumentState

    let find: String
    let replacement: String

    /// Marks every annotation this command creates, so undo removes exactly
    /// those — not the user's own FreeText notes, and not the output of another
    /// replacement that happens to use the same text.
    ///
    /// Generated once, in `init`, and stored: redo re-applies the *same*
    /// command, so the re-created annotations carry the same tag and the next
    /// undo still finds them.
    let tag: String

    /// Prefix shared by all replacement tags, stored in `PDFAnnotation.userName`.
    static let tagPrefix = "pdf-engineer.replace."

    /// Replacement text size as a fraction of the covered box height.
    ///
    /// Slightly under 1 so descenders are not clipped by the cover rectangle.
    private let sizeRatio: CGFloat = 0.8

    public init(find: String, replacement: String) {
        self.init(find: find, replacement: replacement, tag: Self.tagPrefix + UUID().uuidString)
    }

    init(find: String, replacement: String, tag: String) {
        self.find = find
        self.replacement = replacement
        self.tag = tag
    }

    public var summary: String {
        "Replace \"\(find)\" with \"\(replacement)\""
    }

    /// Paints over existing content, so it is destructive.
    public var isDestructive: Bool { true }

    public func apply(to state: DocumentState) throws -> DocumentState {
        let matches = state.document.findString(find, withOptions: [.caseInsensitive])
        guard !matches.isEmpty else {
            throw CommandError.preconditionFailed("\"\(find)\" was not found in this document")
        }

        // Group by page so each page is annotated once.
        var byPage: [Int: [CGRect]] = [:]
        for match in matches {
            for page in match.pages {
                let index = state.document.index(for: page)
                byPage[index, default: []].append(match.bounds(for: page))
            }
        }

        for (pageIndex, boxes) in byPage {
            guard let page = state.document.page(at: pageIndex) else { continue }
            for box in boxes {
                // A FreeText annotation, rather than drawing into the content
                // stream: annotations are what PDFKit can actually add, they
                // round-trip through save/load, and they are individually
                // removable — which is what makes undo exact.
                let annotation = PDFAnnotation(
                    bounds: box,
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = replacement
                // `userName` (the /T entry) round-trips through save and is
                // not otherwise used for FreeText, so it carries the tag.
                annotation.userName = tag
                annotation.color = .white                 // opaque cover
                annotation.fontColor = .black
                annotation.font = .systemFont(ofSize: max(box.height * sizeRatio, 6))
                // No border: a box around replaced text looks like a defect.
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 0
                page.addAnnotation(annotation)
            }
        }
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // Undo removes exactly the annotations this command is about to add,
        // identified by this command's tag.
        RemoveReplacementsCommand(find: find, replacement: replacement, tag: tag)
    }
}

/// Removes the overlay annotations added by ``ReplaceTextCommand``.
struct RemoveReplacementsCommand: Command, @unchecked Sendable {
    typealias State = DocumentState

    let find: String
    let replacement: String
    let tag: String

    init(find: String, replacement: String, tag: String) {
        self.find = find
        self.replacement = replacement
        self.tag = tag
    }

    var summary: String { "Undo replacement" }
    var isDestructive: Bool { false }

    func apply(to state: DocumentState) throws -> DocumentState {
        for index in 0..<state.document.pageCount {
            guard let page = state.document.page(at: index) else { continue }
            // Only annotations carrying this command's tag — so a user's own
            // notes, and other replacements, are never collateral damage.
            for annotation in page.annotations where annotation.userName == tag {
                page.removeAnnotation(annotation)
            }
        }
        return state
    }

    func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // Re-running the original replacement, with the same tag, so a later
        // undo still identifies its annotations. The search lands in the same
        // places for an unchanged document.
        ReplaceTextCommand(find: find, replacement: replacement, tag: tag)
    }
}
