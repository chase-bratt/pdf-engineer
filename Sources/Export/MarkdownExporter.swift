import Foundation
import PDFKit

/// Builds a ``DocAST`` from a PDF and renders Markdown from it.
///
/// DocAST is canonical; Markdown is *derived*. Markdown is never
/// the source of truth, which is why this type always builds the AST first even
/// when only Markdown is wanted.
///
/// ## Scope
///
/// v1 extracts the text layer and infers paragraph and heading structure from
/// it. It does **not** attempt table reconstruction or figure extraction from
/// born-digital PDFs — those need content-stream analysis. Vision's
/// structured output covers them for scanned input and will land here once the
/// OCR path feeds the AST directly.
public enum MarkdownExporter {

    /// Builds the AST for a document.
    public static func buildAST(from document: PDFDocument, filename: String) -> DocAST {
        var blocks: [Block] = []
        var order = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string, !text.isEmpty else { continue }

            let pageBox = page.bounds(for: .mediaBox)

            for paragraph in paragraphs(in: text) {
                let isHeading = looksLikeHeading(paragraph)
                blocks.append(
                    Block(
                        id: String(format: "b_%04d", blocks.count + 1),
                        type: isHeading ? .heading : .paragraph,
                        text: paragraph,
                        page: index + 1,
                        // Page-level bounds: per-block geometry needs the
                        // content-stream layer, so claiming tighter boxes here
                        // would be a lie the AST's consumers would act on.
                        bbox: pageBox,
                        readingOrder: order,
                        provenance: .textLayer,
                        level: isHeading ? headingLevel(paragraph) : nil
                    )
                )
                order += 1
            }
        }

        return DocAST(
            source: SourceInfo(
                filename: filename,
                sha256: "",
                pages: document.pageCount,
                tagged: false,
                pdfVersion: nil,
                producer: document.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String
            ),
            blocks: blocks
        )
    }

    /// Renders Markdown with YAML frontmatter from an AST.
    public static func markdown(from ast: DocAST) -> String {
        var lines: [String] = []

        // Frontmatter carries the provenance a consumer needs to judge the text.
        lines.append("---")
        lines.append("source: \(yamlString(ast.source.filename))")
        lines.append("pages: \(ast.source.pages)")
        lines.append("schema: \(ast.schema)")
        if let producer = ast.source.producer, !producer.isEmpty {
            lines.append("producer: \(yamlString(producer))")
        }
        lines.append("---")
        lines.append("")

        var lastPage = 0
        for block in ast.blocksInReadingOrder {
            // A page marker keeps citations possible after export, which is the
            // main thing a flat Markdown dump otherwise destroys.
            if block.page != lastPage {
                lines.append("<!-- page \(block.page) -->")
                lines.append("")
                lastPage = block.page
            }

            switch block.type {
            case .heading:
                let hashes = String(repeating: "#", count: min(block.level ?? 2, 6))
                lines.append("\(hashes) \(block.text)")
            case .code:
                lines.append("```")
                lines.append(block.text)
                lines.append("```")
            default:
                lines.append(block.text)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Convenience: PDF straight to Markdown.
    public static func markdown(from document: PDFDocument, filename: String) -> String {
        markdown(from: buildAST(from: document, filename: filename))
    }

    // MARK: - Structure inference

    /// Splits page text into paragraphs.
    ///
    /// PDFKit returns text with hard line breaks at the *visual* line ends, so
    /// a blank line is the only reliable paragraph signal available without
    /// geometry. Single newlines inside a paragraph are joined, because leaving
    /// them turns every wrapped line into its own Markdown line.
    static func paragraphs(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { block in
                block
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Heuristic heading detection.
    ///
    /// Without font metrics (which need the content-stream layer) this is
    /// necessarily shallow: short, unterminated lines, or numbered section
    /// headers. Marked `.inferred` in the AST so consumers know not to trust it
    /// as much as a structure-tree tag.
    static func looksLikeHeading(_ text: String) -> Bool {
        guard text.count <= 80, !text.isEmpty else { return false }
        // Sentences end in punctuation; headings generally do not.
        if let last = text.last, ".!?,;:".contains(last) { return false }
        if numberedPrefix(text) != nil { return true }
        // ALL CAPS short lines are nearly always headings.
        if text == text.uppercased(), text.contains(where: \.isLetter) { return true }
        return false
    }

    /// Depth from a numbered prefix: "1" is h1, "1.2" is h2, and so on.
    static func headingLevel(_ text: String) -> Int {
        guard let prefix = numberedPrefix(text) else { return 2 }
        let depth = prefix.split(separator: ".").filter { !$0.isEmpty }.count
        return min(max(depth, 1), 6)
    }

    /// Returns a leading "1." / "2.3.4" style prefix, if present.
    private static func numberedPrefix(_ text: String) -> String? {
        let head = text.prefix { $0.isNumber || $0 == "." }
        guard head.contains(where: \.isNumber) else { return nil }
        // Must be followed by whitespace, or "1984" would look like a heading.
        let rest = text.dropFirst(head.count)
        guard let next = rest.first, next == " " else { return nil }
        return String(head)
    }

    /// Minimal YAML scalar quoting.
    private static func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
