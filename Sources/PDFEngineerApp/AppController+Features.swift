import AppKit
import DocumentModel
import PDFCore
import PDFKit
import UniformTypeIdentifiers

/// What the left sidebar lists.
enum SidebarMode: String, CaseIterable, Identifiable {
    case thumbnails, contents
    var id: String { rawValue }
    var title: String { self == .thumbnails ? "Pages" : "Contents" }
}

// MARK: - Find navigation

extension AppController {

    /// "3 of 12" for the search field, or nil when there is nothing to step through.
    var matchLabel: String? {
        guard !searchResults.isEmpty else { return nil }
        let position = (currentMatch ?? -1) + 1
        return position > 0 ? "\(position) of \(searchResults.count)" : "\(searchResults.count) matches"
    }

    func resetSearch() {
        searchResults = []
        currentMatch = nil
    }

    func nextMatch() { stepMatch(by: 1) }
    func previousMatch() { stepMatch(by: -1) }

    private func stepMatch(by step: Int) {
        guard !searchResults.isEmpty else {
            if !searchQuery.isEmpty { runSearch() }
            return
        }
        let count = searchResults.count
        let next = ((currentMatch ?? (step > 0 ? -1 : 0)) + step + count) % count
        currentMatch = next
        canvas.reveal(searchResults[next])
        status("Match \(next + 1) of \(count)")
    }
}

// MARK: - Unsaved changes

extension AppController {

    var hasUnsavedChanges: Bool { session?.hasUnsavedChanges ?? false }

    /// Shows the "edited" dot in the close button, like any Mac document app.
    func updateWindowState() {
        window?.isDocumentEdited = hasUnsavedChanges
        if let url = session?.url { window?.representedURL = url }
    }

    /// Asks whether to save before the current document is replaced or closed.
    /// - Returns: false if the user cancelled, so the caller must stop.
    func confirmDiscardingChanges() -> Bool {
        guard let session, session.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(session.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !session.hasUnsavedChanges
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// OCR works from the saved file, so unsaved edits must be saved first.
    func confirmSaveBeforeOCR() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save before making this document searchable?"
        alert.informativeText = "OCR works from the saved file. Save now so your recent changes are included."
        alert.addButton(withTitle: "Save and Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        save()
        return true
    }
}

// MARK: - Markup

extension AppController {

    var canMarkUp: Bool { hasDocument && canvas.hasTextSelection }

    /// Highlights, underlines or strikes through the text selected in the canvas.
    func addMarkup(_ style: MarkupStyle) {
        guard let session, let selection = canvas.currentSelection else {
            errorMessage = "Select some text on the page first."
            return
        }
        let lines: [MarkupLine] = selection.selectionsByLine().flatMap { line in
            line.pages.map { page in
                MarkupLine(pageIndex: session.document.index(for: page), bounds: line.bounds(for: page))
            }
        }
        apply(AddMarkupCommand(style: style, lines: lines), on: session)
        canvas.clearSelection()
    }
}

// MARK: - Inserting pages

extension AppController {

    /// Where new pages go: after the last selected page, or at the end.
    var insertionIndex: Int {
        selectedPages.max().map { $0 + 1 } ?? pageCount
    }

    func insertBlankPage() {
        guard let session else { return }
        let index = insertionIndex
        apply(InsertBlankPageCommand(at: index), on: session)
        selectedPages = [index]
        canvas.go(toPage: index)
    }

    func duplicateSelection() {
        guard let session, !selectedPages.isEmpty else { return }
        let count = selectedPages.count
        let start = (selectedPages.max() ?? 0) + 1
        apply(DuplicatePagesCommand(pageIndices: Array(selectedPages)), on: session)
        selectedPages = Set(start..<(start + count))
    }

    /// Inserts every page of the given PDFs at `index`, in order, as one undo step each.
    func insertFiles(_ urls: [URL], at index: Int) {
        guard let session else { return }
        var position = index
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            guard let incoming = PDFDocument(url: url), incoming.pageCount > 0 else {
                errorMessage = "“\(url.lastPathComponent)” could not be opened as a PDF."
                continue
            }
            apply(MergeDocumentCommand(incoming: incoming, at: position), on: session)
            position += incoming.pageCount
        }
        if position > index {
            selectedPages = Set(index..<position)
            canvas.go(toPage: index)
        }
    }

    /// Insert from File… — puts the chosen PDFs after the selection.
    func insertFromFile() {
        guard hasDocument else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls, at: insertionIndex)
    }
}

