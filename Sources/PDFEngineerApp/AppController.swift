import AppKit
import DocumentModel
import Assistant
import Export
import OCR
import PDFCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the open document and drives every user action.
///
/// Every mutation goes through ``DocumentSession/apply(_:origin:)``, so undo and
/// the audit log see all of it — including, later, the MCP server's edits.
@MainActor
final class AppController: ObservableObject {

    @Published private(set) var session: DocumentSession?

    /// Pages selected in the thumbnail sidebar, as zero-based indices.
    @Published var selectedPages: Set<Int> = []

    /// Bumped whenever the document changes, to force the views to re-read it.
    ///
    /// `PDFDocument` is a reference type that mutates in place, so SwiftUI has
    /// nothing to diff — there is no value change for it to notice. An explicit
    /// revision counter is the simplest honest signal.
    @Published private(set) var revision = 0

    @Published var searchQuery = ""
    @Published var searchResults: [PDFSelection] = []
    /// Index into `searchResults` of the match last revealed (⌘G / ⇧⌘G).
    @Published var currentMatch: Int?

    /// The live PDF view: navigation, zoom and text selection.
    let canvas = CanvasBridge()

    /// The active editing tool and its font/colour settings.
    let tools = ToolState()

    /// Saved signatures, and whether the signature picker is showing.
    let signatures = SignatureStore()
    @Published var showingSignatureSheet = false

    /// Shows the page-selection checkboxes in the sidebar.
    @Published var pageSelectMode = false

    /// Which list the left sidebar shows.
    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var showingGoToPage = false

    /// Anchor for ⇧-click range selection in the thumbnail sidebar.
    var selectionAnchor: Int?

    /// The main window, for the "edited" dot and sheet-style alerts.
    weak var window: NSWindow?

    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = ""
    @Published var errorMessage: String?

    /// Presents the Claude/MCP setup sheet.
    @Published var showingMCPSetup = false

    // MARK: - Assistant (on-device LLM)

    @Published var showingAssistant = false
    @Published var chatInput = ""
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var assistantIsThinking = false
    @Published private(set) var assistantStatus: LocalLLM.Status = .notLoaded

    /// The model, loaded lazily on first use so launch stays fast and the ~1GB
    /// is not paid for by users who never open the sidebar.
    private let llm = LocalLLM()

    var assistantStatusLabel: String {
        switch assistantStatus {
        case .notLoaded:   return "idle"
        case .loading:     return "loading model…"
        case .ready:       return "on-device"
        case .unavailable: return "unavailable"
        }
    }

    // MARK: - Derived state for the menus

    var hasDocument: Bool { session != nil }
    var hasSelection: Bool { !selectedPages.isEmpty && hasDocument }
    var canUndo: Bool { session?.canUndo ?? false }
    var canRedo: Bool { session?.canRedo ?? false }
    var pageCount: Int { session?.pageCount ?? 0 }

    var documentTitle: String { session?.displayName ?? "PDF Engineer" }

    var undoTitle: String {
        session?.undoSummary.map { "Undo \($0)" } ?? "Undo"
    }

    var redoTitle: String {
        session?.redoSummary.map { "Redo \($0)" } ?? "Redo"
    }

    // MARK: - Opening

