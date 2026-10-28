import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Page thumbnails with Finder-style selection, drag-to-reorder, and PDF drops.
///
/// This is the page-organisation surface — the app's core workflow,
/// so it is a custom grid rather than `PDFThumbnailView`, which offers no
/// selection model we can drive or drag-reorder we can intercept.
///
/// - Click selects one page; ⌘-click toggles; ⇧-click selects a range.
/// - ↑/↓ move the selection (⇧ extends it); ⌘A in the Pages menu selects all.
/// - Dragging a thumbnail reorders; dropping PDFs from Finder inserts them there.
struct ThumbnailSidebar: View {

    @ObservedObject var controller: AppController
    @ObservedObject var canvas: CanvasBridge
    let document: PDFDocument
    let revision: Int

    @State private var dragSource: Int?
    @State private var dropTarget: Int?
    @FocusState private var focused: Bool

    /// Thumbnail frames, for drag-to-select in Select mode.
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var selectionAtDragStart: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            selectBar
            pages
        }
        .frame(minWidth: 140, idealWidth: 170)
    }

    /// "Select" toggles checkbox mode: click to tick, drag across pages to tick many.
    private var selectBar: some View {
        HStack(spacing: 6) {
            Button {
                controller.pageSelectMode.toggle()
            } label: {
                Label(controller.pageSelectMode ? "Done" : "Select Pages",
                      systemImage: controller.pageSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .help("Select many pages: tick them, or drag across thumbnails")
            if controller.pageSelectMode {
                Button("All") { controller.selectAllPages() }
                Button("None") { controller.selectedPages = [] }
                Spacer()
                Text("\(controller.selectedPages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var pages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        cell(index)
                    }
                    // Dropping below the last page appends.
                    Color.clear
                        .frame(height: 40)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            insertDroppedFiles(providers, at: document.pageCount)
                        }
                }
                .padding(8)
                .coordinateSpace(name: "thumbnails")
                .onPreferenceChange(CellFrameKey.self) { cellFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if let marquee {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                            .frame(width: marquee.width, height: marquee.height)
                            .offset(x: marquee.minX, y: marquee.minY)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(controller.pageSelectMode ? marqueeGesture : nil)
            }
            // The thumbnail of the page being read follows the canvas.
            .onChange(of: canvas.currentPage) { _, page in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(page, anchor: .center) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow, phases: .down) { press in
            controller.moveSelection(by: -1, extending: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            controller.moveSelection(by: 1, extending: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.delete) {
            controller.deleteSelection()
            return .handled
        }
    }

    private func cell(_ index: Int) -> some View {
        ThumbnailCell(
            document: document,
            index: index,
            revision: revision,
            isSelected: controller.selectedPages.contains(index),
            isCurrent: canvas.currentPage == index,
            showsDropIndicator: dropTarget == index
        )
        .id(index)
        .overlay(alignment: .topTrailing) {
            if controller.pageSelectMode {
                Image(systemName: controller.selectedPages.contains(index) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, controller.selectedPages.contains(index) ? Color.accentColor : Color.secondary)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: CellFrameKey.self, value: [index: geometry.frame(in: .named("thumbnails"))])
        })
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            if controller.pageSelectMode {
                // In Select mode a click ticks or unticks, like checkboxes.
                controller.clickPage(index, command: true, shift: NSEvent.modifierFlags.contains(.shift))
            } else {
                let flags = NSEvent.modifierFlags
                controller.clickPage(index, command: flags.contains(.command), shift: flags.contains(.shift))
            }
        }
        .contextMenu { contextMenu(for: index) }
        .modifier(ReorderDrag(enabled: !controller.pageSelectMode) {
            dragSource = index
        })
        .onDrop(of: [.text, .fileURL], isTargeted: Binding(
            get: { dropTarget == index },
            set: { dropTarget = $0 ? index : (dropTarget == index ? nil : dropTarget) }
        )) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                return insertDroppedFiles(providers, at: index)
            }
            guard let source = dragSource, source != index else { return false }
            controller.movePage(from: source, to: index)
            dragSource = nil
            return true
        }
    }

    /// Right-click acts on the selection if the clicked page is in it, else on that page alone.
    @ViewBuilder
    private func contextMenu(for index: Int) -> some View {
        Button("Insert Blank Page After") {
            controller.selectedPages = [index]
            controller.insertBlankPage()
        }
        Button("Insert from File…") {
            controller.selectedPages = [index]
            controller.insertFromFile()
        }
        Button("Duplicate") { target(index); controller.duplicateSelection() }
        Divider()
        Button("Rotate Left") { target(index); controller.rotateSelection(by: -90) }
        Button("Rotate Right") { target(index); controller.rotateSelection(by: 90) }
        Divider()
        Button("Extract…") { target(index); controller.extractSelection() }
        Button("Delete", role: .destructive) { target(index); controller.deleteSelection() }
    }

    private func target(_ index: Int) {
        if !controller.selectedPages.contains(index) { controller.selectedPages = [index] }
    }

    /// Drag across thumbnails to select every page the rectangle touches
    /// (⌘ adds to the existing selection).
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("thumbnails"))
            .onChanged { value in
                if marquee == nil {
                    selectionAtDragStart = NSEvent.modifierFlags.contains(.command) ? controller.selectedPages : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let hit = cellFrames.filter { $0.value.intersects(rect) }.map(\.key)
                controller.selectedPages = selectionAtDragStart.union(hit)
            }
            .onEnded { _ in marquee = nil }
    }

    /// Inserts PDFs dragged in from Finder at `index`.
    private func insertDroppedFiles(_ providers: [NSItemProvider], at index: Int) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        dropTarget = nil
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadURL(from: provider) { urls.append(url) }
            }
            controller.insertFiles(urls, at: index)
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

/// One page thumbnail.
private struct ThumbnailCell: View {
    let document: PDFDocument
    let index: Int
    let revision: Int
    let isSelected: Bool
    let isCurrent: Bool
    let showsDropIndicator: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            if showsDropIndicator {
                Capsule().fill(Color.accentColor).frame(height: 3)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: isSelected ? 3 : 1
                    )
            )

            Text("\(index + 1)")
                .font(.caption2.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : (isCurrent ? .primary : .secondary))
        }
        .task(id: revision) { await render() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Renders the thumbnail.
    ///
    /// `thumbnailOfSize:forBox:` is synchronous and is one of PDFKit's known
    /// main-thread stalls. `PDFPage` and `PDFDocument` are not
    /// `Sendable`, so this stays on the main actor and bounds the cost
    /// instead: a yield lets scrolling interleave, and `.task(id:)` cancels the
    /// render when a cell scrolls away.
    private func render() async {
        guard let page = document.page(at: index) else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        image = page.thumbnail(of: CGSize(width: 200, height: 260), for: .cropBox)
    }
}

/// Collects thumbnail frames for drag-to-select.
private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Drag-to-reorder, switched off in Select mode so dragging selects instead.
private struct ReorderDrag: ViewModifier {
    let enabled: Bool
    let onStart: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                onStart()
                // The payload is unused — reordering is driven by `dragSource` —
                // but a provider is required for the drag to start at all.
                return NSItemProvider(object: "page" as NSString)
            }
        } else {
            content
        }
    }
}
