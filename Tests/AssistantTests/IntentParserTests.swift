import Testing
import Foundation
import PDFKit
import DocumentModel
@testable import Assistant

/// The parser is the safety boundary: whatever the model emits, only a valid
/// ``Intent`` gets through. A small model produces messy output, so these tests
/// are mostly about tolerating that without ever misfiring.
@Suite("IntentParser")
struct IntentParserTests {

    // MARK: - Clean input

    @Test("a bare JSON object parses")
    func bareJSON() {
        #expect(
            IntentParser.parse(#"{"tool":"search","query":"invoice"}"#)
                == .search(query: "invoice")
        )
    }

    @Test("every tool maps to its intent")
    func allTools() {
        #expect(IntentParser.parse(#"{"tool":"count","query":"Acme"}"#) == .count(query: "Acme"))
        #expect(IntentParser.parse(#"{"tool":"goto","page":3}"#) == .goToPage(3))
        #expect(
            IntentParser.parse(#"{"tool":"replace","find":"A","with":"B"}"#)
                == .replace(find: "A", replacement: "B")
        )
        #expect(
            IntentParser.parse(#"{"tool":"rotate","pages":[1,2],"degrees":90}"#)
                == .rotate(pages: [1, 2], degrees: 90)
        )
        #expect(
            IntentParser.parse(#"{"tool":"delete","pages":[2]}"#) == .deletePages([2])
        )
        #expect(IntentParser.parse(#"{"tool":"info"}"#) == .documentInfo)
        #expect(IntentParser.parse(#"{"tool":"export"}"#) == .exportMarkdown)
        #expect(IntentParser.parse(#"{"tool":"ocr"}"#) == .runOCR)
    }

    @Test("tool aliases are accepted")
    func aliases() {
        // The model does not always pick the canonical name.
        #expect(IntentParser.parse(#"{"tool":"find","query":"x"}"#) == .search(query: "x"))
        #expect(IntentParser.parse(#"{"tool":"go_to_page","page":2}"#) == .goToPage(2))
        #expect(IntentParser.parse(#"{"tool":"delete_pages","pages":[1]}"#) == .deletePages([1]))
        #expect(IntentParser.parse(#"{"tool":"markdown"}"#) == .exportMarkdown)
    }

    @Test("tool names are case-insensitive")
    func caseInsensitive() {
        #expect(IntentParser.parse(#"{"tool":"SEARCH","query":"x"}"#) == .search(query: "x"))
    }

    // MARK: - Messy model output

    @Test("an empty think block is skipped")
    func skipsThinkBlock() {
        // Qwen3 emits these even in /no_think mode.
        let reply = "<think>\n\n</think>\n\n{\"tool\":\"search\",\"query\":\"invoice\"}"
        #expect(IntentParser.parse(reply) == .search(query: "invoice"))
    }

    @Test("a populated think block is skipped")
    func skipsReasoning() {
        let reply = """
            <think>The user wants to find something. I should use search.</think>
            {"tool":"search","query":"total"}
            """
        #expect(IntentParser.parse(reply) == .search(query: "total"))
    }

    @Test("a markdown code fence is tolerated")
    func toleratesCodeFence() {
        let reply = "```json\n{\"tool\":\"count\",\"query\":\"Acme\"}\n```"
        #expect(IntentParser.parse(reply) == .count(query: "Acme"))
    }

    @Test("surrounding prose is tolerated")
    func toleratesProse() {
        let reply = "Sure! Here is the JSON: {\"tool\":\"ocr\"} Let me know if that helps."
        #expect(IntentParser.parse(reply) == .runOCR)
    }

    @Test("prose containing braces after the JSON does not corrupt parsing")
    func bracesInTrailingProse() {
        // A naive first-{-to-last-} grab fails here; depth counting is why this
        // works.
        let reply = #"{"tool":"search","query":"x"} note: use {braces} carefully"#
        #expect(IntentParser.parse(reply) == .search(query: "x"))
    }

