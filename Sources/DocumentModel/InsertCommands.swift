import PDFCore
import PDFKit

// Page insertion commands. Each is undone by `DeletePagesCommand` over exactly
// the range it inserted, so undo never touches pages that were already there.

// MARK: - Insert blank page

/// Inserts a blank page sized like a neighbouring page (US Letter if none).
public struct InsertBlankPageCommand: Command {
    public typealias State = DocumentState

    let index: Int

    /// - Parameter index: Where the new page goes, `0...pageCount`.
    public init(at index: Int) {
        self.index = index
    }

    public var summary: String { "Insert Blank Page" }
    public var isDestructive: Bool { false }

    public func apply(to state: DocumentState) throws -> DocumentState {
        let document = state.document
        guard index >= 0, index <= document.pageCount else {
            throw PDFCoreError.pageIndexOutOfRange(index: index, pageCount: document.pageCount)
        }
        let neighbour = document.page(at: max(0, min(index, document.pageCount - 1)))
        let bounds = neighbour?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: bounds.size), for: .mediaBox)
        document.insert(page, at: index)
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        DeletePagesCommand(pageIndices: [index])
    }
}

// MARK: - Duplicate

/// Inserts a copy of each given page directly after the last of them, in order.
public struct DuplicatePagesCommand: Command {
    public typealias State = DocumentState

    let pageIndices: [Int]

    public init(pageIndices: [Int]) {
        self.pageIndices = Array(Set(pageIndices)).sorted()
    }

    public var summary: String {
        pageIndices.count == 1 ? "Duplicate Page" : "Duplicate \(pageIndices.count) Pages"
    }

    public var isDestructive: Bool { false }

    /// Where the copies land: right after the last duplicated page.
    var insertionIndex: Int { (pageIndices.last ?? -1) + 1 }

    public func apply(to state: DocumentState) throws -> DocumentState {
        try PageIndexValidation.validate(pageIndices, in: state.document)
        // Copy everything first, so inserting cannot shift pages still to be copied.
        let copies: [PDFPage] = try pageIndices.map { index in
            guard let copy = state.document.page(at: index)?.copy() as? PDFPage else {
                throw PDFCoreError.pageCopyFailed(index: index)
            }
            return copy
        }
        for (offset, copy) in copies.enumerated() {
            state.document.insert(copy, at: insertionIndex + offset)
        }
        return state
    }

    public func inverse(for state: DocumentState) throws -> any Command<DocumentState> {
        try PageIndexValidation.validate(pageIndices, in: state.document)
        return DeletePagesCommand(pageIndices: Array(insertionIndex..<(insertionIndex + pageIndices.count)))
    }
}