    func openDocument() {
        let panel = NSOpenPanel()
        // HTML is a first-class input: saving a webpage as HTML is much faster
        // than printing it to PDF, so we convert on open instead.
        panel.allowedContentTypes = [.pdf, .html] + Self.convertibleTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Opens a PDF, or converts and opens an HTML file.
    func open(_ url: URL) {
        guard confirmDiscardingChanges() else { return }
        if HTMLConverter.isHTML(url) {
            convertAndOpen(html: url)
            return
        }
        if DocumentConverter.canConvert(url) {
            convertAndOpen(document: url)
            return
        }
        do {
            session = try DocumentSession(contentsOf: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            selectedPages = []
            selectionAnchor = nil
            resetSearch()
            revision += 1
            updateWindowState()
            status("Opened \(url.lastPathComponent) — \(session?.pageCount ?? 0) pages")
        } catch {
            fail(error)
        }
    }

    /// Makes a freshly opened or converted document the current one.
    func adopt(_ newSession: DocumentSession, from url: URL) {
        session = newSession
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        selectedPages = []
        selectionAnchor = nil
        tools.selectedAnnotation = nil
        resetSearch()
        revision += 1
        updateWindowState()
    }

    /// Converts an HTML file to PDF and opens the result.
    ///
    /// The PDF lands next to the source so the conversion is not thrown away —
    /// the usual reason to drop an HTML file here is to keep a PDF of it.
    private func convertAndOpen(html url: URL) {
        isWorking = true
        status("Converting \(url.lastPathComponent)…")

        Task {
            do {
                let converter = HTMLConverter()
                let data = try await converter.convert(fileAt: url)

                let destination = url.deletingPathExtension().appendingPathExtension("pdf")
                let target = try Self.availableURL(for: destination)
                // Slices the single tall page WebKit produces into sheets.
                try HTMLConverter.write(data, to: target)

                session = try DocumentSession(contentsOf: target)
                NSDocumentController.shared.noteNewRecentDocumentURL(target)
                selectedPages = []
                selectionAnchor = nil
                resetSearch()
                revision += 1
                updateWindowState()
                isWorking = false
                status("Converted to \(target.lastPathComponent) — \(session?.pageCount ?? 0) pages")
            } catch {
                isWorking = false
                fail(error)
            }
        }
    }

    /// Returns `url`, or `name-2.pdf`, `name-3.pdf`… so a conversion never
    /// silently overwrites an existing file.
    static func availableURL(for url: URL) throws -> URL {
        let manager = FileManager.default
        // `fileExists` follows symlinks, so also treat a dangling link as taken.
        func taken(_ candidate: URL) -> Bool {
            manager.fileExists(atPath: candidate.path)
                || (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) != nil
        }
        guard taken(url) else { return url }

        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        for suffix in 2...99 {
            let candidate = directory
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(ext)
            if !taken(candidate) { return candidate }
        }
        // Never fall back to the original name: it exists, and writing to it
        // could follow a planted symlink and destroy an unrelated file.
        throw CocoaError(.fileWriteFileExists, userInfo: [
            NSLocalizedDescriptionKey: "There are already 99 converted copies of \(url.lastPathComponent) here. Move some of them and try again."
        ])
    }

    /// Writes new bytes without ever replacing an existing file or following a
    /// symlink at the destination: stage in a temp file, then move (which fails
    /// rather than overwrite).
    static func writeNewFile(_ data: Data, to destination: URL) throws {
        let staging = AtomicPDFWriter.temporaryURL(near: destination)
        try data.write(to: staging, options: [.withoutOverwriting])
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Saving

    func save() {
        guard let session else { return }
        do {
            if session.url == nil {
                saveAs()
            } else {
                try session.save()
                status("Saved")
                revision += 1
                updateWindowState()
            }
        } catch {
            fail(error)
        }
    }

    func saveAs() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.displayName).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.save(to: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            status("Saved to \(url.lastPathComponent)")
            revision += 1
            updateWindowState()
        } catch {
            fail(error)
        }
    }

    // MARK: - Undo

    func undo() {
        guard let session else { return }
        do {
            try session.undo()
            afterMutation("Undid")
        } catch {
            fail(error)
        }
    }

    func redo() {
        guard let session else { return }
        do {
            try session.redo()
            afterMutation("Redid")
        } catch {
            fail(error)
        }
    }

    // MARK: - Page operations

    func rotateSelection(by degrees: Int) {
        guard let session, !selectedPages.isEmpty else { return }
        apply(RotatePagesCommand(pageIndices: Array(selectedPages), degrees: degrees), on: session)
    }

    func deleteSelection() {
        guard let session, !selectedPages.isEmpty else { return }
        let indices = Array(selectedPages)
        // Clear the selection first: the pages it refers to are about to stop
        // existing, and a stale selection would point at the wrong pages.
        selectedPages = []
        apply(DeletePagesCommand(pageIndices: indices), on: session)
    }

    func movePage(from source: Int, to destination: Int) {
        guard let session else { return }
        apply(MovePageCommand(from: source, to: destination), on: session)
    }

    func mergeDocument() {
        guard let session else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let incoming = PDFDocument(url: url) else { return }

        apply(
            MergeDocumentCommand(incoming: incoming, at: session.pageCount),
            on: session
        )
    }

    /// Writes the selected pages to a new file, leaving this document alone.
    func extractSelection() {
        guard let session, !selectedPages.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.displayName)-extract.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let extracted = PDFDocument()
        do {
            for (offset, index) in selectedPages.sorted().enumerated() {
                // PageGraft copies, so the source document is never aliased
                // into the extract.
                try PageGraft.graft(
                    pageAt: index, from: session.document,
                    into: extracted, at: offset
                )
            }
            guard extracted.write(to: url) else { throw PDFCoreError.documentLoadFailed }
            status("Extracted \(selectedPages.count) pages")
        } catch {
            fail(error)
        }
    }

    // MARK: - OCR

