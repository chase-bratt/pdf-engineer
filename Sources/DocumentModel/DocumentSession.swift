import Foundation
import PDFCore
import PDFKit

/// Owns one open document and serialises every mutation through it.
///
/// PDFKit carries no concurrency
/// annotations, so each `PDFDocument` is confined to one isolation domain and
/// never shared. Making this `@MainActor` rather than a bespoke actor is a
/// deliberate simplification — PDFKit's views are main-thread anyway, so a
/// separate actor would mean hopping back for every UI read with no safety
/// gained. Long work (OCR, export) runs off-main and returns *values*, which is
/// where the real concurrency boundary belongs.
///
/// This is the single funnel the UI and the MCP server both call, so the audit
/// log and undo stack see every change.
@MainActor
public final class DocumentSession {

    private var stack: CommandStack<DocumentState>

    /// Where the document lives on disk, once known.
    public private(set) var url: URL?

    /// The stack version last written to disk, or nil if the current
    /// document has never been saved in its present form.
    private var savedVersion: Int?

    /// Whether there are changes not yet written to disk.
    ///
    /// Derived from the undo position rather than set on every edit, so
    /// undoing back to the saved state reports clean, and redoing (or making
    /// a new edit) reports dirty again.
    public var hasUnsavedChanges: Bool { stack.stateVersion != savedVersion }

    public init(document: PDFDocument, url: URL? = nil) {
        let stack = CommandStack(initial: DocumentState(document: document))
        self.stack = stack
        self.url = url
        self.savedVersion = stack.stateVersion
    }

    public convenience init(contentsOf url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw PDFCoreError.documentLoadFailed
        }
        self.init(document: document, url: url)
    }

    // MARK: - Reading

    public var document: PDFDocument { stack.state.document }
    public var pageCount: Int { document.pageCount }

    public var displayName: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    public var canUndo: Bool { stack.canUndo }
    public var canRedo: Bool { stack.canRedo }
    public var undoSummary: String? { stack.undoSummary }
    public var redoSummary: String? { stack.redoSummary }

    /// The audit log — every change, with its origin.
    public var history: [CommandRecord] { stack.history }

    public func page(at index: Int) -> PDFPage? { document.page(at: index) }

    /// Plain text of a page, for export and the MCP `get_page_text` tool.
    public func text(onPage index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    public func search(_ query: String) -> [PDFSelection] {
        guard !query.isEmpty else { return [] }
        return document.findString(query, withOptions: [.caseInsensitive])
    }

    // MARK: - Mutating

    /// Applies a command. The only way to change the document.
    public func apply(
        _ command: some Command<DocumentState>,
        origin: CommandOrigin = .user
    ) throws {
        try stack.apply(command, origin: origin)
    }

    public func undo() throws {
        try stack.undo()
    }

    public func redo() throws {
        try stack.redo()
    }

    // MARK: - Saving

    /// Writes to the document's existing location.
    ///
    /// - Throws: ``SessionError/noFileLocation`` for a document that has
    ///   never been saved (use ``save(to:)``), or
    ///   ``PDFCoreError/writeFailed(path:)``.
    public func save() throws {
        guard let url else { throw SessionError.noFileLocation }
        try save(to: url)
    }

    /// Writes to a new location and adopts it.
    ///
    /// Atomic: the bytes go to a temporary sibling first and are swapped in
    /// only when complete. Writing in place would overwrite the file PDFKit
    /// may still be reading pages from lazily, and a failure part-way would
    /// destroy the original.
    public func save(to destination: URL) throws {
        try AtomicPDFWriter.write(document, to: destination)
        url = destination
        savedVersion = stack.stateVersion
    }

    /// Replaces the document wholesale — used after an out-of-band rewrite such
    /// as the OCR pass, which produces a new file rather than mutating in place.
    ///
    /// Clears undo history, because the commands in it no longer describe this
    /// document. Pretending otherwise would let undo corrupt the result.
    public func replaceDocument(with replacement: PDFDocument) {
        stack = CommandStack(initial: DocumentState(document: replacement))
        // The replacement exists only in memory until saved.
        savedVersion = nil
    }
}

/// Errors from ``DocumentSession`` itself, as opposed to its commands.
public enum SessionError: Error, Equatable, Sendable, LocalizedError {
    /// `save()` was called on a document that has no file yet.
    case noFileLocation

    public var errorDescription: String? {
        switch self {
        case .noFileLocation:
            return "This document has not been saved yet. Choose a location with Save As."
        }
    }
}
