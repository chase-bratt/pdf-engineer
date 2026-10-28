import Foundation
import PDFKit

/// Writes PDFs without ever leaving a half-written file at the destination.
///
/// ## Why not `PDFDocument.write(to:)` directly
///
/// PDFKit reads a document *lazily* from its file. Writing over that same file
/// in place means PDFKit may still be pulling page data from bytes it is busy
/// overwriting, and a failure part-way (full disk, crash) destroys the user's
/// original. So every save goes to a temporary file in the destination's own
/// directory — same volume, so the final step is a rename, not a copy — and
/// only a complete file is swapped into place.
public enum AtomicPDFWriter {

    /// Writes `document` to `destination`, replacing any existing file only
    /// once the new one is complete.
    ///
    /// - Throws: ``PDFCoreError/writeFailed(path:)`` if the document cannot be
    ///   serialised or moved into place. The destination is untouched on error.
    public static func write(_ document: PDFDocument, to destination: URL) throws {
        let temporary = temporaryURL(near: destination)
        guard document.write(to: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw PDFCoreError.writeFailed(path: destination.path)
        }
        try moveIntoPlace(temporary, at: destination)
    }

    /// Moves a completed temporary file to `destination`, replacing atomically
    /// when a file is already there. Removes `temporary` on failure.
    public static func moveIntoPlace(_ temporary: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                // replaceItemAt swaps via rename and keeps the destination's
                // metadata; any reader holding the old file keeps its inode.
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw PDFCoreError.writeFailed(path: destination.path)
        }
    }

    /// A hidden, unique sibling of `destination` for staging a write.
    ///
    /// Same directory, so the final move cannot cross volumes.
    public static func temporaryURL(near destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).pdfeng-\(UUID().uuidString).tmp"
        )
    }

    /// Whether two paths name the same file.
    ///
    /// Compares standardised, symlink-resolved paths, and — when both exist —
    /// file identity, which also catches hard links and case-insensitive
    /// spellings (`In.pdf` vs `in.pdf` on APFS).
    public static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath()
        let b = second.standardizedFileURL.resolvingSymlinksInPath()
        if a.path == b.path { return true }

        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }

    /// The first of `base-suffix.pdf`, `base-suffix-2.pdf`, … that does not exist.
    ///
    /// Used where output names are chosen for the user, so an existing file is
    /// never silently overwritten.
    public static func uniqueURL(nextTo source: URL, suffix: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let name = attempt == 1 ? "\(base)-\(suffix).pdf" : "\(base)-\(suffix)-\(attempt).pdf"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }

    /// Writes `document` to the first free `base-suffix[-N].pdf` beside
    /// `source` and returns where it went. Never replaces an existing file.
    ///
    /// The final step is `moveItem`, which fails rather than overwrites if a
    /// file appeared since the name was chosen, so a race costs a retry, not
    /// someone's data.
    public static func writeNew(_ document: PDFDocument, nextTo source: URL, suffix: String) throws -> URL {
        let directory = source.deletingLastPathComponent()
        let temporary = temporaryURL(near: source)
        guard document.write(to: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw PDFCoreError.writeFailed(path: directory.path)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        for _ in 0..<1000 {
            let candidate = uniqueURL(nextTo: source, suffix: suffix)
            do {
                try FileManager.default.moveItem(at: temporary, to: candidate)
                return candidate
            } catch where FileManager.default.fileExists(atPath: candidate.path) {
                continue
            } catch {
                throw PDFCoreError.writeFailed(path: candidate.path)
            }
        }
        throw PDFCoreError.writeFailed(path: directory.path)
    }

    /// Writes `data` to `destination`, which must not exist yet.
    ///
    /// For outputs derived from untrusted input (HTML conversion), where
    /// replacing whatever sits at the destination is never what was meant.
    /// Two properties matter:
    ///
    /// - **Never overwrites.** The bytes are staged in a temporary sibling and
    ///   moved into place with `renamex_np(RENAME_EXCL)`, which fails if
    ///   anything is at `destination`. Unlike `fileExists` then `moveItem`,
    ///   there is no window in which a file can appear and be clobbered.
    /// - **Never follows a symlink.** A rename replaces the directory entry
    ///   itself; it does not write through a link, so a symlink planted at
    ///   `destination` (even a dangling one) makes the write fail instead of
    ///   redirecting it somewhere else.
    ///
    /// - Throws: ``PDFCoreError/destinationExists(path:)`` if anything is at
    ///   `destination`, else ``PDFCoreError/writeFailed(path:)``. The temporary
    ///   file is removed either way.
    public static func writeNew(_ data: Data, to destination: URL) throws {
        let temporary = temporaryURL(near: destination)
        do {
            // `.withoutOverwriting` is O_EXCL: the staging file is ours alone.
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw PDFCoreError.writeFailed(path: destination.path)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        // errno is captured inside the closure, before anything else can
        // overwrite it.
        let failure = temporary.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch failure {
        case 0: return
        case EEXIST: throw PDFCoreError.destinationExists(path: destination.path)
        default: throw PDFCoreError.writeFailed(path: destination.path)
        }
    }

    /// A new document holding copies of the given pages, in the given order.
    ///
    /// Built on ``PageGraft`` so the source document is never damaged by a
    /// cross-document insert.
    public static func extract(pages indices: [Int], from source: PDFDocument) throws -> PDFDocument {
        let output = PDFDocument()
        for index in indices {
            try PageGraft.graft(pageAt: index, from: source, into: output, at: output.pageCount)
        }
        return output
    }
}
