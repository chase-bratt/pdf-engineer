import PDFCore
import PDFKit

/// The state a ``Command`` transforms.
///
/// ## Why this wraps a mutable reference
///
/// The command model works on immutable snapshots, and the project's immutability
/// rule says never mutate inputs. `PDFDocument`, however, is a mutable
/// reference type with no value semantics and no copy-on-write, and PDFKit
/// offers no cheap structural copy — the only full copy is
/// `PDFDocument(data: document.dataRepresentation()!)`, which serialises the
/// entire file. On a 500 MB document, snapshotting on every keystroke is not
/// viable.
///
/// So the compromise is explicit rather than accidental: this type holds one
/// document reference, and **commands mutate it through their inverse**. Undo
/// correctness comes from each command knowing how to reverse itself exactly
/// (`inverse(for:)`), not from retaining a prior copy. That is why every command
/// in this module is tested for an exact round trip — the tests are carrying the
/// guarantee that structural sharing would otherwise give us for free.
///
/// `copyingDocument()` exists for the cases that genuinely need a detached
/// snapshot (autosave, export, a background render that must not see edits).
///
/// ## Concurrency
///
/// `PDFDocument` carries no concurrency annotations at all, so
/// this is `@unchecked Sendable` under a documented invariant: **one
/// `DocumentState` is owned by exactly one actor**, and the document reference
/// is never handed to another isolation domain. Background work receives
/// extracted values, never this type.
public struct DocumentState: @unchecked Sendable {

    /// The live document. Mutated only by ``Command`` implementations in this
    /// module, never by UI or MCP code directly.
    public let document: PDFDocument

    public init(document: PDFDocument) {
        self.document = document
    }

    /// A fully detached copy, for autosave, export, or background rendering.
    ///
    /// Serialises and reparses, so this is O(file size). Call it deliberately.
    ///
    /// - Throws: ``PDFCoreError/documentLoadFailed`` if the round trip fails.
    public func copyingDocument() throws -> DocumentState {
        guard let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data)
        else { throw PDFCoreError.documentLoadFailed }
        return DocumentState(document: copy)
    }
}
