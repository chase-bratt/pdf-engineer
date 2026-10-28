import PDFCore
import PDFKit

// Page organization commands — the app's core workflow.
//
// Each is a ``Command``, so each is undoable, audit-logged, and reachable from
// the MCP tool surface with no extra plumbing.

// MARK: - Rotate

/// Rotates one or more pages by a relative angle.
public struct RotatePagesCommand: Command {
    public typealias State = DocumentState

    let pageIndices: [Int]
    let degrees: Int

    /// Largest accepted magnitude. Ten full turns is far beyond any real
    /// request; the cap exists so arbitrary input can never reach integer
    /// overflow in the angle arithmetic.
    public static let maxDegrees = 3600

    /// - Parameters:
    ///   - pageIndices: Zero-based page indices to rotate.
    ///   - degrees: Relative rotation. Normalised to 0/90/180/270, so 450 and
    ///     -270 both mean 90.
    ///
    /// Non-throwing so existing call sites keep compiling; an invalid angle is
    /// rejected by `apply`/`inverse` before anything changes. Use
    /// ``init(validatingPageIndices:degrees:)`` to fail at construction.
    public init(pageIndices: [Int], degrees: Int) {
        self.pageIndices = pageIndices
        self.degrees = degrees
    }

    /// Validating initialiser: throws ``RotationError`` for an angle that is
    /// not a multiple of 90 within ±``maxDegrees``.
    public init(validatingPageIndices pageIndices: [Int], degrees: Int) throws {
        try Self.validate(degrees: degrees)
        self.init(pageIndices: pageIndices, degrees: degrees)
    }

    /// Throws unless `degrees` is a multiple of 90 within ±``maxDegrees``.
    ///
    /// PDF `/Rotate` only allows multiples of 90; PDFKit silently accepts
    /// anything and then renders garbage, so the check lives here, once.
    public static func validate(degrees: Int) throws {
        guard degrees % 90 == 0, (-maxDegrees...maxDegrees).contains(degrees) else {
            throw RotationError.invalidDegrees(degrees)
        }
    }

    public var summary: String {
        let noun = pageIndices.count == 1 ? "Page" : "Pages"
        return "Rotate \(pageIndices.count) \(noun)"
    }

    /// Rotation is reversible and loses nothing.
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        // Validate the angle and every index before touching anything, so bad
        // input cannot leave a half-rotated document behind.
        try Self.validate(degrees: degrees)
        try PageIndexValidation.validate(pageIndices, in: state.document)

        for index in pageIndices {
            guard let page = state.document.page(at: index) else {
                throw PDFCoreError.pageIndexOutOfRange(
                    index: index, pageCount: state.document.pageCount
                )
            }
            // Normalise each operand first so the sum stays tiny whatever the
            // stored rotation is.
            page.rotation = Self.normalize(Self.normalize(page.rotation) + Self.normalize(degrees))
        }
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // Runs before `apply`, so this is where an invalid angle is caught first.
        try Self.validate(degrees: degrees)
        return RotatePagesCommand(pageIndices: pageIndices, degrees: -degrees)
    }

    /// PDFKit accepts arbitrary integers but only renders multiples of 90, and
    /// a stored 450 would confuse later arithmetic. Normalise at the boundary.
    ///
    /// `%` never overflows, so this is safe for any `Int`, including `.min`.
    static func normalize(_ degrees: Int) -> Int {
        let wrapped = degrees % 360
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

/// Rejected rotation input.
public enum RotationError: Error, Equatable, Sendable, LocalizedError {
    case invalidDegrees(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidDegrees(degrees):
            return "Cannot rotate by \(degrees)°: rotation must be a multiple of 90 between "
                + "-\(RotatePagesCommand.maxDegrees) and \(RotatePagesCommand.maxDegrees). "
                + "Use 90 (clockwise), 180, or -90 (counter-clockwise)."
        }
    }
}

// MARK: - Delete

/// Deletes one or more pages, retaining them so undo can restore them exactly.
public struct DeletePagesCommand: Command {
    public typealias State = DocumentState

    let pageIndices: [Int]

    public init(pageIndices: [Int]) {
        self.pageIndices = pageIndices
    }

    public var summary: String {
        let noun = pageIndices.count == 1 ? "Page" : "Pages"
        return "Delete \(pageIndices.count) \(noun)"
    }

    /// Destroys content, so it requires explicit per-call consent
    /// whenever this originates from Claude.
    public var isDestructive: Bool { true }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try PageIndexValidation.validate(pageIndices, in: state.document)

        // A zero-page PDF is not a valid document. Refuse rather than produce one.
        let remaining = state.document.pageCount - Set(pageIndices).count
        guard remaining > 0 else {
            throw CommandError.preconditionFailed(
                "a document must keep at least one page"
            )
        }

