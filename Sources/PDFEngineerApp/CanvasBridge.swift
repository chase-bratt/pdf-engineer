import PDFKit
import SwiftUI

/// The app's handle on the live `PDFView`.
///
/// Navigation used to be a `scrollTarget` value passed down through SwiftUI,
/// which `updateNSView` re-applied on every redraw — so any edit or search
/// threw the reader back to the last page they had clicked. Navigation is an
/// *event*, not state, so it goes through this object as a direct call instead.
@MainActor
final class CanvasBridge: ObservableObject {

    enum Layout: String, CaseIterable, Identifiable {
        case continuous, singlePage, twoUp

        var id: String { rawValue }

        var title: String {
            switch self {
            case .continuous: return "Continuous Scroll"
            case .singlePage: return "Single Page"
            case .twoUp: return "Two Pages"
            }
        }

        var mode: PDFDisplayMode {
            switch self {
            case .continuous: return .singlePageContinuous
            case .singlePage: return .singlePage
            case .twoUp: return .twoUpContinuous
            }
        }
    }

    weak var pdfView: PDFView? {
        didSet { applyLayout() }
    }

    /// Zero-based index of the page currently in view.
    @Published private(set) var currentPage = 0
    /// Whether the reader has text selected on the page (enables markup).
    @Published private(set) var hasTextSelection = false
    @Published var layout: Layout = .continuous {
        didSet { applyLayout() }
    }

    // MARK: - Navigation

    func go(toPage index: Int) {
        guard let view = pdfView, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    /// Selects and scrolls to a search match.
    func reveal(_ selection: PDFSelection) {
        guard let view = pdfView else { return }
        view.setCurrentSelection(selection, animate: true)
        view.scrollSelectionToVisible(nil)
    }

    // MARK: - Zoom

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }

    func actualSize() {
        pdfView?.autoScales = false
        pdfView?.scaleFactor = 1
    }

    func fitWidth() {
        guard let view = pdfView else { return }
        view.autoScales = true
    }

    // MARK: - Selection

    var currentSelection: PDFSelection? { pdfView?.currentSelection }

    func clearSelection() {
        pdfView?.clearSelection()
    }

    // MARK: - Callbacks from the coordinator

    func pageChanged() {
        guard let view = pdfView, let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index != currentPage { currentPage = index }
    }

    func selectionChanged() {
        let selected = !(pdfView?.currentSelection?.string?.isEmpty ?? true)
        if selected != hasTextSelection { hasTextSelection = selected }
    }

    private func applyLayout() {
        guard let view = pdfView else { return }
        view.displayMode = layout.mode
        view.displayDirection = .vertical
        view.displaysAsBook = false
    }
}
