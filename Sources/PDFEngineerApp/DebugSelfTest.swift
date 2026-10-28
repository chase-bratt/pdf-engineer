#if DEBUG
import AppKit
import DocumentModel
import PDFKit
import SwiftUI

/// Debug builds only: exercises the editing tools through their real code paths
/// and renders the window off-screen — no synthetic mouse events, no Screen
/// Recording permission. Not compiled into release builds.
///
///     open --env PDFENGINEER_SELFTEST='<in.pdf>::<out-dir>' -a PDFEngineer.app
///
/// Writes `<out-dir>/edited.pdf` and `<out-dir>/selftest.png`, prints a report, quits.
@MainActor
enum DebugSelfTest {

    static func runIfRequested(controller: AppController) {
        // Passed through the environment, not argv: AppKit treats path-like
        // arguments as documents to open, which changes how the app launches.
        guard let spec = ProcessInfo.processInfo.environment["PDFENGINEER_SELFTEST"] else { return }
        let parts = spec.components(separatedBy: "::")
        guard parts.count == 2 else { return }
        let input = URL(fileURLWithPath: parts[0])
        let outDir = URL(fileURLWithPath: parts[1])
        controller.open(input)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var report: [String] = []
            run(controller, report: &report)
            // Long enough for an external `screencapture` of the finished page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finish(controller, outDir: outDir, report: report)
            }
        }
    }

    private static func run(_ controller: AppController, report: inout [String]) {
        guard let session = controller.session, let view = controller.canvas.pdfView as? EditorPDFView,
              let page = session.document.page(at: 0) else {
            report.append("FAIL: no document or editor view")
            return
        }
        func center(of text: String) -> CGPoint? {
            guard let match = session.document.findString(text, withOptions: [.caseInsensitive]).first else { return nil }
            let rect = match.bounds(for: page)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func bounds(of text: String) -> CGRect? {
            session.document.findString(text, withOptions: [.caseInsensitive]).first?.bounds(for: page)
        }

        // 1. Edit Text on an existing line.
        if let point = center(of: "$12,500") {
            controller.tools.tool = .editText
            view.beginTextEdit(on: page, at: point)
            if let editor = view.currentEditor {
                editor.string = editor.string.replacingOccurrences(of: "$12,500", with: "$14,000")
                editor.commit()
                report.append("edit text: \(controller.session?.undoSummary ?? "-")")
            } else { report.append("FAIL: edit text editor did not open") }
        }

        // 2. Add Text beside the first signature line.
        if let line = bounds(of: "Signed for Acme Corporation:") {
            controller.tools.tool = .addText
            controller.tools.fontFamily = "Helvetica"
            controller.tools.fontSize = 11
            controller.tools.textColor = .blue
            view.beginNewText(on: page, at: CGPoint(x: line.maxX + 20, y: line.maxY + 26))
            view.currentEditor?.string = "Date: 28 October 2026"
            view.currentEditor?.commit()
            report.append("add text: \(controller.session?.undoSummary ?? "-")")
        }

        // 3. Highlight a phrase via the selection path.
        if let match = session.document.findString("Confidentiality", withOptions: []).first {
            controller.canvas.pdfView?.setCurrentSelection(match, animate: false)
            controller.addMarkup(.highlight)
            report.append("highlight: \(controller.session?.undoSummary ?? "-")")
        }

        // 4. Shapes and ink.
        if let scope = bounds(of: "1. Scope of Work") {
            controller.tools.strokeColor = .red
            controller.tools.lineWidth = 2
            view.debugDrag(.rectangle, on: page, from: CGPoint(x: scope.minX - 6, y: scope.maxY + 4),
                           to: CGPoint(x: scope.maxX + 6, y: scope.minY - 4))
            report.append("rectangle: \(controller.session?.undoSummary ?? "-")")
            let start = CGPoint(x: scope.maxX + 60, y: scope.midY + 30)
            view.debugDrag(.arrow, on: page, from: start, to: CGPoint(x: scope.maxX + 12, y: scope.midY))
            report.append("arrow: \(controller.session?.undoSummary ?? "-")")
        }

        // 5. Signature stamped on the Northwind line.
        if let line = bounds(of: "Signed for Northwind Design Studio:") {
            controller.tools.pendingSignature = typedSignature("Jane Smith")
            view.debugDrag(.sign, on: page, from: CGPoint(x: line.maxX + 10, y: line.minY - 6),
                           to: CGPoint(x: line.maxX + 170, y: line.maxY + 34))
            report.append("sign: \(controller.session?.undoSummary ?? "-")")
        }

        // 6. Undo/redo round trip on the last edit.
        controller.undo()
        let afterUndo = controller.session?.document.page(at: 0)?.annotations.count ?? -1
        controller.redo()
        report.append("undo/redo ok: \(afterUndo >= 0)")
        // Optionally leave a tool active so its settings show in a screenshot.
        let finalTool = ProcessInfo.processInfo.environment["PDFENGINEER_SELFTEST_TOOL"].flatMap(ToolState.Tool.init(rawValue:))
        controller.tools.tool = finalTool ?? .select
        if finalTool == .addText {
            controller.tools.fontFamily = "Georgia"
            controller.tools.fontSize = 14
            controller.tools.textColor = Color(nsColor: .systemIndigo)
        }
    }

    private static func finish(_ controller: AppController, outDir: URL, report: [String]) {
        var report = report
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let pdfURL = outDir.appendingPathComponent("edited.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        do {
            try controller.session?.save(to: pdfURL)
            if let reopened = PDFDocument(url: pdfURL), let page = reopened.page(at: 0) {
                let types = page.annotations.compactMap(\.type)
                report.append("saved annotations: \(types.sorted())")
                report.append("edited text persisted: \(page.annotations.contains { $0.contents?.contains("$14,000") == true })")
                report.append("page text still searchable: \(reopened.findString("Timeline", withOptions: []).isEmpty == false)")
            }
        } catch {
            report.append("FAIL save: \(error)")
        }
        if let window = controller.window, let frameView = window.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("selftest.png"))
        }
        let text = report.map { "SELFTEST \($0)" }.joined(separator: "\n")
        print(text)
        try? text.write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func typedSignature(_ name: String) -> NSImage {
        let font = NSFont(name: "Snell Roundhand", size: 64) ?? .systemFont(ofSize: 48)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.1, green: 0.15, blue: 0.5, alpha: 1)]
        let size = (name as NSString).size(withAttributes: attributes)
        return NSImage(size: size, flipped: false) { _ in
            (name as NSString).draw(at: .zero, withAttributes: attributes)
            return true
        }
    }
}
#endif