        // Descending order, so each removal cannot shift the indices still to
        // be removed.
        for index in Set(pageIndices).sorted(by: >) {
            state.document.removePage(at: index)
        }
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        try PageIndexValidation.validate(pageIndices, in: state.document)

        // Capture the actual pages *before* deletion. Copies, so a later edit
        // to the live document cannot mutate what undo will restore.
        let restores: [RestorePagesCommand.Entry] = try Set(pageIndices).sorted().map { index in
            guard let page = state.document.page(at: index),
                  let copy = page.copy() as? PDFPage
            else { throw PDFCoreError.pageCopyFailed(index: index) }
            return .init(index: index, page: copy)
        }
        return RestorePagesCommand(entries: restores)
    }
}

/// Reinserts previously deleted pages at their original indices.
///
/// Internal: produced only as ``DeletePagesCommand``'s inverse, never applied
/// directly by UI or MCP code.
struct RestorePagesCommand: Command {
    typealias State = DocumentState

    /// A captured page and the index it must return to.
    ///
    /// `@unchecked Sendable` under the same invariant as ``DocumentState``:
    /// these pages are detached copies owned solely by the actor that owns the
    /// document, and are never read from another isolation domain.
    struct Entry: @unchecked Sendable {
        let index: Int
        let page: PDFPage
    }

    let entries: [Entry]

    var summary: String {
        let noun = entries.count == 1 ? "Page" : "Pages"
        return "Restore \(entries.count) \(noun)"
    }

    var isDestructive: Bool { false }

    func apply(to state: DocumentState) throws -> DocumentState {
        // Ascending, so each insertion lands at its original index once the
        // earlier ones are back in place.
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            guard entry.index <= state.document.pageCount else {
                throw PDFCoreError.pageIndexOutOfRange(
                    index: entry.index, pageCount: state.document.pageCount
                )
            }
            guard let copy = entry.page.copy() as? PDFPage else {
                throw PDFCoreError.pageCopyFailed(index: entry.index)
            }
            state.document.insert(copy, at: entry.index)
        }
        return state
    }

    func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        DeletePagesCommand(pageIndices: entries.map(\.index))
    }
}

// MARK: - Move

/// Moves a single page within the document.
public struct MovePageCommand: Command {
    public typealias State = DocumentState

    let from: Int
    let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    public var summary: String { "Move Page \(from + 1) to \(to + 1)" }
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        // PageGraft.move is remove+insert, not exchange — an exchange would
        // scramble the pages in between.
        try PageGraft.move(pageAt: from, to: to, in: state.document)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        MovePageCommand(from: to, to: from)
    }
}

// MARK: - Merge

/// Inserts every page of another document at a given index.
///
/// `@unchecked Sendable`: `PDFDocument` carries no concurrency annotations
/// The invariant is that `incoming` is confined to the actor
/// that applies this command, and `apply` copies out of it rather than
/// retaining a reference in the destination.
public struct MergeDocumentCommand: Command, @unchecked Sendable {
    public typealias State = DocumentState

    let incoming: PDFDocument
    let at: Int

    public init(incoming: PDFDocument, at index: Int) {
        self.incoming = incoming
        self.at = index
    }

    public var summary: String {
        "Merge \(incoming.pageCount) \(incoming.pageCount == 1 ? "Page" : "Pages")"
    }

    /// Adds content without destroying any, and is fully reversible.
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try requireIncomingPages()
        // graftAll copies, so the incoming document is never aliased into ours.
        try PageGraft.graftAll(from: incoming, into: state.document, at: at)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        // An empty merge would produce DeletePagesCommand([]) as its inverse,
        // which always throws — leaving an entry that can never be undone and
        // jamming everything beneath it. Refuse up front instead.
        try requireIncomingPages()
        // Undo removes exactly the range we are about to add.
        return DeletePagesCommand(pageIndices: Array(at..<(at + incoming.pageCount)))
    }

    private func requireIncomingPages() throws {
        guard incoming.pageCount > 0 else {
            throw CommandError.preconditionFailed(
                "the document to merge has no pages, so there is nothing to add"
            )
        }
    }
}

// MARK: - Shared validation

enum PageIndexValidation {
    /// Throws unless every index is within the document and the list is non-empty.
    static func validate(_ indices: [Int], in document: PDFDocument) throws {
        guard !indices.isEmpty else {
            throw CommandError.preconditionFailed("no pages were specified")
        }
        for index in indices {
            guard index >= 0, index < document.pageCount else {
                throw PDFCoreError.pageIndexOutOfRange(
                    index: index, pageCount: document.pageCount
                )
            }
        }
    }
}
