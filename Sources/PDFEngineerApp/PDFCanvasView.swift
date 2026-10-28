import PDFKit
import SwiftUI

/// Wraps `PDFView` for SwiftUI.
///
/// There is no `PDFViewRepresentable` in the SDK — `PDFView` is
/// an `NSView`, so this bridge is mandatory rather than a shortcut. PDFKit also
/// handles scrolling, zooming, text selection, and search highlighting, all of
/// which would be weeks of work to reimplement and none of which is a
/// differentiator.
///
/// Navigation, zoom and selection go through ``CanvasBridge`` as direct calls,
/// never through view state, so a redraw can't move the reader.
struct PDFCanvasView: NSViewRepresentable {

    let document: PDFDocument
    let bridge: CanvasBridge
    let controller: AppController
    @ObservedObject var tools: ToolState

    /// Changes whenever the document mutates, forcing a refresh.
    ///
    /// `PDFDocument` mutates in place, so SwiftUI sees no value change and will
    /// not call `updateNSView` on its own.
    let revision: Int

    /// Search hits to highlight.
    let highlights: [PDFSelection]

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeNSView(context: Context) -> EditorPDFView {
        let view = EditorPDFView()
        view.controller = controller
        view.tools = tools
        view.document = document
        view.autoScales = true
        // Matches Preview's look rather than PDFKit's default flat grey.
        view.backgroundColor = .windowBackgroundColor
        view.pageShadowsEnabled = true
        bridge.pdfView = view
        context.coordinator.observe(view)
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            context.coordinator.observeScrolling(clip)
        }
        return view
    }

    func updateNSView(_ view: EditorPDFView, context: Context) {
        view.tools = tools
        if context.coordinator.lastTool != tools.tool {
            context.coordinator.lastTool = tools.tool
            view.commitEditing()
            if tools.tool != .select { view.deselect() }
            if !tools.tool.allowsTextSelection { view.clearSelection() }
        }
        view.refreshOverlay()
        // Reassigning the document resets scroll position and zoom, so only do
        // it when the document object actually changed (OCR replaces it).
        if view.document !== document {
            view.document = document
        }
        if bridge.pdfView !== view { bridge.pdfView = view }
        view.highlightedSelections = highlights.isEmpty ? nil : highlights
        // In-place edits (rotate, markup) don't trigger PDFView's own redraw.
        if context.coordinator.lastRevision != revision {
            context.coordinator.lastRevision = revision
            // Signing (and its undo) swaps in a new PDFPage object. PDFView keeps
            // drawing the page it knew, which is now detached and renders blank,
            // so reload the document and return to the same page.
            if let current = view.currentPage, document.index(for: current) == NSNotFound {
                let pageIndex = min(bridge.currentPage, max(document.pageCount - 1, 0))
                let scale = view.scaleFactor
                let autoScales = view.autoScales
                view.document = nil
                view.document = document
                view.autoScales = autoScales
                if !autoScales { view.scaleFactor = scale }
                if let page = document.page(at: pageIndex) { view.go(to: page) }
            } else {
                view.layoutDocumentView()
                view.needsDisplay = true
            }
        }
    }

    static func dismantleNSView(_ view: EditorPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        let bridge: CanvasBridge
        var lastRevision = -1
        var lastTool: ToolState.Tool = .select
        private weak var view: EditorPDFView?
        private var observers: [NSObjectProtocol] = []

        init(bridge: CanvasBridge) {
            self.bridge = bridge
        }

        func observe(_ view: EditorPDFView) {
            self.view = view
            let center = NotificationCenter.default
            // Keep the tool overlay glued to the page while scrolling and zooming,
            // and commit any text being typed (its position would go stale).
            let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.view?.commitEditing()
                    self?.view?.refreshOverlay()
                }
            }
            observers = [
                center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main, using: redraw),
                center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.bridge.pageChanged() }
                },
                center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.bridge.selectionChanged() }
                },
            ]
        }

        func observeScrolling(_ clip: NSClipView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.view?.commitEditing()
                    self?.view?.refreshOverlay()
                }
            })
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
