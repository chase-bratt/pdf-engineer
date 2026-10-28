import DocumentModel
import Foundation
import PDFCore
import PDFKit

/// Executes an ``Intent`` against a document.
///
/// This is the half the model does not touch. Everything here is ordinary
/// tested code, and every mutation goes through ``DocumentSession/apply(_:origin:)``
/// so it lands in the undo stack and the audit log labelled `.assistant` —
/// the same guarantee the MCP layer gives.
@MainActor
public enum IntentExecutor {

    /// What happened, for display in the chat transcript.
    public struct Outcome: Sendable {
        /// Text to show the user.
        public let message: String
        /// A page to scroll to, if the intent implies one.
        public let scrollToPage: Int?
        /// Pages the UI should select, if any.
        public let selectPages: [Int]
        /// Whether the document changed.
        public let didMutate: Bool

        init(
            message: String,
            scrollToPage: Int? = nil,
            selectPages: [Int] = [],
            didMutate: Bool = false
        ) {
            self.message = message
            self.scrollToPage = scrollToPage
            self.selectPages = selectPages
            self.didMutate = didMutate
        }
    }

    /// Runs an intent.
    ///
    /// - Parameter confirmed: Whether the user has approved a mutating action.
    ///   Intents needing confirmation refuse to run without it rather than
    ///   asking again here, so the UI owns the prompt.
    public static func execute(
        _ intent: Intent,
        on session: DocumentSession,
        confirmed: Bool = false
    ) -> Outcome {
        if intent.needsConfirmation, !confirmed {
            return Outcome(message: "Confirm: \(intent.summary)?")
        }

        switch intent {
        case let .search(query):
            return search(query, in: session)

        case let .count(query):
            let hits = session.search(query)
            return Outcome(
                message: hits.isEmpty
                    ? "\"\(query)\" does not appear in this document."
                    : "\"\(query)\" appears \(hits.count) time\(hits.count == 1 ? "" : "s")."
            )

        case let .goToPage(page):
            // -1 means "last", which is how the prompt teaches the model to
            // express it.
            // The parser bounds `page`, but this is checked before any
            // arithmetic too, so an Intent built elsewhere cannot trap here.
            guard session.pageCount > 0,
                  page == -1 || (1...session.pageCount).contains(page)
            else {
                return Outcome(
                    message: "This document has \(session.pageCount) pages, so page \(page) does not exist."
                )
            }
            let index = page == -1 ? session.pageCount - 1 : page - 1
            return Outcome(message: "Page \(index + 1).", scrollToPage: index)

        case let .replace(find, replacement):
            return replace(find, with: replacement, in: session)

        case let .rotate(pages, degrees):
            return rotate(pages: pages, degrees: degrees, in: session)

        case let .deletePages(pages):
            return delete(pages: pages, in: session)

        case .documentInfo:
            return info(session)

        case .exportMarkdown:
            // The UI owns the save panel, so this is a request, not an action.
            return Outcome(message: "Use File ▸ Export as Markdown… to choose where to save.")

        case .runOCR:
            return Outcome(message: "Starting OCR. This runs in the background.", didMutate: false)

        case let .unsupported(reason):
            return Outcome(message: reason)
        }
    }

    // MARK: - Read

    private static func search(_ query: String, in session: DocumentSession) -> Outcome {
        let hits = session.search(query)
        guard !hits.isEmpty else {
            return Outcome(message: "No matches for \"\(query)\".")
        }

        let pages = hits.compactMap { hit -> Int? in
            guard let page = hit.pages.first else { return nil }
            return session.document.index(for: page)
        }
        let unique = Array(Set(pages)).sorted()
        let pageList = unique.prefix(10).map { String($0 + 1) }.joined(separator: ", ")
        let more = unique.count > 10 ? " and \(unique.count - 10) more" : ""

        return Outcome(
            message: "\(hits.count) match\(hits.count == 1 ? "" : "es") on page\(unique.count == 1 ? "" : "s") \(pageList)\(more).",
            scrollToPage: unique.first,
            selectPages: unique
        )
    }

    private static func info(_ session: DocumentSession) -> Outcome {
        let withText = (0..<session.pageCount).filter {
            !session.text(onPage: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        var lines = ["\(session.displayName): \(session.pageCount) pages."]
        if withText < session.pageCount {
            lines.append(
                "\(session.pageCount - withText) page(s) have no text layer — OCR would make them searchable."
            )
        }
        if session.hasUnsavedChanges { lines.append("There are unsaved changes.") }
        return Outcome(message: lines.joined(separator: " "))
    }

    // MARK: - Mutate

    private static func replace(
        _ find: String,
        with replacement: String,
        in session: DocumentSession
    ) -> Outcome {
        let hits = session.search(find)
        guard !hits.isEmpty else {
            return Outcome(message: "\"\(find)\" was not found, so nothing was changed.")
        }

        do {
            try session.apply(
                ReplaceTextCommand(find: find, replacement: replacement),
                origin: .assistant
            )
            return Outcome(
                message: """
                    Replaced \(hits.count) occurrence\(hits.count == 1 ? "" : "s") of \
                    "\(find)" with "\(replacement)". Note: the replacement is drawn over the \
                    original, which is still present underneath — this is not redaction. \
                    Undo with ⌘Z.
                    """,
                didMutate: true
            )
        } catch {
            return Outcome(message: failure(error))
        }
    }

    private static func rotate(
        pages: [Int],
        degrees: Int,
        in session: DocumentSession
    ) -> Outcome {
        // Validated as 1-based numbers *before* converting: `Int.min - 1`
        // traps, so subtracting first would crash on a hostile page number.
        if let bad = pages.first(where: { !(1...max(session.pageCount, 1)).contains($0) }) {
            return Outcome(
                message: "Page \(bad) does not exist — this document has \(session.pageCount) pages."
            )
        }
        // An empty page list means every page, per the Intent contract.
        let indices = pages.isEmpty
            ? Array(0..<session.pageCount)
            : pages.map { $0 - 1 }

        guard let bad = indices.first(where: { $0 < 0 || $0 >= session.pageCount }) else {
            do {
                try session.apply(
                    RotatePagesCommand(pageIndices: indices, degrees: degrees),
                    origin: .assistant
                )
                return Outcome(
                    message: "Rotated \(indices.count) page(s) by \(degrees)°. Undo with ⌘Z.",
                    selectPages: indices,
                    didMutate: true
                )
            } catch {
                return Outcome(message: failure(error))
            }
        }
        return Outcome(
            message: "Page \(bad + 1) does not exist — this document has \(session.pageCount) pages."
        )
    }

    private static func delete(pages: [Int], in session: DocumentSession) -> Outcome {
        // Range-checked as 1-based numbers before subtracting, for the same
        // overflow reason as `rotate`.
        if let bad = pages.first(where: { !(1...max(session.pageCount, 1)).contains($0) }) {
            return Outcome(
                message: "Page \(bad) does not exist — this document has \(session.pageCount) pages."
            )
        }
        let indices = pages.map { $0 - 1 }

        do {
            try session.apply(DeletePagesCommand(pageIndices: indices), origin: .assistant)
            return Outcome(
                message: "Deleted \(indices.count) page(s). \(session.pageCount) remain. Undo with ⌘Z.",
                didMutate: true
            )
        } catch {
            return Outcome(message: failure(error))
        }
    }

    private static func failure(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