// MARK: - Selection

extension AppController {

    /// Click, ⌘-click and ⇧-click semantics from Finder.
    func clickPage(_ index: Int, command: Bool, shift: Bool) {
        if shift, let anchor = selectionAnchor {
            let range = Set(min(anchor, index)...max(anchor, index))
            selectedPages = command ? selectedPages.union(range) : range
        } else if command {
            if selectedPages.contains(index) { selectedPages.remove(index) } else { selectedPages.insert(index) }
            selectionAnchor = index
        } else {
            selectedPages = [index]
            selectionAnchor = index
        }
        canvas.go(toPage: index)
    }

    func selectAllPages() {
        guard pageCount > 0 else { return }
        selectedPages = Set(0..<pageCount)
        selectionAnchor = 0
    }

    /// Arrow keys in the sidebar: move (or with ⇧, extend) the selection.
    func moveSelection(by step: Int, extending: Bool) {
        guard pageCount > 0 else { return }
        let current = step > 0 ? (selectedPages.max() ?? -1) : (selectedPages.min() ?? pageCount)
        let target = min(max(current + step, 0), pageCount - 1)
        if extending, let anchor = selectionAnchor {
            selectedPages = Set(min(anchor, target)...max(anchor, target))
        } else {
            selectedPages = [target]
            selectionAnchor = target
        }
        canvas.go(toPage: target)
    }
}

// MARK: - Go to page, print, recent files

extension AppController {

    var currentPageLabel: String {
        guard pageCount > 0 else { return "" }
        return "Page \(min(canvas.currentPage, pageCount - 1) + 1) of \(pageCount)"
    }

    func goToPage(_ number: Int) {
        guard number >= 1, number <= pageCount else {
            errorMessage = "Choose a page between 1 and \(pageCount)."
            return
        }
        canvas.go(toPage: number - 1)
    }

    func printDocument() {
        guard let session else { return }
        let info = NSPrintInfo.shared
        guard let operation = session.document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        else {
            errorMessage = "This document can't be printed."
            return
        }
        operation.jobTitle = session.displayName
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    var recentDocuments: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        objectWillChange.send()
    }
}

// MARK: - Reduced-size export

extension AppController {

    /// Writes a smaller copy (JPEG-recompressed, screen-resolution images),
    /// leaving the open document and its file untouched.
    func exportReducedSize() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.displayName)-small.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let source = session.url, source.standardizedFileURL == url.standardizedFileURL {
            errorMessage = "Choose a different name: the reduced copy can't replace the original."
            return
        }

        let before = session.document.dataRepresentation()?.count ?? 0
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard session.document.write(to: url, withOptions: options) else {
            errorMessage = "The reduced copy couldn't be written to \(url.lastPathComponent)."
            return
        }
        let after = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let format = ByteCountFormatter()
        status("Saved \(url.lastPathComponent): \(format.string(fromByteCount: Int64(before))) → \(format.string(fromByteCount: Int64(after)))")
    }
}

// MARK: - Editing tools

extension AppController {

    /// Applies an edit built by a canvas tool.
    func perform(_ command: some Command<DocumentState>) {
        guard let session else { return }
        apply(command, on: session)
    }

    /// Stamps a signature into the page (baked into the content so it survives saving).
    func placeSignature(_ image: NSImage, in rect: CGRect, pageIndex: Int) {
        guard let png = image.pngData() else {
            errorMessage = "That signature image couldn't be prepared."
            return
        }
        perform(StampImageCommand(pageIndex: pageIndex, rect: rect, imagePNG: png, summary: "Sign"))
        tools.tool = .select
    }

    /// Called when a signature is chosen in the sheet: arm the Sign tool with it.
    func useSignature(_ image: NSImage) {
        tools.pendingSignature = image
        tools.tool = .sign
        showingSignatureSheet = false
        status("Click or drag on the page to place your signature.")
    }

