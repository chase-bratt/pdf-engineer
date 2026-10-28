import DocumentModel
import PDFCore
import PDFKit
import SwiftUI

/// Main window: thumbnail sidebar, PDF canvas, toolbar, status bar.
struct RootView: View {

    @ObservedObject var controller: AppController
    @ObservedObject private var canvas: CanvasBridge

    init(controller: AppController) {
        self.controller = controller
        self.canvas = controller.canvas
    }

    var body: some View {
        Group {
            if let session = controller.session {
                documentView(session.document)
            } else {
                EmptyStateView(controller: controller)
            }
        }
        .navigationTitle(controller.documentTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $controller.showingMCPSetup) { MCPSetupView() }
        .sheet(isPresented: $controller.showingGoToPage) { GoToPageSheet(controller: controller) }
        .sheet(isPresented: $controller.showingSignatureSheet) {
            SignatureSheet(store: controller.signatures) { controller.useSignature($0) }
        }
        .background(WindowAccessor { window in
            controller.window = window
            controller.updateWindowState()
        })
        // `errorMessage` is the single funnel for failures, so one alert covers
        // every operation rather than each one inventing its own.
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private func documentView(_ document: PDFDocument) -> some View {
        VStack(spacing: 0) {
            EditToolbar(controller: controller)
            HSplitView {
                VStack(spacing: 0) {
                    Picker("Sidebar", selection: $controller.sidebarMode) {
                        ForEach(SidebarMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)

                    switch controller.sidebarMode {
                    case .thumbnails:
                        ThumbnailSidebar(
                            controller: controller,
                            canvas: canvas,
                            document: document,
                            revision: controller.revision
                        )
                    case .contents:
                        OutlineSidebar(document: document, revision: controller.revision) {
                            canvas.go(toPage: $0)
                        }
                    }
                }
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

                PDFCanvasView(
                    document: document,
                    bridge: canvas,
                    controller: controller,
                    tools: controller.tools,
                    revision: controller.revision,
                    highlights: controller.searchResults
                )
                .frame(minWidth: 400, maxWidth: .infinity)
                .layoutPriority(1)

                if controller.showingAssistant {
                    AssistantSidebar(controller: controller)
                }
            }

            StatusBar(controller: controller)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                controller.rotateSelection(by: -90)
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .disabled(!controller.hasSelection)
            .help("Rotate selected pages left")

            Button {
                controller.rotateSelection(by: 90)
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .disabled(!controller.hasSelection)
            .help("Rotate selected pages right")

            Button {
                controller.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!controller.hasSelection)
            .help("Delete selected pages")
        }

        ToolbarItemGroup {
            Menu {
                ForEach(MarkupStyle.allCases, id: \.self) { style in
                    Button(style.title) { controller.addMarkup(style) }
                }
            } label: {
                Label("Highlight", systemImage: "highlighter")
            } primaryAction: {
                controller.addMarkup(.highlight)
            }
            .disabled(!controller.canMarkUp)
            .help("Highlight the selected text (⌃⌘H); click and hold for underline and strike-through")
        }

        ToolbarItemGroup {
            Button {
                controller.runOCR()
            } label: {
                Label("OCR", systemImage: "text.viewfinder")
            }
            .disabled(!controller.hasDocument || controller.isWorking)
            .help("Make this document searchable")

            Button {
                controller.exportMarkdown()
            } label: {
                Label("Markdown", systemImage: "arrow.down.doc")
            }
            .disabled(!controller.hasDocument)
            .help("Export as Markdown for an LLM")
        }

        ToolbarItem {
            SearchField(controller: controller)
        }

        ToolbarItem {
            Button {
                controller.showingAssistant.toggle()
                // Reclaim the model's ~1GB when the sidebar is dismissed.
                if !controller.showingAssistant { controller.unloadAssistant() }
            } label: {
                Label("Assistant", systemImage: "sparkles")
            }
            .help("Ask the on-device assistant about this document")
        }
    }
}

/// Search box with match counter and next/previous (⌘G / ⇧⌘G).
private struct SearchField: View {
    @ObservedObject var controller: AppController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $controller.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focused)
                // Return on an unchanged query steps to the next match, like Preview.
                .onSubmit {
                    if controller.searchResults.isEmpty { controller.runSearch() } else { controller.nextMatch() }
                }
                .onChange(of: controller.searchQuery) { _, _ in controller.resetSearch() }
                .overlay(alignment: .trailing) {
                    if let label = controller.matchLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 6)
                            .allowsHitTesting(false)
                    }
                }
            if !controller.searchResults.isEmpty {
                ControlGroup {
                    Button { controller.previousMatch() } label: { Image(systemName: "chevron.up") }
                        .help("Previous match (⇧⌘G)")
                    Button { controller.nextMatch() } label: { Image(systemName: "chevron.down") }
                        .help("Next match (⌘G)")
                }
                .controlSize(.small)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in focused = true }
    }
}

extension Notification.Name {
    /// Posted by Find… (⌘F) to put the cursor in the search field.
    static let focusSearchField = Notification.Name("PDFEngineer.focusSearchField")
}

/// Hands the hosting `NSWindow` to the controller (for the edited dot and printing).
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shown before a document is open.
private struct EmptyStateView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("No document open")
                .font(.title2)

            Text("Open a PDF — or drop in a Word document, image, text file or web page and it converts automatically.")
                .foregroundStyle(.secondary)

            Button("Open…") { controller.openDocument() }
                .keyboardShortcut("o", modifiers: .command)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Dropping a PDF on the window is the fastest way in.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                guard ext == "pdf" || HTMLConverter.isHTML(url) || DocumentConverter.canConvert(url) else { return }
                Task { @MainActor in controller.open(url) }
            }
            return true
        }
    }
}

/// Page count, selection, and the current status message.
private struct StatusBar: View {
    @ObservedObject var controller: AppController
    @ObservedObject var canvas: CanvasBridge

    init(controller: AppController) {
        self.controller = controller
        self.canvas = controller.canvas
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(controller.currentPageLabel) { controller.showingGoToPage = true }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Go to page (⌥⌘G)")

            if !controller.selectedPages.isEmpty {
                Text("\(controller.selectedPages.count) selected")
                    .foregroundStyle(Color.accentColor)
            }

            Divider().frame(height: 12)

            if controller.isWorking {
                ProgressView().controlSize(.small)
            }

            Text(controller.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
