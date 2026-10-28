import Foundation

/// What the assistant understood the user to want.
///
/// ## The safety boundary
///
/// This enum *is* the boundary. A 1.7B model is good at picking a label and
/// filling two fields; it is not good at rewriting a document, and it would
/// happily hallucinate content if asked to. So the model's only job is to emit
/// one of these, and our tested code executes it.
///
/// The consequence: the model never touches document bytes. It cannot corrupt a
/// PDF, because the worst it can do is pick the wrong tool or the wrong search
/// string — and every resulting edit is an undoable `Command`.
public enum Intent: Sendable, Equatable {

    /// Find text. Read-only.
    case search(query: String)

    /// Count occurrences of text. Read-only.
    case count(query: String)

    /// Jump to a page. Read-only.
    case goToPage(Int)

    /// Replace every occurrence of `find` with `replacement`.
    case replace(find: String, replacement: String)

    /// Rotate pages. `pages` empty means all.
    case rotate(pages: [Int], degrees: Int)

    /// Delete pages.
    case deletePages([Int])

    /// Describe the document. Read-only.
    case documentInfo

    /// Export to Markdown.
    case exportMarkdown

    /// Run OCR.
    case runOCR

    /// The model could not map the request onto a supported action.
    ///
    /// Explicit rather than a silent no-op: the user gets told their request
    /// was not understood instead of watching nothing happen.
    case unsupported(reason: String)

    /// Whether executing this changes the document.
    ///
    /// Drives the confirmation prompt — the same consent idea as the MCP layer
    /// (explicit confirmation before a change), applied to a local model.
    public var mutatesDocument: Bool {
        switch self {
        case .search, .count, .goToPage, .documentInfo, .exportMarkdown, .unsupported:
            return false
        case .replace, .rotate, .deletePages, .runOCR:
            return true
        }
    }

    /// Whether the user should confirm before this runs.
    public var needsConfirmation: Bool {
        switch self {
        case .deletePages, .replace: return true
        default: return false
        }
    }

    /// One-line description, shown in the confirmation prompt.
    public var summary: String {
        switch self {
        case let .search(query):
            return "Search for \"\(query)\""
        case let .count(query):
            return "Count occurrences of \"\(query)\""
        case let .goToPage(page):
            return "Go to page \(page)"
        case let .replace(find, replacement):
            return "Replace \"\(find)\" with \"\(replacement)\""
        case let .rotate(pages, degrees):
            let scope = pages.isEmpty ? "all pages" : "\(pages.count) page(s)"
            return "Rotate \(scope) by \(degrees)°"
        case let .deletePages(pages):
            return "Delete \(pages.count) page(s)"
        case .documentInfo:
            return "Describe the document"
        case .exportMarkdown:
            return "Export as Markdown"
        case .runOCR:
            return "Make the document searchable (OCR)"
        case let .unsupported(reason):
            return reason
        }
    }
}

/// Parses the model's JSON reply into an ``Intent``.
///
/// Tolerant by design: a small model wraps JSON in prose, emits `<think>`
/// blocks even in `/no_think` mode, and fences code. Rejecting those would make
/// the feature feel broken when the model is substantially right, so this digs
/// the JSON object out of whatever surrounds it.
public enum IntentParser {

