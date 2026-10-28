import PDFKit

/// The single audited path for moving pages between `PDFDocument`s.
///
/// ## Why this type exists
///
/// `PDFDocument.h` carries this warning verbatim, immediately above
/// `insertPage:atIndex:`:
///
/// > when inserting a PDFPage, you have to be careful if that page came from
/// > another PDFDocument. PDFPage's have a notion of a single document that owns
/// > them and when you call the methods below the PDFPage passed in is assigned
/// > a new owning document. You'll want to call -[PDFPage copy] first then and
/// > pass this copy to the blow methods. This allows the orignal PDFPage to
/// > maintain its original document.
///
/// Inserting a page across documents therefore **reassigns ownership and damages
/// the source document**. It does not deep-copy. A merge feature built on the
/// naive call silently destroys the user's input files.
///
/// So, by design, no call site uses `insert(_:at:)`
/// directly for a cross-document move. Everything goes through here, so the
/// `copy()` can never be forgotten at one of a dozen call sites.
///
/// ## Concurrency
///
/// `PDFDocument` and `PDFPage` carry no concurrency annotations — a grep for
/// `Sendable`/`MainActor` across every PDFKit header returns zero matches
/// These methods are therefore *not* safe to call concurrently
/// on the same documents; callers confine each document to one actor and call in
/// from that isolation.
public enum PageGraft {

    /// Copies the page at `sourceIndex` out of `source` and inserts it into
    /// `destination`, leaving `source` untouched.
    ///
    /// - Parameters:
    ///   - sourceIndex: Zero-based index in `source`.
    ///   - source: The document to copy from. Not mutated.
    ///   - destination: The document to insert into.
    ///   - destinationIndex: Zero-based insertion point. May equal
    ///     `destination.pageCount` to append.
    /// - Throws: ``PDFCoreError/pageIndexOutOfRange(index:pageCount:)`` if either
    ///   index is invalid, or ``PDFCoreError/pageCopyFailed(index:)`` if the page
    ///   cannot be copied.
    public static func graft(
        pageAt sourceIndex: Int,
        from source: PDFDocument,
        into destination: PDFDocument,
        at destinationIndex: Int
    ) throws {
        let page = try copiedPage(at: sourceIndex, from: source)
        try validate(insertionIndex: destinationIndex, in: destination)
        destination.insert(page, at: destinationIndex)
    }

    /// Copies every page of `source` into `destination`, preserving order.
    ///
    /// Used by merge. Order preservation is explicit rather than incidental: each
    /// page is inserted at an advancing offset, not repeatedly at the same index
    /// (which would reverse the document).
    public static func graftAll(
        from source: PDFDocument,
        into destination: PDFDocument,
        at destinationIndex: Int
    ) throws {
        try validate(insertionIndex: destinationIndex, in: destination)

        // Copy every page up front. If any page fails to copy we throw before
        // mutating `destination` at all, so a partial merge is never left behind.
        let pages = try (0..<source.pageCount).map {
            try copiedPage(at: $0, from: source)
        }

        for (offset, page) in pages.enumerated() {
            destination.insert(page, at: destinationIndex + offset)
        }
    }

    /// Reorders a page within a single document.
    ///
    /// `exchangePageAtIndex:withPageAtIndex:` is a *swap*, not a move; using it
    /// for a drag-reorder scrambles the pages in between. This is remove+insert,
    /// which is what a reorder actually means.
    ///
    /// No cross-document ownership concern applies here, so no copy is needed —
    /// the page keeps the same owning document throughout.
    public static func move(
        pageAt sourceIndex: Int,
        to destinationIndex: Int,
        in document: PDFDocument
    ) throws {
        try validate(pageIndex: sourceIndex, in: document)
        try validate(pageIndex: destinationIndex, in: document)
        guard sourceIndex != destinationIndex else { return }

        guard let page = document.page(at: sourceIndex) else {
            throw PDFCoreError.pageIndexOutOfRange(
                index: sourceIndex, pageCount: document.pageCount
            )
        }

        document.removePage(at: sourceIndex)
        // Removing shifts every later index down by one, so a rightward move
        // needs no adjustment while the removal has already accounted for it.
        document.insert(page, at: destinationIndex)
    }

    // MARK: - Private

    /// Returns an independent copy of a page, or throws.
    private static func copiedPage(at index: Int, from document: PDFDocument) throws -> PDFPage {
        try validate(pageIndex: index, in: document)

        guard let page = document.page(at: index) else {
            throw PDFCoreError.pageIndexOutOfRange(index: index, pageCount: document.pageCount)
        }
        // The load-bearing line. `copy()` is typed `Any`, so this downcast is
        // checked rather than forced.
        guard let copy = page.copy() as? PDFPage else {
            throw PDFCoreError.pageCopyFailed(index: index)
        }
        return copy
    }

    private static func validate(pageIndex index: Int, in document: PDFDocument) throws {
        guard index >= 0, index < document.pageCount else {
            throw PDFCoreError.pageIndexOutOfRange(index: index, pageCount: document.pageCount)
        }
    }

    /// Insertion permits `pageCount` itself, which means "append".
    private static func validate(insertionIndex index: Int, in document: PDFDocument) throws {
        guard index >= 0, index <= document.pageCount else {
            throw PDFCoreError.pageIndexOutOfRange(index: index, pageCount: document.pageCount)
        }
    }
}
