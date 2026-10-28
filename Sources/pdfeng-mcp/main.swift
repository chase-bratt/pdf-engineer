import DocumentModel
import Foundation
import MCP
import MCPServer
import PDFKit

// MCP stdio helper. Claude Code and Claude Desktop both launch an MCP server as
// a child process and speak JSON-RPC over stdio, so this is the transport they
// expect.
//
// ## Why this opens a file rather than attaching to the running app
//
// The ideal design is a stdio helper + XPC to the GUI app, so Claude would
// operate on the document the user is looking at. That remains the goal, but it
// needs a signed, entitled bundle with app-group mach registration — which the
// prototype could NOT verify end to end.
//
// So v1 is file-scoped: the helper owns its own DocumentSession over a path.
// Claude edits files; the user reopens them in the app. Less magical, but it
// works today and needs no entitlements.
//
// Edits live in this process's memory until Claude calls `save_document`,
// which writes atomically back to <file.pdf> — the session keeps the URL it
// was opened from. Without that tool every edit vanished on exit.
//
// The tool surface does not change when XPC lands — only this provider does.
// That is the whole reason `DocumentProviding` is a protocol.
//
// Usage:
//   pdfeng-mcp <file.pdf>    serve one document
//   pdfeng-mcp               serve with no document (tools report none open)

/// Holds one document opened from a path.
///
/// `@unchecked Sendable` because it hands out a `@MainActor`-confined session:
/// the session itself enforces isolation, and this box only stores it.
final class FileDocumentProvider: DocumentProviding, @unchecked Sendable {

    private let session: DocumentSession?

    @MainActor
    init(path: String?) {
        guard let path else { session = nil; return }
        // Standardised so `save_document` reports, and writes to, a clean path.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        session = try? DocumentSession(contentsOf: url)

        if session == nil {
            FileHandle.standardError.write(
                Data("warning: could not open \(path)\n".utf8)
            )
        }
    }

    @MainActor
    func currentSession() -> DocumentSession? { session }
}

@main
struct Main {
    static func main() async {
        let path = CommandLine.arguments.dropFirst().first

        // Diagnostics go to stderr: stdout is the JSON-RPC channel, and
        // anything else written there corrupts the protocol stream.
        FileHandle.standardError.write(
            Data("pdfeng-mcp starting\(path.map { " with \($0)" } ?? "")\n".utf8)
        )

        let provider = await MainActor.run { FileDocumentProvider(path: path) }
        let server = PDFToolServer(provider: provider)

        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}