    public static func parse(_ reply: String) -> Intent {
        guard let json = extractJSONObject(from: reply) else {
            return .unsupported(reason: "I couldn't understand that request.")
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String
        else {
            return .unsupported(reason: "I couldn't understand that request.")
        }
        return intent(tool: tool.lowercased(), fields: object)
    }

    // MARK: - Private

    private static func intent(tool: String, fields: [String: Any]) -> Intent {
        switch tool {
        case "search", "find":
            guard let query = string(fields, "query"), !query.isEmpty else {
                return .unsupported(reason: "What should I search for?")
            }
            return .search(query: query)

        case "count":
            guard let query = string(fields, "query"), !query.isEmpty else {
                return .unsupported(reason: "What should I count?")
            }
            return .count(query: query)

        case "goto", "goto_page", "go_to_page", "page":
            guard let page = int(fields, "page") else {
                return .unsupported(reason: "Which page?")
            }
            // -1 is the prompt's spelling of "last page"; anything else must
            // be a plausible page number, so `page - 1` downstream cannot trap.
            guard page == -1 || isValidPageNumber(page) else {
                return .unsupported(reason: invalidPageReason(page))
            }
            return .goToPage(page)

        case "replace":
            guard let find = string(fields, "find"), !find.isEmpty else {
                return .unsupported(reason: "What text should I replace?")
            }
            // An empty replacement is legitimate — it means delete the text.
            let replacement = string(fields, "with")
                ?? string(fields, "replacement")
                ?? ""
            return .replace(find: find, replacement: replacement)

        case "rotate":
            let degrees = int(fields, "degrees") ?? 90
            guard let pages = pageList(fields, "pages") else {
                return .unsupported(reason: "Those page numbers aren't valid. Use 1 for the first page.")
            }
            if let bad = pages.first(where: { !isValidPageNumber($0) }) {
                return .unsupported(reason: invalidPageReason(bad))
            }
            return .rotate(pages: pages, degrees: degrees)

        case "delete", "delete_pages":
            guard let pages = pageList(fields, "pages") else {
                return .unsupported(reason: "Those page numbers aren't valid. Use 1 for the first page.")
            }
            guard !pages.isEmpty else {
                return .unsupported(reason: "Which pages should I delete?")
            }
            if let bad = pages.first(where: { !isValidPageNumber($0) }) {
                return .unsupported(reason: invalidPageReason(bad))
            }
            return .deletePages(pages)

        case "info", "document_info":
            return .documentInfo

        case "export", "export_markdown", "markdown":
            return .exportMarkdown

        case "ocr", "run_ocr":
            return .runOCR

        default:
            return .unsupported(reason: "I can't do that yet.")
        }
    }

    /// Finds the first balanced `{…}` run, ignoring braces inside strings.
    ///
    /// A naive first-`{`-to-last-`}` grab breaks when the model emits prose
    /// containing braces after the JSON; counting depth is what makes this
    /// reliable on messy output.
    static func extractJSONObject(from text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]

            if escaped { escaped = false; continue }
            if character == "\\" , inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }

            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
                // A stray closing brace before any opening one: ignore it
                // rather than going negative.
                if depth < 0 { depth = 0 }
            }
        }
        return nil
    }

    private static func string(_ fields: [String: Any], _ key: String) -> String? {
        if let value = fields[key] as? String { return value }
        // Models sometimes emit a number where a string belongs.
        if let value = fields[key] as? NSNumber { return value.stringValue }
        return nil
    }

    /// The largest page number accepted from the model.
    ///
    /// Far beyond any real document, but small enough that arithmetic on it
    /// (`page - 1`, `index + 1`) can never overflow. The model's JSON is
    /// untrusted: without this, `{"page": -9223372036854775808}` reaches
    /// `page - 1` and traps, crashing the app.
    static let maxPageNumber = 100_000

    static func isValidPageNumber(_ page: Int) -> Bool {
        (1...maxPageNumber).contains(page)
    }

    private static func invalidPageReason(_ page: Int) -> String {
        "Page \(page) isn't a valid page number. Pages are numbered from 1."
    }

    /// `as? Int` rather than `.intValue`: Foundation bridges an `NSNumber` to
    /// `Int` only when the value is exactly representable, whereas `.intValue`
    /// silently wraps 1e300 or truncates 2.5 into some unrelated page.
    private static func int(_ fields: [String: Any], _ key: String) -> Int? {
        if let value = fields[key] as? NSNumber { return value as? Int }
        if let text = fields[key] as? String {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Page numbers as sent, or nil if any entry is not a whole number.
    ///
    /// All-or-nothing: silently dropping a bad entry would apply the intent to
    /// a different set of pages than the model asked for.
    private static func pageList(_ fields: [String: Any], _ key: String) -> [Int]? {
        guard let raw = fields[key] else { return [] }
        if let numbers = raw as? [Any] {
            let pages = numbers.compactMap { ($0 as? NSNumber).flatMap { $0 as? Int } }
            return pages.count == numbers.count ? pages : nil
        }
        if let single = raw as? NSNumber { return (single as? Int).map { [$0] } }
        if let text = raw as? String {
            // "1,3,5" or "2"
            let parts = text.split(separator: ",")
            let pages = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return pages.count == parts.count ? pages : nil
        }
        return nil
    }
}
