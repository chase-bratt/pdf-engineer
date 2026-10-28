import Assistant
import DocumentModel
import Export
import Foundation
import OCR
import PDFCore
import PDFKit

// CLI over the same engine modules the app uses.
//
// This is not a toy: it is how the engine gets exercised without GUI
// automation, and it is the surface the MCP server will wrap.
// If a feature works here, the app's menu item for it is a thin wrapper.

let usage = """
pdfeng — PDF Engineer CLI

USAGE
  pdfeng ask <file.pdf> "<request>"
  pdfeng html <in.html> [out.pdf]
  pdfeng convert <out.pdf> <file> [file...]   (docx, doc, rtf, odt, txt, md, csv, images, pdf)
  pdfeng flatten <in.pdf> <out.pdf>           (bake annotations into the pages)
  pdfeng info <file.pdf>
  pdfeng text <file.pdf> [pages]
  pdfeng search <file.pdf> <query>
  pdfeng merge <out.pdf> <in1.pdf> <in2.pdf> [...]
  pdfeng rotate <in.pdf> <out.pdf> <degrees> <pages>
  pdfeng delete <in.pdf> <out.pdf> <pages>
  pdfeng move <in.pdf> <out.pdf> <from> <to>
  pdfeng extract <in.pdf> <out.pdf> <pages>
  pdfeng split <in.pdf> <out-dir> --every <N>
  pdfeng ocr <in.pdf> <out.pdf>
  pdfeng markdown <file.pdf> [out.md]
  pdfeng ast <file.pdf> [out.json]

Page numbers are 1-based, matching what the app shows. <pages> is a list of
pages and ranges such as 1-3,7,10-end ("end" or "last" is the final page).
<degrees> is a multiple of 90; positive turns clockwise.
The output file must differ from the input; writes are atomic.
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func load(_ path: String) -> PDFDocument {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
        die("could not open \(path)")
    }
    return document
}

func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

/// Parses "1-3,7,10-end" into sorted zero-based indices via the shared
/// ``PageRange``, so the CLI, MCP and app agree on what a page list means.
func pageList(_ argument: String, pageCount: Int) -> [Int] {
    do {
        return try PageRange.parse(argument, pageCount: pageCount)
    } catch {
        die(message(error))
    }
}

/// Refuses to write over an input file.
///
/// PDFKit reads lazily, so writing over the input corrupts the very bytes
/// still being read, and a failure part-way leaves the user with nothing.
func requireDistinct(_ input: String, _ output: String) {
    if AtomicPDFWriter.isSameFile(URL(fileURLWithPath: input), URL(fileURLWithPath: output)) {
        die(message(PDFCoreError.outputIsInput(path: output)))
    }
}

func write(_ document: PDFDocument, to path: String) {
    do {
        try AtomicPDFWriter.write(document, to: URL(fileURLWithPath: path))
    } catch {
        die(message(error))
    }
    print("wrote \(path)")
}

/// Writes text output, reporting failure instead of claiming success.
func writeOutput(_ data: Data, to path: String, detail: String) {
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        die("could not write \(path): \(error.localizedDescription)")
    }
    print("wrote \(path) (\(detail))")
}

/// Applies a command through a real session, so the CLI exercises the same
/// undo-backed path the UI and MCP server use.
@MainActor
func applying(
    _ inputPath: String,
    _ outputPath: String,
    _ makeCommand: (DocumentSession) throws -> any Command<DocumentState>
) {
    requireDistinct(inputPath, outputPath)
    let session = DocumentSession(document: load(inputPath))
    do {
        let command = try makeCommand(session)
        try session.apply(command)
        print(command.summary)
        write(session.document, to: outputPath)
    } catch {
        die(message(error))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let verb = arguments.first else { print(usage); exit(0) }

switch verb {

case "ask":
    // Exercises the full assistant loop headlessly: model -> Intent -> executor.
    guard arguments.count >= 3 else { die("usage: pdfeng ask <file.pdf> \"<request>\"") }
    let askPath = arguments[1]
    let askRequest = arguments[2]
    final class AskDone: @unchecked Sendable { var finished = false }
    let askState = AskDone()
    Task { @MainActor in
        let session = DocumentSession(document: load(askPath))
        let llm = LocalLLM()
        let intent = await llm.intent(for: askRequest, pageCount: session.pageCount)
        print("intent:  \(intent)")
        print("summary: \(intent.summary)")
        print("mutates: \(intent.mutatesDocument)  needsConfirm: \(intent.needsConfirmation)")
        // Auto-confirm here: this is a diagnostic path, and the GUI prompts.
        let outcome = IntentExecutor.execute(intent, on: session, confirmed: true)
        print("result:  \(outcome.message)")
        if outcome.didMutate, arguments.count >= 4 {
            requireDistinct(askPath, arguments[3])
            write(session.document, to: arguments[3])
        }
        askState.finished = true
    }
    while !askState.finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

case "convert":
    // Word, RTF, OpenDocument, text, Markdown, CSV and images (and existing
    // PDFs) combined, in the order given, into one PDF.
    guard arguments.count >= 3 else { die("usage: pdfeng convert <out.pdf> <file> [file...]") }
    let convertOutput = arguments[1]
    let convertInputs = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
    for input in convertInputs { requireDistinct(input.path, convertOutput) }
    do {
        let data = try DocumentConverter.pdfData(combining: Array(convertInputs))
        writeOutput(data, to: convertOutput, detail: "\(PDFDocument(data: data)?.pageCount ?? 0) pages")
    } catch {
        die(message(error))
    }

case "flatten":
    guard arguments.count >= 3 else { die("usage: pdfeng flatten <in.pdf> <out.pdf>") }
    requireDistinct(arguments[1], arguments[2])
    do {
        let data = try PDFFlattener.flattenedData(from: load(arguments[1]))
        writeOutput(data, to: arguments[2], detail: "annotations baked in")
    } catch {
        die(message(error))
    }

case "html":
    guard arguments.count >= 2 else { die("usage: pdfeng html <in.html> [out.pdf]") }
    let htmlSource = URL(fileURLWithPath: arguments[1])
    let htmlTarget = arguments.count >= 3
        ? URL(fileURLWithPath: arguments[2])
        : htmlSource.deletingPathExtension().appendingPathExtension("pdf")
    requireDistinct(htmlSource.path, htmlTarget.path)
    // Same RunLoop bridge as `ocr`: HTMLConverter is @MainActor, so blocking
    // the main thread would deadlock it.
    final class HTMLDone: @unchecked Sendable { var finished = false; var failure: Error? }
    let htmlState = HTMLDone()
    Task { @MainActor in
        do {
            let converter = HTMLConverter()
            try await converter.convert(fileAt: htmlSource, to: htmlTarget)
            if let document = PDFDocument(url: htmlTarget) {
                print("pages: \(document.pageCount)")
            }
            print("wrote \(htmlTarget.path)")
        } catch {
            htmlState.failure = error
        }
        htmlState.finished = true
    }
    while !htmlState.finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if let failure = htmlState.failure {
        die(message(failure))
    }

case "info":
    guard arguments.count >= 2 else { die("usage: pdfeng info <file.pdf>") }
    let document = load(arguments[1])
    print("pages:     \(document.pageCount)")
    if let attributes = document.documentAttributes {
        for key in ["Title", "Author", "Producer", "Creator"] {
            if let value = attributes[key] as? String, !value.isEmpty {
                print("\(key.lowercased()):\(String(repeating: " ", count: max(1, 10 - key.count)))\(value)")
            }
        }
    }
    print("encrypted: \(document.isEncrypted)")
    print("locked:    \(document.isLocked)")
    // Flags whether OCR would help — the first question about any scan.
    let withText = (0..<document.pageCount).filter {
        !(document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.count
    print("pages with text: \(withText)/\(document.pageCount)")

case "text":
    guard arguments.count >= 2 else { die("usage: pdfeng text <file.pdf> [pages]") }
    let document = load(arguments[1])
    if arguments.count >= 3 {
        let indices = pageList(arguments[2], pageCount: document.pageCount)
        for index in indices {
            // A header per page only when there are several, so single-page
            // output stays pipe-friendly.
            if indices.count > 1 { print("--- page \(index + 1) ---") }
            print(document.page(at: index)?.string ?? "")
        }
    } else {
        print(document.string ?? "")
    }

case "search":
    guard arguments.count >= 3 else { die("usage: pdfeng search <file.pdf> <query>") }
    let document = load(arguments[1])
    let hits = document.findString(arguments[2], withOptions: [.caseInsensitive])
    print("\(hits.count) match\(hits.count == 1 ? "" : "es")")
    for hit in hits {
        guard let page = hit.pages.first else { continue }
        let number = document.index(for: page) + 1
        let text = (hit.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        print("  page \(number): \(text)")
    }

case "merge":
    guard arguments.count >= 4 else { die("usage: pdfeng merge <out.pdf> <in1.pdf> <in2.pdf> [...]") }
    let output = arguments[1]
    for path in arguments.dropFirst(2) { requireDistinct(path, output) }
    let merged = PDFDocument()
    do {
        for path in arguments.dropFirst(2) {
            let incoming = load(path)
            // graftAll copies, so no source document is ever aliased into the
            // result.
            try PageGraft.graftAll(from: incoming, into: merged, at: merged.pageCount)
            print("  + \(path) (\(incoming.pageCount) pages)")
        }
    } catch {
        die(message(error))
    }
    write(merged, to: output)

case "rotate":
    guard arguments.count >= 5 else {
        die("usage: pdfeng rotate <in.pdf> <out.pdf> <degrees> <pages>")
    }
    guard let degrees = Int(arguments[3]) else { die("degrees must be a whole number such as 90 or -90") }
    do { try RotatePagesCommand.validate(degrees: degrees) } catch { die(message(error)) }
    let pages = arguments[4]
    MainActor.assumeIsolated {
        applying(arguments[1], arguments[2]) { session in
            RotatePagesCommand(
                pageIndices: pageList(pages, pageCount: session.pageCount),
                degrees: degrees
            )
        }
    }

case "delete":
    guard arguments.count >= 4 else {
        die("usage: pdfeng delete <in.pdf> <out.pdf> <pages>")
    }
    let pages = arguments[3]
    MainActor.assumeIsolated {
        applying(arguments[1], arguments[2]) { session in
            DeletePagesCommand(pageIndices: pageList(pages, pageCount: session.pageCount))
        }
    }

case "move":
    guard arguments.count >= 5 else { die("usage: pdfeng move <in.pdf> <out.pdf> <from> <to>") }
    guard let from = Int(arguments[3]), let to = Int(arguments[4]) else {
        die("from and to must be page numbers")
    }
    MainActor.assumeIsolated {
        applying(arguments[1], arguments[2]) { _ in
            MovePageCommand(from: from - 1, to: to - 1)
        }
    }

case "extract":
    guard arguments.count >= 4 else { die("usage: pdfeng extract <in.pdf> <out.pdf> <pages>") }
    requireDistinct(arguments[1], arguments[2])
    let source = load(arguments[1])
    let indices = pageList(arguments[3], pageCount: source.pageCount)
    do {
        // PageGraft copies, so the source document is never damaged.
        let extracted = try AtomicPDFWriter.extract(pages: indices, from: source)
        print("extracted \(indices.count) page\(indices.count == 1 ? "" : "s")")
        write(extracted, to: arguments[2])
    } catch {
        die(message(error))
    }

case "split":
    guard arguments.count >= 5, arguments[3] == "--every", let size = Int(arguments[4]) else {
        die("usage: pdfeng split <in.pdf> <out-dir> --every <N>")
    }
    guard size >= 1 else { die("--every must be at least 1 page") }
    let splitInput = URL(fileURLWithPath: arguments[1])
    let splitDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let source = load(arguments[1])
    do {
        try FileManager.default.createDirectory(at: splitDirectory, withIntermediateDirectories: true)
    } catch {
        die("could not create \(splitDirectory.path): \(error.localizedDescription)")
    }
    let base = splitInput.deletingPathExtension().lastPathComponent
    for (number, chunk) in PageRange.chunks(pageCount: source.pageCount, size: size).enumerated() {
        let path = splitDirectory.appendingPathComponent("\(base)-\(number + 1).pdf").path
        requireDistinct(arguments[1], path)
        do {
            write(try AtomicPDFWriter.extract(pages: chunk, from: source), to: path)
        } catch {
            die(message(error))
        }
    }

case "ocr":
    guard arguments.count >= 3 else { die("usage: pdfeng ocr <in.pdf> <out.pdf>") }
    requireDistinct(arguments[1], arguments[2])
    // Bridged with a nested RunLoop rather than a DispatchSemaphore: the
    // pipeline reports progress on the main actor, and `semaphore.wait()` would
    // block the main thread that callback needs — a guaranteed deadlock.
    // Spinning the RunLoop keeps the main thread serviceable while we wait.
    let ocrInput = URL(fileURLWithPath: arguments[1])
    let ocrOutput = URL(fileURLWithPath: arguments[2])
    final class Done: @unchecked Sendable { var finished = false; var failure: Error? }
    let state = Done()
    Task { @MainActor in
        do {
            let result = try await OCRPipeline.addTextLayer(
                from: ocrInput, to: ocrOutput,
                onProgress: { progress in
                    print("  page \(progress.pageIndex + 1)/\(progress.pageCount) — \(progress.runsFound) runs")
                }
            )
            print("pages processed: \(result.pagesProcessed)")
            print("pages skipped (already had text): \(result.pagesSkipped)")
            print("text runs written: \(result.runsWritten)")
            if result.usedLineFallback {
                print("note: some pages used line-level boxes (words were unavailable)")
            }
            print("wrote \(ocrOutput.path)")
        } catch {
            state.failure = error
        }
        state.finished = true
    }
    while !state.finished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if let failure = state.failure {
        die(message(failure))
    }

case "markdown":
    guard arguments.count >= 2 else { die("usage: pdfeng markdown <file.pdf> [out.md]") }
    let document = load(arguments[1])
    let name = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent
    let markdown = MarkdownExporter.markdown(from: document, filename: name)
    if arguments.count >= 3 {
        requireDistinct(arguments[1], arguments[2])
        writeOutput(Data(markdown.utf8), to: arguments[2], detail: "\(markdown.count) characters")
    } else {
        print(markdown)
    }

case "ast":
    guard arguments.count >= 2 else { die("usage: pdfeng ast <file.pdf> [out.json]") }
    let document = load(arguments[1])
    let name = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent
    let ast = MarkdownExporter.buildAST(from: document, filename: name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(ast) else { die("could not encode AST") }
    if arguments.count >= 3 {
        requireDistinct(arguments[1], arguments[2])
        writeOutput(data, to: arguments[2], detail: "\(ast.blocks.count) blocks")
    } else {
        print(String(decoding: data, as: UTF8.self))
    }

case "-h", "--help", "help":
    print(usage)

default:
    die("unknown command '\(verb)'\n\n\(usage)")
}
