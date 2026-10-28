import AppKit
import PDFCore
import SwiftUI

/// Handles files opened from outside the app.
///
/// Needed because this app uses `WindowGroup` rather than `DocumentGroup` (see
/// `PDFEngineerApp`). `DocumentGroup` would wire up Finder double-clicks, "Open
/// With", and `open -a` for free; with `WindowGroup` the app must implement
/// `application(_:open:)` itself, or launching with a file argument opens an
/// empty window and silently drops the file.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the app at launch so the delegate can reach the controller.
    ///
    /// `nonisolated(unsafe)` because AppKit constructs the delegate before any
    /// SwiftUI state exists, so this is assigned once on the main thread during
    /// launch and only read on the main thread afterwards.
    nonisolated(unsafe) static weak var controller: AppController?

    /// Called for Finder double-clicks, "Open With", `open -a`, and drops on
    /// the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        // One window, one document for now, so only the first PDF is opened.
        // Multi-document windows are future work.
        guard let url = urls.first(where: {
            $0.pathExtension.lowercased() == "pdf" || HTMLConverter.isHTML($0) || DocumentConverter.canConvert($0)
        }) else { return }
        Task { @MainActor in
            Self.controller?.open(url)
        }
    }

    /// Keeps the app running with no windows, which is the macOS convention for
    /// a document app — the Dock icon stays available to open another file.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs would show the single shared document twice.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Quitting with unsaved edits asks first, like every Mac document app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            (Self.controller?.confirmDiscardingChanges() ?? true) ? .terminateNow : .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
