import PDFKit
import SwiftUI

/// The document's table of contents (its PDF outline), for long reports and books.
struct OutlineSidebar: View {
    let document: PDFDocument
    let revision: Int
    let onSelect: (Int) -> Void

    private struct Node: Identifiable {
        let id: String
        let title: String
        let pageIndex: Int?
        let children: [Node]?
    }

    var body: some View {
        let nodes = Self.nodes(of: document.outlineRoot, document: document, path: "")
        Group {
            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No table of contents")
                        .foregroundStyle(.secondary)
                    Text("This PDF has no bookmarks.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(nodes, children: \.children) { node in
                    Button {
                        if let page = node.pageIndex { onSelect(page) }
                    } label: {
                        HStack {
                            Text(node.title).lineLimit(2)
                            Spacer()
                            if let page = node.pageIndex {
                                Text("\(page + 1)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 140, idealWidth: 200)
        .id(revision)
    }

    private static func nodes(of outline: PDFOutline?, document: PDFDocument, path: String) -> [Node] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let id = path + "/\(index)"
            let page = child.destination?.page.map { document.index(for: $0) }
            let children = nodes(of: child, document: document, path: id)
            return Node(
                id: id,
                title: child.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                pageIndex: page.flatMap { $0 == NSNotFound ? nil : $0 },
                children: children.isEmpty ? nil : children
            )
        }
    }
}

/// ⌥⌘G: jump to a page by number.
struct GoToPageSheet: View {
    @ObservedObject var controller: AppController
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            TextField("1–\(controller.pageCount)", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(text.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(20)
        .onAppear {
            text = "\(controller.canvas.currentPage + 1)"
            focused = true
        }
    }

    private func go() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        controller.goToPage(number)
        dismiss()
    }
}
