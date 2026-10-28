import Foundation

/// Errors raised by the PDF object layer.
///
/// Every case carries enough context to produce an actionable message — the MCP
/// surface needs structured, actionable errors a model can act on, and those
/// messages originate here rather than being invented at the boundary.
public enum PDFCoreError: Error, Equatable, Sendable {

    /// A page index fell outside a document's range.
    case pageIndexOutOfRange(index: Int, pageCount: Int)

    /// `PDFPage.copy()` returned something that was not a `PDFPage`.
    ///
    /// `copy()` is typed `Any`, so the downcast can fail in principle. Treating
    /// that as an error rather than force-unwrapping is what keeps a malformed
    /// page from crashing the app.
    case pageCopyFailed(index: Int)

    /// A document could not be parsed.
    case documentLoadFailed

    /// A `CGContext` for PDF output could not be created.
    case contextCreationFailed

    /// A document could not be written to `path`.
    ///
    /// Distinct from ``documentLoadFailed`` so a full disk or a read-only
    /// folder is not misreported as a corrupt input file.
    case writeFailed(path: String)

    /// An operation would overwrite its own input file.
    case outputIsInput(path: String)

    /// A write that must create a new file found something already at `path`
    /// — a file, folder or symbolic link — and left it alone.
    case destinationExists(path: String)
}

extension PDFCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .pageIndexOutOfRange(index, pageCount):
            // 1-based in the message: users and LLMs both think in page numbers.
            return "Page \(index + 1) is outside the document's range of 1–\(pageCount)."
        case let .pageCopyFailed(index):
            return "Page \(index + 1) could not be copied; it may be malformed."
        case .documentLoadFailed:
            return "The document could not be opened. It may be corrupt or not a PDF."
        case .contextCreationFailed:
            return "A PDF drawing context could not be created."
        case let .writeFailed(path):
            return "The document could not be saved to \(path). Check that the folder exists, is writable, and has free space."
        case let .outputIsInput(path):
            return "The output path is the same file as the input (\(path)). Choose a different output file."
        case let .destinationExists(path):
            return "\(path) already exists, so nothing was written. Choose a different output name, or move the existing file away first."
        }
    }
}
