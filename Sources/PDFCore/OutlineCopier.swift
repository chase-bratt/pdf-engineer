import Foundation
import PDFKit

/// Rebuilds a document outline (bookmarks) against another document's pages.
///
/// An outline item's destination points at a `PDFPage` *object*, not a page
/// number. When a document is regenerated — OCR re-renders every page into a
/// new file — those page objects no longer exist, so the outline cannot simply
/// be reassigned: it has to be rebuilt by page *index*, which is the one thing
/// the two documents share.
public enum OutlineCopier {

    /// Returns a fresh outline tree mirroring `root`, with every destination
    /// retargeted from `source`'s pages to the page at the same index in
    /// `destination`. Items whose page has no counterpart keep their label but
    /// lose their destination, rather than pointing into the wrong document.
    public static func copy(
        _ root: PDFOutline,
        from source: PDFDocument,
        to destination: PDFDocument
    ) -> PDFOutline {
        let copy = PDFOutline()
        copy.label = root.label
        copy.isOpen = root.isOpen

        if let target = root.destination,
           let retargeted = retarget(target, from: source, to: destination) {
            copy.destination = retargeted
        } else if let action = root.action, !(action is PDFActionGoTo),
                  let actionCopy = action.copy() as? PDFAction {
            // URL and named actions reference no page, so they copy as-is.
            copy.action = actionCopy
        }

        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index) else { continue }
            copy.insertChild(
                Self.copy(child, from: source, to: destination),
                at: copy.numberOfChildren
            )
        }
        return copy
    }

    private static func retarget(
        _ target: PDFDestination,
        from source: PDFDocument,
        to destination: PDFDocument
    ) -> PDFDestination? {
        guard let page = target.page else { return nil }
        let index = source.index(for: page)
        guard index != NSNotFound, let newPage = destination.page(at: index) else { return nil }
        return PDFDestination(page: newPage, at: target.point)
    }
}
