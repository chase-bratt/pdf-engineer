import Testing
import CoreGraphics
import Foundation
@testable import Export

/// DocAST is the canonical lossless representation. It is the
/// published contract (`/contracts/docast.schema.json`), so its JSON encoding is
/// part of the API: a field rename is a breaking change for every consumer.
@Suite("DocAST")
struct DocASTTests {

    private func sampleBlock(
        id: String = "b_0001",
        type: BlockType = .paragraph,
        text: String = "Hello"
    ) -> Block {
        Block(
            id: id,
            type: type,
            text: text,
            page: 1,
            bbox: CGRect(x: 72, y: 648, width: 451, height: 18),
            readingOrder: 0,
            provenance: .textLayer
        )
    }

    // MARK: - Encoding contract

    @Test("a block round-trips through JSON unchanged")
    func blockRoundTrips() throws {
        let block = sampleBlock()

        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(Block.self, from: data)

        #expect(decoded == block)
    }

    @Test("JSON keys are snake_case as published in the schema")
    func jsonKeysAreSnakeCase() throws {
        let data = try JSONEncoder().encode(sampleBlock())
        let json = try #require(String(data: data, encoding: .utf8))

        // These names are the published contract; renaming one breaks consumers.
        #expect(json.contains("\"reading_order\""))
        #expect(json.contains("\"provenance\""))
        #expect(json.contains("\"bbox\""))
    }

    @Test("bbox encodes as [x, y, width, height]")
    func bboxEncodesAsArray() throws {
        let block = sampleBlock()
        let data = try JSONEncoder().encode(block)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // An array, not an object: compact, and matches the JSON schema.
        let bbox = try #require(object["bbox"] as? [Double])
        #expect(bbox == [72, 648, 451, 18])
    }

    @Test("optional fields are omitted rather than encoded as null")
    func optionalsAreOmitted() throws {
        let data = try JSONEncoder().encode(sampleBlock())
        let json = try #require(String(data: data, encoding: .utf8))

        // Nulls cost tokens in an LLM-facing artifact for no information gain.
        #expect(!json.contains("null"))
        #expect(!json.contains("\"level\""))
    }

    @Test("a heading carries its inferred level")
    func headingCarriesLevel() throws {
        var block = sampleBlock(type: .heading, text: "Methodology")
        block.level = 2

        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(Block.self, from: data)

        #expect(decoded.level == 2)
    }

    // MARK: - Provenance (load-bearing)

    @Test("provenance distinguishes extracted text from OCR guesses")
    func provenanceIsDistinct() {
        // Conflating these is how silent corruption enters a pipeline, so the
        // cases must stay distinguishable and stably named.
        #expect(Provenance.textLayer.rawValue == "text_layer")
        #expect(Provenance.ocr.rawValue == "ocr")
        #expect(Provenance.structTree.rawValue == "struct_tree")
        #expect(Provenance.inferred.rawValue == "inferred")
    }

    @Test("OCR-derived blocks carry a confidence value")
    func ocrBlocksCarryConfidence() throws {
        var block = sampleBlock()
        block.provenance = .ocr
        block.confidence = 0.87

        let decoded = try JSONDecoder().decode(
            Block.self, from: try JSONEncoder().encode(block)
        )
        #expect(decoded.confidence == 0.87)
        #expect(decoded.provenance == .ocr)
    }

    // MARK: - Document

    @Test("a document round-trips through JSON")
    func documentRoundTrips() throws {
        let document = DocAST(
            source: SourceInfo(
                filename: "report.pdf",
                sha256: String(repeating: "a", count: 64),
                pages: 42,
                tagged: true,
                pdfVersion: "1.7"
            ),
            blocks: [sampleBlock(id: "b_0001"), sampleBlock(id: "b_0002")]
        )

        let decoded = try JSONDecoder().decode(
            DocAST.self, from: try JSONEncoder().encode(document)
        )

        #expect(decoded.blocks.count == 2)
        #expect(decoded.source.filename == "report.pdf")
        #expect(decoded.source.tagged)
    }

