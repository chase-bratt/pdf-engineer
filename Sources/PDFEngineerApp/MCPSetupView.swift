import AppKit
import SwiftUI

/// Shows the user how to connect Claude to this app.
///
/// We must never silently write into another
/// app's configuration. So this displays the exact JSON and offers to copy it —
/// the user pastes it themselves, which keeps the action visible and reversible.
struct MCPSetupView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Path to the helper inside our own bundle, falling back to a dev build.
    private var helperPath: String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "pdfeng-mcp")?.path {
            return bundled
        }
        let devBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/pdfeng-mcp")
        return devBuild.path
    }

    private var configJSON: String {
        """
        {
          "mcpServers": {
            "pdf-engineer": {
              "command": "\(helperPath)",
              "args": ["/path/to/your.pdf"]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude")
                .font(.title2.bold())

            Text("""
                Add this to your Claude config, then restart Claude. Replace the \
                path in "args" with the PDF you want Claude to work on.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                ScrollView {
                    Text(configJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }

            Text("Claude Code: ~/.claude.json   ·   Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Claude gets 8 tools: read info, page text, search, export Markdown, rotate, delete, move pages, and read the change history. Every edit it makes is undoable and labelled as assistant-made.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(copied ? "Copied" : "Copy Configuration") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configJSON, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