    @Test("a brace inside a string value is not treated as structure")
    func braceInsideString() {
        let reply = #"{"tool":"search","query":"a{b"}"#
        #expect(IntentParser.parse(reply) == .search(query: "a{b"))
    }

    @Test("an escaped quote inside a value is handled")
    func escapedQuote() {
        let reply = #"{"tool":"search","query":"say \"hi\""}"#
        #expect(IntentParser.parse(reply) == .search(query: #"say "hi""#))
    }

    @Test("a number sent as a string still parses")
    func numberAsString() {
        // Models are inconsistent about quoting numbers.
        #expect(IntentParser.parse(#"{"tool":"goto","page":"4"}"#) == .goToPage(4))
    }

    @Test("a page list sent as a string still parses")
    func pageListAsString() {
        #expect(
            IntentParser.parse(#"{"tool":"delete","pages":"1,3"}"#) == .deletePages([1, 3])
        )
    }

    @Test("a single page sent unwrapped still parses")
    func singlePageUnwrapped() {
        #expect(IntentParser.parse(#"{"tool":"rotate","pages":2,"degrees":90}"#)
                == .rotate(pages: [2], degrees: 90))
    }

    @Test("replacement accepts either field name")
    func replacementFieldNames() {
        #expect(
            IntentParser.parse(#"{"tool":"replace","find":"A","replacement":"B"}"#)
                == .replace(find: "A", replacement: "B")
        )
    }

    @Test("rotate defaults to 90 degrees when unspecified")
    func rotateDefaults() {
        #expect(IntentParser.parse(#"{"tool":"rotate","pages":[1]}"#)
                == .rotate(pages: [1], degrees: 90))
    }

    @Test("an empty replacement means delete the text")
    func emptyReplacementAllowed() {
        #expect(
            IntentParser.parse(#"{"tool":"replace","find":"A","with":""}"#)
                == .replace(find: "A", replacement: "")
        )
    }

    // MARK: - Rejection

    @Test("non-JSON output is reported as unsupported")
    func nonJSONRejected() {
        guard case .unsupported = IntentParser.parse("I'm not sure what you mean.") else {
            Issue.record("expected .unsupported")
            return
        }
    }

    @Test("an unknown tool is rejected rather than guessed at")
    func unknownToolRejected() {
        guard case .unsupported = IntentParser.parse(#"{"tool":"launch_missiles"}"#) else {
            Issue.record("expected .unsupported")
            return
        }
    }

    @Test("a missing required field is rejected with a question")
    func missingFieldRejected() {
        // Better to ask than to search for the empty string.
        guard case let .unsupported(reason) = IntentParser.parse(#"{"tool":"search"}"#) else {
            Issue.record("expected .unsupported")
            return
        }
        #expect(reason.contains("search for"))
    }

    @Test("an empty query is rejected")
    func emptyQueryRejected() {
        guard case .unsupported = IntentParser.parse(#"{"tool":"search","query":""}"#) else {
            Issue.record("expected .unsupported")
            return
        }
    }

    @Test("delete with no pages is rejected")
    func deleteWithoutPagesRejected() {
        guard case .unsupported = IntentParser.parse(#"{"tool":"delete","pages":[]}"#) else {
            Issue.record("expected .unsupported")
            return
        }
    }

    @Test("hostile or implausible page numbers are rejected at parse time",
          arguments: [
              #"{"tool":"goto","page":-9223372036854775808}"#,
              #"{"tool":"goto","page":0}"#,
              #"{"tool":"goto","page":100001}"#,
              #"{"tool":"goto","page":1e300}"#,
              #"{"tool":"delete","pages":[-9223372036854775808]}"#,
              #"{"tool":"delete","pages":[2, 0]}"#,
              #"{"tool":"delete","pages":"1,x"}"#,
              #"{"tool":"rotate","pages":[-9223372036854775808],"degrees":90}"#,
              #"{"tool":"rotate","pages":[2.5],"degrees":90}"#,
              #"{"tool":"rotate","pages":1e300,"degrees":90}"#,
          ])
    func hostilePageNumbersRejected(reply: String) {
        // Before the bound, Int.min reached `page - 1` in the executor and
        // trapped, so one bad model reply crashed the app.
        guard case .unsupported = IntentParser.parse(reply) else {
            Issue.record("expected .unsupported for \(reply)")
            return
        }
    }

    @Test("-1 still means the last page, and the upper bound is inclusive")
    func pageBoundsAccepted() {
        #expect(IntentParser.parse(#"{"tool":"goto","page":-1}"#) == .goToPage(-1))
        #expect(IntentParser.parse(#"{"tool":"goto","page":100000}"#) == .goToPage(100_000))
    }

    @Test("the executor never traps on an out-of-range page, however the Intent was built")
    @MainActor
    func executorSurvivesExtremePages() throws {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let session = DocumentSession(document: document)
        for intent: Intent in [
            .goToPage(Int.min), .goToPage(Int.max),
            .rotate(pages: [Int.min], degrees: 90),
            .deletePages([Int.min]),
        ] {
            let outcome = IntentExecutor.execute(intent, on: session, confirmed: true)
            #expect(outcome.message.contains("does not exist"), "\(intent)")
            #expect(!outcome.didMutate)
        }
        #expect(session.pageCount == 1)
    }

    @Test("malformed JSON is rejected rather than partially applied")
    func malformedJSONRejected() {
        guard case .unsupported = IntentParser.parse(#"{"tool":"delete","pages":[1,}"#) else {
            Issue.record("expected .unsupported")
            return
        }
    }

    // MARK: - Intent properties

    @Test("read-only intents are marked as not mutating")
    func readOnlyIntents() {
        #expect(!Intent.search(query: "x").mutatesDocument)
        #expect(!Intent.count(query: "x").mutatesDocument)
        #expect(!Intent.goToPage(1).mutatesDocument)
        #expect(!Intent.documentInfo.mutatesDocument)
    }

    @Test("mutating intents are marked as mutating")
    func mutatingIntents() {
        #expect(Intent.replace(find: "a", replacement: "b").mutatesDocument)
        #expect(Intent.deletePages([1]).mutatesDocument)
        #expect(Intent.rotate(pages: [1], degrees: 90).mutatesDocument)
    }

    @Test("destructive intents require confirmation")
    func confirmationRequired() {
        // Delete and replace are the two that paint over or remove content.
        #expect(Intent.deletePages([1]).needsConfirmation)
        #expect(Intent.replace(find: "a", replacement: "b").needsConfirmation)
        #expect(!Intent.search(query: "x").needsConfirmation)
        #expect(!Intent.rotate(pages: [1], degrees: 90).needsConfirmation)
    }

    @Test("summaries name the actual values, so a prompt is reviewable")
    func summariesAreSpecific() {
        #expect(
            Intent.replace(find: "Acme", replacement: "Globex").summary
                == #"Replace "Acme" with "Globex""#
        )
        #expect(Intent.deletePages([1, 2]).summary == "Delete 2 page(s)")
    }

    // MARK: - Model discovery

    @Test("a cached model directory is found when present")
    func findsCachedModel() {
        // Not asserting it exists — that depends on the machine. Asserting the
        // path logic does not crash and returns either a real directory or nil.
        let found = LocalLLM.cachedModelDirectory(for: "mlx-community/Qwen3-1.7B-4bit")
        if let found {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: found.path)
            #expect(contents?.contains { $0.hasSuffix(".safetensors") } ?? false)
        }
    }

    @Test("a nonexistent model returns nil rather than a bogus path")
    func missingModelReturnsNil() {
        #expect(LocalLLM.cachedModelDirectory(for: "nobody/does-not-exist-xyz") == nil)
    }
}
