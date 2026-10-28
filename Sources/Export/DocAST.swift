import CoreGraphics
import Foundation

// DocAST — the canonical, lossless document representation.
//
// This is a *published contract*: it is serialised to
// `/contracts/docast.schema.json` and consumed by external tooling, so the JSON
// key names here are API. Renaming a field is a breaking change and requires a
// schema version bump, which is why the encoding is pinned by tests.
//
// Design rules enforced below:
//   - snake_case keys, matching the JSON schema.
//   - `bbox` as a 4-element array, not an object: compact for an artifact whose
//     whole purpose is token efficiency.
//   - optionals omitted rather than encoded as `null`, for the same reason.

/// What kind of content a block holds.
public enum BlockType: String, Codable, Sendable, Equatable {
    case heading
    case paragraph
    case list
    case table
    case figure
    case code
    case equation
    case footnote
    case caption
    case header
    case footer
    case annotation
    case formField = "form_field"
}

/// Where a block's content came from.
///
/// This is load-bearing: a consumer must be able to tell
/// extracted text from an OCR guess. Conflating them is how silent data
/// corruption enters a downstream pipeline.
public enum Provenance: String, Codable, Sendable, Equatable {
    /// Extracted from the PDF's own text layer. Trustworthy.
    case textLayer = "text_layer"
    /// Produced by OCR. Carries `confidence`; may be wrong.
    case ocr
    /// Taken from the tagged-PDF structure tree. Authoritative for semantics.
    case structTree = "struct_tree"
    /// Derived by our own classifier, e.g. an inferred heading level.
    case inferred
}

/// A single unit of document content.
public struct Block: Codable, Sendable, Equatable, Identifiable {

    /// Stable across re-exports, so markdown anchors and annotation round-trips
    /// keep pointing at the same content.
    public var id: String

    public var type: BlockType
    public var text: String

    /// 1-based page number, matching what a user sees.
    public var page: Int

    /// Bounds in PDF user space, origin bottom-left.
    public var bbox: CGRect

    /// Position in the document's reading order. Storage order is not
    /// reading order, so this is explicit.
    public var readingOrder: Int

    public var provenance: Provenance

    /// Heading depth, 1-based. Only meaningful for `.heading`.
    ///
    /// Vision gives one title and a flat paragraph list with no levels
    /// so for scanned input this is always inferred.
    public var level: Int?

    /// Recognition confidence, 0...1. Present when `provenance == .ocr`.
    public var confidence: Double?

    /// BCP-47 language tag.
    public var lang: String?

    /// Font and weight, where they carry meaning (bold, code, emphasis).
    public var style: BlockStyle?

    public init(
        id: String,
        type: BlockType,
        text: String,
        page: Int,
        bbox: CGRect,
        readingOrder: Int,
        provenance: Provenance,
        level: Int? = nil,
        confidence: Double? = nil,
        lang: String? = nil,
        style: BlockStyle? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.page = page
        self.bbox = bbox
        self.readingOrder = readingOrder
        self.provenance = provenance
        self.level = level
        self.confidence = confidence
        self.lang = lang
        self.style = style
    }

    enum CodingKeys: String, CodingKey {
        case id, type, text, page, bbox, provenance, level, confidence, lang, style
        case readingOrder = "reading_order"
    }

    // `CGRect` has no compact Codable form, so bbox is encoded explicitly as
    // [x, y, width, height].
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(BlockType.self, forKey: .type)
        text = try container.decode(String.self, forKey: .text)
        page = try container.decode(Int.self, forKey: .page)
        readingOrder = try container.decode(Int.self, forKey: .readingOrder)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        style = try container.decodeIfPresent(BlockStyle.self, forKey: .style)

        let values = try container.decode([Double].self, forKey: .bbox)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(
                forKey: .bbox, in: container,
                debugDescription: "bbox must be [x, y, width, height]; got \(values.count) values"
            )
        }
        bbox = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encode(page, forKey: .page)
        try container.encode(readingOrder, forKey: .readingOrder)
        try container.encode(provenance, forKey: .provenance)
        // encodeIfPresent: omitted rather than null, to save tokens.
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(
            [bbox.origin.x, bbox.origin.y, bbox.width, bbox.height].map(Double.init),
            forKey: .bbox
        )
    }
}

/// Styling that carries meaning, rather than full visual fidelity.
public struct BlockStyle: Codable, Sendable, Equatable {
    public var font: String?
    public var size: Double?
    public var bold: Bool?
    public var italic: Bool?

    public init(font: String? = nil, size: Double? = nil, bold: Bool? = nil, italic: Bool? = nil) {
        self.font = font
        self.size = size
        self.bold = bold
        self.italic = italic
    }
}

/// Provenance and identity of the source file.
public struct SourceInfo: Codable, Sendable, Equatable {
    public var filename: String

    /// Hash of the source bytes, so an export can be tied to an exact input.
    public var sha256: String

    public var pages: Int

    /// Whether the PDF carried a structure tree. Drives export quality
    /// expectations — and is usually `false` in practice.
    public var tagged: Bool

    public var pdfVersion: String?
    public var producer: String?

    public init(
        filename: String,
        sha256: String,
        pages: Int,
        tagged: Bool = false,
        pdfVersion: String? = nil,
        producer: String? = nil
    ) {
        self.filename = filename
        self.sha256 = sha256
        self.pages = pages
        self.tagged = tagged
        self.pdfVersion = pdfVersion
        self.producer = producer
    }

    enum CodingKeys: String, CodingKey {
        case filename, sha256, pages, tagged, producer
        case pdfVersion = "pdf_version"
    }
}

/// The canonical document representation.
public struct DocAST: Codable, Sendable, Equatable {

    /// Schema identifier, emitted so a consumer can detect an incompatible
    /// version rather than mis-parsing.
    public let schema: String

    public var source: SourceInfo
    public var blocks: [Block]

    /// Current schema version. Bumping this is a breaking change.
    public static let currentSchema = "docast/1.0"

    public init(source: SourceInfo, blocks: [Block]) {
        self.schema = Self.currentSchema
        self.source = source
        self.blocks = blocks
    }

    // MARK: - Queries

    /// Blocks sorted by reading order, which storage order does not imply.
    public var blocksInReadingOrder: [Block] {
        blocks.sorted { $0.readingOrder < $1.readingOrder }
    }

    /// Blocks on a 1-based page, in reading order.
    public func blocks(onPage page: Int) -> [Block] {
        blocks.filter { $0.page == page }.sorted { $0.readingOrder < $1.readingOrder }
    }

    /// Whether every block id is distinct.
    ///
    /// Stable unique ids are the precondition for markdown anchors and the
    /// annotation round-trip, so an exporter validates this before writing.
    public var hasUniqueBlockIDs: Bool {
        Set(blocks.map(\.id)).count == blocks.count
    }
}
