import CoreGraphics
import Foundation
import PDFKit

/// Bakes annotations into page content.
///
/// ## Why this exists
///
/// Highlights, text boxes, ink and placed signatures live in a page's
/// `/Annots` array, not in its content stream. Any viewer can hide, move or
/// delete them, and some (form-filling services, print drivers, older readers)
/// silently drop them. Flattening redraws each page — content *and*
/// annotations — into a fresh PDF, so what was visible becomes permanent.
///
/// ## How
///
/// `PDFPage.draw(with:to:)` renders the page the way PDFKit displays it:
/// annotation appearances included, the page's `/Rotate` applied, and the crop
/// box mapped to the origin (all verified empirically). Drawing into a
/// `CGContext` PDF context keeps text as glyphs, so the result stays
/// selectable and searchable rather than becoming a raster. The new pages are
/// built from nothing, so they carry no `/Annots` at all.
public enum PDFFlattener {

    /// Returns a flattened copy of `document`.
    ///
    /// Each output page has the size and orientation of the *visible* source
    /// page — its crop box, with 90°/270° rotations already applied — so the
    /// output carries no `/Rotate` and looks identical in every viewer. The
    /// outline (bookmarks) is rebuilt by page index.
    ///
    /// - Throws: ``PDFCoreError/documentLoadFailed`` for a locked or empty
    ///   document, ``PDFCoreError/contextCreationFailed`` if drawing fails.
    public static func flattenedData(from document: PDFDocument) throws -> Data {
        // A locked document draws blank pages; failing is better than
        // returning a "flattened" file with nothing on it.
        guard !document.isLocked, document.pageCount > 0 else {
            throw PDFCoreError.documentLoadFailed
        }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw PDFCoreError.pageCopyFailed(index: index)
            }
            var mediaBox = CGRect(origin: .zero, size: visibleSize(of: page))
            context.beginPage(mediaBox: &mediaBox)
            page.draw(with: .cropBox, to: context)
            context.endPage()
        }
        context.closePDF()

        guard let flattened = PDFDocument(data: output as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        if let root = document.outlineRoot {
            flattened.outlineRoot = OutlineCopier.copy(root, from: document, to: flattened)
        }
        guard let data = flattened.dataRepresentation() else {
            throw PDFCoreError.contextCreationFailed
        }
        return data
    }

    /// The crop box size as the reader sees it, i.e. after `/Rotate`.
    static func visibleSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).standardized
        let quarterTurns = ((page.rotation / 90) % 4 + 4) % 4
        return quarterTurns % 2 == 0
            ? box.size
            : CGSize(width: box.height, height: box.width)
    }
}