    @Test("the schema version is emitted so consumers can detect a break")
    func schemaVersionIsEmitted() throws {
        let document = DocAST(
            source: SourceInfo(filename: "x.pdf", sha256: "", pages: 1),
            blocks: []
        )
        let data = try JSONEncoder().encode(document)

        // Asserted on the parsed value, not the raw text: JSONEncoder escapes
        // the forward slash as "docast\\/1.0", which is valid JSON but makes a
        // substring match on the serialised form misleading.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? String == "docast/1.0")

        let decoded = try JSONDecoder().decode(DocAST.self, from: data)
        #expect(decoded.schema == DocAST.currentSchema)
    }

    @Test("block ids are unique within a document")
    func blockIDsAreUnique() {
        let document = DocAST(
            source: SourceInfo(filename: "x.pdf", sha256: "", pages: 1),
            blocks: [sampleBlock(id: "b_0001"), sampleBlock(id: "b_0002")]
        )

        #expect(document.hasUniqueBlockIDs)
    }

    @Test("duplicate block ids are detectable")
    func duplicateIDsDetected() {
        // Stable unique ids are what make the annotation round-trip and
        // markdown anchors work at all.
        let document = DocAST(
            source: SourceInfo(filename: "x.pdf", sha256: "", pages: 1),
            blocks: [sampleBlock(id: "dup"), sampleBlock(id: "dup")]
        )

        #expect(!document.hasUniqueBlockIDs)
    }

    @Test("blocks can be read back in reading order")
    func blocksInReadingOrder() {
        var first = sampleBlock(id: "b_0002"); first.readingOrder = 5
        var second = sampleBlock(id: "b_0001"); second.readingOrder = 1

        let document = DocAST(
            source: SourceInfo(filename: "x.pdf", sha256: "", pages: 1),
            blocks: [first, second]
        )

        // Storage order is not reading order, so reading order is explicit.
        #expect(document.blocksInReadingOrder.map(\.id) == ["b_0001", "b_0002"])
    }

    @Test("blocks can be filtered by page")
    func blocksByPage() {
        var p1 = sampleBlock(id: "a"); p1.page = 1
        var p2 = sampleBlock(id: "b"); p2.page = 2

        let document = DocAST(
            source: SourceInfo(filename: "x.pdf", sha256: "", pages: 2),
            blocks: [p1, p2]
        )

        #expect(document.blocks(onPage: 2).map(\.id) == ["b"])
    }

    // MARK: - Tables

    @Test("a table cell records its row and column spans")
    func tableCellRecordsSpans() throws {
        // Vision gives rowRange/columnRange, so merged cells are representable.
        let cell = TableCell(text: "Q1", rowRange: 0...1, columnRange: 2...2)

        let decoded = try JSONDecoder().decode(
            TableCell.self, from: try JSONEncoder().encode(cell)
        )

        #expect(decoded.rowSpan == 2)
        #expect(decoded.columnSpan == 1)
    }

    @Test("a single-cell span is 1, not 0")
    func singleCellSpan() {
        let cell = TableCell(text: "x", rowRange: 3...3, columnRange: 1...1)
        #expect(cell.rowSpan == 1)
        #expect(cell.columnSpan == 1)
    }

    @Test("a table knows whether it is a clean grid")
    func tableDetectsCleanGrid() {
        // A clean grid becomes a markdown pipe table; anything with spans
        // must become an HTML table, because pipe tables cannot express them.
        let clean = Table(cells: [
            TableCell(text: "a", rowRange: 0...0, columnRange: 0...0),
            TableCell(text: "b", rowRange: 0...0, columnRange: 1...1),
        ], rowCount: 1, columnCount: 2)
        #expect(clean.isCleanGrid)

        let merged = Table(cells: [
            TableCell(text: "a", rowRange: 0...1, columnRange: 0...0),
        ], rowCount: 2, columnCount: 1)
        #expect(!merged.isCleanGrid)
    }
}