    /// Applies the tool bar's font settings to the selected text box.
    func restyleSelectedText() {
        guard let selected = tools.selectedAnnotation,
              selected.annotation.object.type == "FreeText" else { return }
        let annotation = selected.annotation.object
        let before = AnnotationAppearance(of: annotation)
        var after = before
        after.font = tools.font
        after.fontColor = tools.nsTextColor
        after.alignment = tools.alignment
        guard after.font != before.font || after.fontColor != before.fontColor || after.alignment != before.alignment
        else { return }
        perform(UpdateAnnotationCommand(pageIndex: selected.pageIndex, annotation: annotation,
                                        from: before, to: after, summary: "Format Text"))
    }

    /// Applies the tool bar's stroke/fill/width to the selected shape or drawing.
    func restyleSelectedShape() {
        guard let selected = tools.selectedAnnotation else { return }
        let annotation = selected.annotation.object
        guard ["Square", "Circle", "Line", "Ink"].contains(annotation.type ?? "") else { return }
        let before = AnnotationAppearance(of: annotation)
        var after = before
        after.color = tools.nsStrokeColor
        after.lineWidth = CGFloat(tools.lineWidth)
        if annotation.type == "Square" || annotation.type == "Circle" { after.interiorColor = tools.nsFillColor }
        guard after.color != before.color || after.lineWidth != before.lineWidth || after.interiorColor != before.interiorColor
        else { return }
        perform(UpdateAnnotationCommand(pageIndex: selected.pageIndex, annotation: annotation,
                                        from: before, to: after, summary: "Format Shape"))
    }

    func deleteSelectedAnnotation() {
        guard let selected = tools.selectedAnnotation else { return }
        perform(RemoveAnnotationCommand(pageIndex: selected.pageIndex, annotation: selected.annotation.object))
        tools.selectedAnnotation = nil
    }
}

// MARK: - Converting other documents to PDF

extension AppController {

    /// Everything the converter can turn into a PDF (Word, RTF, OpenDocument, text, images).
    static var convertibleTypes: [UTType] {
        DocumentConverter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Converts a Word document, image, text file… and opens the resulting PDF,
    /// saved next to the original so the conversion isn't thrown away.
    func convertAndOpen(document url: URL) {
        status("Converting \(url.lastPathComponent)…")
        do {
            let data = try DocumentConverter.pdfData(from: url)
            let target = try Self.availableURL(for: url.deletingPathExtension().appendingPathExtension("pdf"))
            try Self.writeNewFile(data, to: target)
            openConverted(target, from: url.lastPathComponent)
        } catch {
            fail(error)
        }
    }

    /// Combines any mix of PDFs, documents and images into one new PDF.
    func createPDFFromFiles() {
        guard confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf] + Self.convertibleTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose documents and images to combine into one PDF, in the order you want them."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".pdf"
            : "Combined.pdf"
        guard save.runModal() == .OK, let target = save.url else { return }
        do {
            let data = try DocumentConverter.pdfData(combining: urls)
            try data.write(to: target, options: .atomic)
            openConverted(target, from: "\(urls.count) files")
        } catch {
            fail(error)
        }
    }

    private func openConverted(_ target: URL, from source: String) {
        do {
            adopt(try DocumentSession(contentsOf: target), from: target)
            status("Converted \(source) → \(target.lastPathComponent) — \(pageCount) page\(pageCount == 1 ? "" : "s")")
        } catch {
            fail(error)
        }
    }

    /// Writes a copy with every edit, signature and markup baked into the pages,
    /// so it looks the same in any PDF viewer and can't be un-annotated.
    func exportFlattenedPDF() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.displayName)-final.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let source = session.url, source.standardizedFileURL == url.standardizedFileURL {
            errorMessage = "Choose a different name: the exported copy can't replace the file you're editing."
            return
        }
        do {
            let data = try PDFFlattener.flattenedData(from: session.document)
            try data.write(to: url, options: .atomic)
            status("Exported \(url.lastPathComponent)")
        } catch {
            fail(error)
        }
    }
}
