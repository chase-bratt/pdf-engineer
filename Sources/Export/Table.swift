import Foundation

/// A table cell, with the spans needed to represent merged cells.
///
/// Vision's `DocumentObservation.Container.Table.Cell` exposes `rowRange` and
/// `columnRange` as `ClosedRange<Int>` — *ranges*, not indices (verified
/// in the macOS 27.0 SDK). So merged cells are representable from OCR,
/// which is better than most extraction stacks manage, and this type preserves
/// that rather than flattening it.
public struct TableCell: Codable, Sendable, Equatable {

    public var text: String

    /// Rows this cell covers. A single-row cell is `n...n`.
    public var rowRange: ClosedRange<Int>

    /// Columns this cell covers.
    public var columnRange: ClosedRange<Int>

    public init(text: String, rowRange: ClosedRange<Int>, columnRange: ClosedRange<Int>) {
        self.text = text
        self.rowRange = rowRange
        self.columnRange = columnRange
    }

    /// Number of rows spanned; 1 for an unmerged cell.
    ///
    /// `count` on a `ClosedRange` already includes both endpoints, so `3...3`
    /// is 1 — not 0, which an exclusive-range habit would produce.
    public var rowSpan: Int { rowRange.count }

    /// Number of columns spanned; 1 for an unmerged cell.
    public var columnSpan: Int { columnRange.count }

    /// Whether this cell is merged across more than one row or column.
    public var isMerged: Bool { rowSpan > 1 || columnSpan > 1 }

    enum CodingKeys: String, CodingKey {
        case text
        case rowRange = "row_range"
        case columnRange = "column_range"
    }

    // ClosedRange is Codable, but encodes as an object. A 2-element array is
    // more compact and easier for other languages to read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        rowRange = try Self.decodeRange(from: container, forKey: .rowRange)
        columnRange = try Self.decodeRange(from: container, forKey: .columnRange)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode([rowRange.lowerBound, rowRange.upperBound], forKey: .rowRange)
        try container.encode([columnRange.lowerBound, columnRange.upperBound], forKey: .columnRange)
    }

    private static func decodeRange(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> ClosedRange<Int> {
        let bounds = try container.decode([Int].self, forKey: key)
        guard bounds.count == 2, bounds[0] <= bounds[1] else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "expected [lower, upper] with lower <= upper, got \(bounds)"
            )
        }
        return bounds[0]...bounds[1]
    }
}

/// A table extracted from a page.
public struct Table: Codable, Sendable, Equatable {

    public var cells: [TableCell]
    public var rowCount: Int
    public var columnCount: Int

    public init(cells: [TableCell], rowCount: Int, columnCount: Int) {
        self.cells = cells
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    /// Whether every cell occupies exactly one row and column.
    ///
    /// Drives the export decision: a clean grid becomes a
    /// Markdown pipe table, which LLMs read cheaply; anything with spans must
    /// become an HTML `<table>`, because pipe tables cannot express `rowspan`
    /// or `colspan` and silently flattening a merged cell loses the structure.
    public var isCleanGrid: Bool {
        cells.allSatisfy { !$0.isMerged }
    }

    enum CodingKeys: String, CodingKey {
        case cells
        case rowCount = "row_count"
        case columnCount = "column_count"
    }
}
