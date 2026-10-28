import Foundation

/// Parses human page lists such as `1-5,8,10-end` into zero-based indices.
///
/// One parser shared by the CLI, the MCP tools and the app, so "page 3" means
/// the same thing everywhere. Input is 1-based (what people and LLMs say);
/// output is 0-based (what PDFKit uses), sorted and de-duplicated.
public enum PageRange {

    public enum ParseError: Error, Equatable, Sendable, LocalizedError {
        case empty
        case invalidToken(String)
        case outOfRange(page: Int, pageCount: Int)
        case reversed(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "No pages were given. Use a list like 1-3,5,8-end."
            case let .invalidToken(token):
                return "\"\(token)\" is not a page number or range. Use a list like 1-3,5,8-end."
            case let .outOfRange(page, pageCount):
                return "Page \(page) is outside the document's range of 1–\(pageCount)."
            case let .reversed(token):
                return "The range \"\(token)\" runs backwards; write the smaller page first."
            }
        }
    }

    /// - Parameters:
    ///   - text: Comma-separated pages and ranges; whitespace is ignored.
    ///     `end` (or `last`) means the final page.
    ///   - pageCount: Number of pages in the document.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let tokens = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ParseError.empty }

        var pages = Set<Int>()
        for token in tokens {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch parts.count {
            case 1:
                pages.insert(try number(parts[0], token: token, pageCount: pageCount))
            case 2:
                let lower = try number(parts[0], token: token, pageCount: pageCount)
                let upper = try number(parts[1], token: token, pageCount: pageCount)
                guard lower <= upper else { throw ParseError.reversed(token) }
                pages.formUnion(lower...upper)
            default:
                throw ParseError.invalidToken(token)
            }
        }
        return pages.sorted().map { $0 - 1 }
    }

    /// Splits `0..<pageCount` into consecutive chunks of `size` pages.
    public static func chunks(pageCount: Int, size: Int) -> [[Int]] {
        guard size > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { start in
            Array(start..<min(start + size, pageCount))
        }
    }

    private static func number(_ text: String, token: String, pageCount: Int) throws -> Int {
        let lowered = text.lowercased()
        if lowered == "end" || lowered == "last" { return pageCount }
        guard let value = Int(text) else { throw ParseError.invalidToken(token) }
        guard value >= 1, value <= pageCount else {
            throw ParseError.outOfRange(page: value, pageCount: pageCount)
        }
        return value
    }
}
