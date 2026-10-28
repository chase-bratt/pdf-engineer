import AppKit
import SwiftUI

/// App entry point.
///
/// Uses `WindowGroup` plus our own open/save commands rather than SwiftUI's
/// `DocumentGroup`. `DocumentGroup` wants to own the document lifecycle through
/// `FileDocument`/`ReferenceFileDocument`, which assumes a value-type or
/// `ObservableObject` document it can copy and diff. Our document is a
/// `PDFDocument` behind an actor-confined session with its own undo stack
/// and audit log, so letting SwiftUI own it would mean fighting two
/// lifecycles. Explicit commands are less magic and less code.
@main
struct PDFEngineerApp: App {

    @StateObject private var controller = AppController()

    /// Owns the AppKit delegate, which handles files opened from Finder.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window, one document: the controller holds a single session, so a
        // single-instance `Window` (not `WindowGroup`) guarantees "Open With" and
        // Finder double-clicks reuse it instead of spawning duplicates.
        Window("PDF Engineer", id: "main") {
            RootView(controller: controller)
                // Hand the controller to the delegate once SwiftUI has built
                // it, so an "Open With" at launch can reach it.
                .onAppear {
                    AppDelegate.controller = controller
                    #if DEBUG
                    DebugSelfTest.runIfRequested(controller: controller)
                    #endif
                }
                // A pro document app should not open at a postage-stamp size.
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 880)
        .windowToolbarStyle(.unified)
        .commands {
            FileCommands(controller: controller)
            EditCommands(controller: controller)
            PageCommandsMenu(controller: controller)
            FindCommands(controller: controller)
            ViewCommands(controller: controller)
            AnnotateCommands(controller: controller)
            ToolsCommands(tools: controller.tools)
            CommandGroup(after: .sidebar) {
                Button("Toggle Assistant") {
                    controller.showingAssistant.toggle()
                    if !controller.showingAssistant { controller.unloadAssistant() }
                }
                .keyboardShortcut("l", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Connect Claude…") { controller.showingMCPSetup = true }
            }
        }
    }
}

/// File menu: open, save, export.
struct FileCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { controller.openDocument() }
                .keyboardShortcut("o", modifiers: .command)

            Button("Create PDF from Files…") { controller.createPDFFromFiles() }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Menu("Open Recent") {
                ForEach(controller.recentDocuments, id: \.self) { url in
                    Button(url.lastPathComponent) { controller.open(url) }
                }
                Divider()
                Button("Clear Menu") { controller.clearRecentDocuments() }
                    .disabled(controller.recentDocuments.isEmpty)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { controller.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!controller.hasDocument)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { controller.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!controller.hasDocument)

            Button("Save As…") { controller.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!controller.hasDocument)

            Divider()

            Button("Export as Markdown…") { controller.exportMarkdown() }
                .disabled(!controller.hasDocument)

            Button("Export as JSON (DocAST)…") { controller.exportJSON() }
                .disabled(!controller.hasDocument)

            Button("Export as PDF (Flattened)…") { controller.exportFlattenedPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!controller.hasDocument)

            Button("Export Reduced Size…") { controller.exportReducedSize() }
                .disabled(!controller.hasDocument)
        }
    }
}

/// Edit menu: undo and redo, labelled with what they will do.
struct EditCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // The label comes from the command's own `summary`, so the menu and
            // Claude's consent prompt can never disagree.
            Button(controller.undoTitle) { controller.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!controller.canUndo)

            Button(controller.redoTitle) { controller.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!controller.canRedo)
        }
    }
}

/// Page organisation — the app's core workflow.
struct PageCommandsMenu: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandMenu("Pages") {
            Button("Select All Pages") { controller.selectAllPages() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!controller.hasDocument)

            Divider()

            Button("Insert Blank Page") { controller.insertBlankPage() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!controller.hasDocument)

            Button("Insert from File…") { controller.insertFromFile() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!controller.hasDocument)

            Button("Duplicate Selected Pages") { controller.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!controller.hasSelection)

            Divider()

            Button("Rotate Left") { controller.rotateSelection(by: -90) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!controller.hasSelection)

            Button("Rotate Right") { controller.rotateSelection(by: 90) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!controller.hasSelection)

            Divider()

            Button("Delete Selected Pages") { controller.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!controller.hasSelection)

            Divider()

            Button("Merge PDF…") { controller.mergeDocument() }
                .disabled(!controller.hasDocument)

            Button("Extract Selected Pages…") { controller.extractSelection() }
                .disabled(!controller.hasSelection)

            Divider()

            Button("Make Searchable (OCR)") { controller.runOCR() }
                .disabled(!controller.hasDocument || controller.isWorking)
        }
    }
}

/// Edit ▸ Find: ⌘F, ⌘G, ⇧⌘G.
struct FindCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { NotificationCenter.default.post(name: .focusSearchField, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Find Next") { controller.nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(controller.searchQuery.isEmpty)
            Button("Find Previous") { controller.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(controller.searchQuery.isEmpty)
        }
    }
}

/// View: zoom, page layout, sidebar, go to page.
struct ViewCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Zoom In") { controller.canvas.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Zoom Out") { controller.canvas.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Actual Size") { controller.canvas.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Zoom to Fit") { controller.canvas.fitWidth() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!controller.hasDocument)

            Divider()

            Picker("Page Layout", selection: Binding(
                get: { controller.canvas.layout },
                set: { controller.canvas.layout = $0 }
            )) {
                ForEach(CanvasBridge.Layout.allCases) { Text($0.title).tag($0) }
            }

            Divider()

            Button("Page Thumbnails") { controller.sidebarMode = .thumbnails }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Table of Contents") { controller.sidebarMode = .contents }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Go to Page…") { controller.showingGoToPage = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!controller.hasDocument)

            Divider()
        }
    }
}

/// Annotate: text markup over the current selection (Preview's shortcuts).
struct AnnotateCommands: Commands {
    @ObservedObject var controller: AppController

    var body: some Commands {
        CommandMenu("Annotate") {
            Button("Highlight") { controller.addMarkup(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .control])
            Button("Underline") { controller.addMarkup(.underline) }
                .keyboardShortcut("u", modifiers: [.command, .control])
            Button("Strike Through") { controller.addMarkup(.strikeOut) }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

/// Tools menu. The single-letter shortcuts (V, E, T, D, R, N) are handled by
/// the page view itself, so they never fire while you're typing in a field.
struct ToolsCommands: Commands {
    @ObservedObject var tools: ToolState

    var body: some Commands {
        CommandMenu("Tools") {
            Picker("Tool", selection: $tools.tool) {
                ForEach(ToolState.Tool.allCases) { tool in
                    Text(tool.key.map { "\(tool.title)  (\(String($0.character).uppercased()))" } ?? tool.title).tag(tool)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