    func runOCR() {
        guard let session, !isWorking else { return }
        // OCR reads the file on disk and replaces the document with the result,
        // so unsaved edits would be silently lost. Save them first, or stop.
        if session.hasUnsavedChanges || session.url == nil {
            guard confirmSaveBeforeOCR(), !session.hasUnsavedChanges, session.url != nil else { return }
        }
        guard let source = session.url else { return }

        isWorking = true
        status("Preparing OCR…")

        Task {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("ocr-\(UUID().uuidString).pdf")
            do {
                let result = try await OCRPipeline.addTextLayer(
                    from: source, to: output,
                    onProgress: { [weak self] progress in
                        self?.status(
                            "OCR page \(progress.pageIndex + 1) of \(progress.pageCount)"
                        )
                    }
                )
                guard let ocred = PDFDocument(url: output) else {
                    throw OCRError.documentLoadFailed
                }
                // The OCR pass writes a whole new file, so this replaces the
                // document rather than applying a Command — and that clears
                // undo, since the old commands no longer describe this document.
                // The user may have opened another file while OCR ran.
                guard self.session === session else {
                    isWorking = false
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                session.replaceDocument(with: ocred)
                revision += 1
                isWorking = false
                updateWindowState()
                status(
                    "OCR complete — \(result.pagesProcessed) pages processed, "
                    + "\(result.pagesSkipped) already had text, "
                    + "\(result.runsWritten) text runs added"
                )
            } catch {
                isWorking = false
                fail(error)
            }
            try? FileManager.default.removeItem(at: output)
        }
    }

    // MARK: - Export

    func exportMarkdown() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.displayName).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let markdown = MarkdownExporter.markdown(
                from: session.document, filename: session.displayName
            )
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            status("Exported Markdown (\(markdown.count) characters)")
        } catch {
            fail(error)
        }
    }

    func exportJSON() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.displayName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let ast = MarkdownExporter.buildAST(
                from: session.document, filename: session.displayName
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ast).write(to: url)
            status("Exported DocAST — \(ast.blocks.count) blocks")
        } catch {
            fail(error)
        }
    }

    // MARK: - Search

    func runSearch() {
        guard let session else { return }
        searchResults = session.search(searchQuery)
        currentMatch = nil
        if searchResults.isEmpty {
            status(searchQuery.isEmpty ? "" : "No matches")
        } else {
            nextMatch()
        }
    }

    // MARK: - Assistant

    /// Sends the current input to the model and acts on what comes back.
    func sendChatMessage() {
        let request = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let session else { return }

        chatInput = ""
        chatMessages.append(ChatMessage(role: .user, text: request))
        assistantIsThinking = true

        Task {
            let intent = await llm.intent(for: request, pageCount: session.pageCount)
            assistantStatus = await llm.status
            assistantIsThinking = false
            handle(intent, on: session)
        }
    }

    /// Runs an intent, or asks for confirmation first.
    private func handle(_ intent: Intent, on session: DocumentSession) {
        // Destructive actions are described and confirmed before they run, so
        // the model can never quietly delete pages.
        if intent.needsConfirmation {
            let message = ChatMessage(
                role: .assistant,
                text: "\(intent.summary)?",
                pendingIntent: intent
            )
            let revisionAtRequest = revision
            message.onConfirm = { [weak self] confirmed in
                guard let self else { return }
                // Page numbers in the request describe the document as it was;
                // after any edit they may name different pages.
                guard self.revision == revisionAtRequest else {
                    self.chatMessages.append(ChatMessage(
                        role: .assistant,
                        text: "The document changed since I suggested that, so I didn't run it. Ask me again."
                    ))
                    return
                }
                // The page numbers were read from *this* document; if another file
                // has been opened since, running them would hit the wrong pages.
                guard self.session === session else {
                    self.chatMessages.append(ChatMessage(
                        role: .assistant,
                        text: "That request was for a document that's no longer open, so I didn't run it."
                    ))
                    return
                }
                self.run(confirmed, on: session, confirmed: true)
            }
            message.onCancel = { [weak self] in
                self?.chatMessages.append(ChatMessage(role: .assistant, text: "Cancelled."))
            }
            chatMessages.append(message)
            return
        }
        run(intent, on: session, confirmed: false)
    }

    private func run(_ intent: Intent, on session: DocumentSession, confirmed: Bool) {
        // OCR is the one intent the executor cannot perform itself: it needs a
        // file path and runs for a long time, so the controller owns it.
        if case .runOCR = intent {
            chatMessages.append(ChatMessage(role: .assistant, text: "Starting OCR…"))
            runOCR()
            return
        }
        if case .exportMarkdown = intent {
            chatMessages.append(ChatMessage(role: .assistant, text: "Choose where to save…"))
            exportMarkdown()
            return
        }

        let outcome = IntentExecutor.execute(intent, on: session, confirmed: confirmed)
        chatMessages.append(ChatMessage(role: .assistant, text: outcome.message))

        if !outcome.selectPages.isEmpty { selectedPages = Set(outcome.selectPages) }
        if let page = outcome.scrollToPage { canvas.go(toPage: page) }
        if outcome.didMutate {
            revision += 1
            updateWindowState()
        }
    }

    /// Frees the model's ~1GB when the sidebar closes.
    func unloadAssistant() {
        Task { await llm.unload(); assistantStatus = await llm.status }
    }

    // MARK: - Private

    func apply(_ command: some Command<DocumentState>, on session: DocumentSession) {
        // OCR replaces the whole document when it finishes; an edit made while
        // it runs would be thrown away, so refuse rather than lose it.
        guard !isWorking else {
            errorMessage = "Wait for the current operation to finish before editing."
            return
        }
        do {
            try session.apply(command)
            afterMutation(command.summary)
        } catch {
            fail(error)
        }
    }

    func afterMutation(_ what: String) {
        revision += 1
        updateWindowState()
        // A stale selection can outlive the pages it names.
        if let session { selectedPages = selectedPages.filter { $0 < session.pageCount } }
        status(what)
    }

    func status(_ message: String) {
        statusMessage = message
    }

    func fail(_ error: Error) {
        // LocalizedError gives the actionable text; `error.localizedDescription`
        // alone degrades to a type name for plain Swift errors.
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}
