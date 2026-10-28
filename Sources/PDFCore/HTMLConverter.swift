import Foundation
import PDFKit
import WebKit

/// Converts HTML to PDF using WebKit.
///
/// Saving a webpage as HTML is far faster than printing it to PDF, so this
/// turns that habit into a first-class import path: drop the `.html` in and get
/// a real PDF.
///
/// ## Why WebKit
///
/// `WKWebView.createPDF(configuration:)` works headlessly — verified with no
/// window attached — and emits **real text**, not a raster. The output is
/// selectable and searchable immediately, with no OCR pass. It is also the same
/// engine Safari uses, so a page that looks right in Safari converts right.
///
/// ## Concurrency
///
/// `WKWebView` is main-thread only, hence `@MainActor`. Conversion is `async`
/// and bridges WebKit's delegate callbacks to a continuation.
@MainActor
public final class HTMLConverter: NSObject {

    /// Page geometry for the rendered PDF.
    public struct PageSize: Sendable {
        public let width: CGFloat
        public let height: CGFloat

        /// US Letter at 96 CSS pixels per inch, which is what WebKit lays out
        /// against. 816×1056 px == 8.5×11 in.
        public static let letter = PageSize(width: 816, height: 1056)

        /// A4 at the same scale.
        public static let a4 = PageSize(width: 794, height: 1123)

        public init(width: CGFloat, height: CGFloat) {
            self.width = width
            self.height = height
        }
    }

    public enum ConversionError: Error, LocalizedError {
        case loadFailed(String)
        case pdfGenerationFailed(String)
        case timedOut
        case unreadableFile(URL)

        public var errorDescription: String? {
            switch self {
            case let .loadFailed(reason):
                return "The page could not be loaded: \(reason)"
            case let .pdfGenerationFailed(reason):
                return "The PDF could not be generated: \(reason)"
            case .timedOut:
                return "The page took too long to load. It may reference resources that are unavailable."
            case let .unreadableFile(url):
                return "Could not read \(url.lastPathComponent)."
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Cancelled once the page loads, so the timeout cannot fire afterwards.
    private var loadWatchdog: Task<Void, Never>?

    /// The load this converter started. Callbacks for any other navigation are
    /// ignored, so a refused `<meta refresh>` cannot end the wait early.
    private var initialNavigation: WKNavigation?

    /// Whether the one permitted main-frame navigation has been decided.
    private var initialNavigationDecided = false

    /// How long to wait for a page to finish loading.
    ///
    /// Remote resources are blocked, so this guards only against WebKit
    /// itself stalling on a local file; without a cap a stall would leave the
    /// conversion waiting forever.
    private let loadTimeout: Duration

    public override init() {
        self.loadTimeout = .seconds(30)
        super.init()
    }

    /// Tests use a short timeout so a regression that lets a request hang
    /// fails quickly instead of stalling the suite.
    init(loadTimeout: Duration) {
        self.loadTimeout = loadTimeout
        super.init()
    }

    /// Converts an HTML file to PDF data.
    ///
    /// The file is untrusted — typically a page saved from the web — so the
    /// load is offline and contained (see ``makeConfiguration(allowingFilesIn:)``):
    /// it may read files in its own folder, which is how browsers save pages
    /// (`page.html` plus `page_files/`), and nothing else.
    ///
    /// - Parameters:
    ///   - url: A local `.html` file. Its directory is the only place assets
    ///     resolve from.
    ///   - pageSize: Output page geometry.
    public func convert(
        fileAt url: URL,
        pageSize: PageSize = .letter
    ) async throws -> Data {
        // Checked up front so a missing file gets a clear message rather than
        // WebKit's generic load failure.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.unreadableFile(url)
        }
        let folder = url.deletingLastPathComponent()
        return try await render(pageSize: pageSize, allowingFilesIn: folder) { view in
            // Read access is granted to the folder only, so even a path that
            // slips past the content rules cannot reach the rest of the disk.
            view.loadFileURL(url, allowingReadAccessTo: folder)
        }
    }

    /// Converts an HTML string to PDF data.
    ///
    /// The same containment applies as for files: with a `baseURL`, only files
    /// inside that folder load; without one, no files at all.
    public func convert(
        html: String,
        baseURL: URL? = nil,
        pageSize: PageSize = .letter
    ) async throws -> Data {
        let folder = baseURL.flatMap { $0.isFileURL ? $0 : nil }
        return try await render(pageSize: pageSize, allowingFilesIn: folder) { view in
            view.loadHTMLString(html, baseURL: folder)
        }
    }

    /// Loads a page into a contained web view and prints it.
    private func render(
        pageSize: PageSize,
        allowingFilesIn folder: URL?,
        load: (WKWebView) -> WKNavigation?
    ) async throws -> Data {
        let (configuration, ruleStore) = try await Self.makeConfiguration(allowingFilesIn: folder)
        defer { Self.discard(ruleStore) }

        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
            configuration: configuration
        )
        view.navigationDelegate = self
        webView = view
        initialNavigationDecided = false
        defer {
            webView = nil
            continuation = nil
            initialNavigation = nil
        }

        // Wait for the load, with a timeout so a stalled load cannot hang us.
        //
        // A plain continuation plus a watchdog task, rather than a task group:
        // the isolation checker cannot reason about a @MainActor continuation
        // captured inside a throwing task group ("pattern that the region-based
        // isolation checker does not understand"). `resumed` guards against a
        // double resume if the load and the watchdog race.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let watchdog = Task { @MainActor [loadTimeout] in
                try? await Task.sleep(for: loadTimeout)
                guard !Task.isCancelled, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: ConversionError.timedOut)
            }
            self.loadWatchdog = watchdog
            initialNavigation = load(view)
        }
        loadWatchdog?.cancel()
        loadWatchdog = nil

        return try await withCheckedThrowingContinuation { continuation in
            view.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case let .success(data):
                    continuation.resume(returning: data)
                case let .failure(error):
                    continuation.resume(
                        throwing: ConversionError.pdfGenerationFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    // MARK: - Containment

    /// A web view configuration that cannot reach the network or keep state.
    ///
    /// Opening a saved page must not phone home: a remote image or font is a
    /// tracking beacon that tells the page's author who opened it and when,
    /// and cookies from a persistent store would identify the user. So:
    ///
    /// - **No JavaScript.** Scripts are useless offline, can block
    ///   `didFinish`, and a saved page's content is already in the markup.
    /// - **Ephemeral data store.** No cookies, cache or storage in or out.
    /// - **Content rules** block every URL except `data:`, `about:` and — when
    ///   `folder` is given — `file:` URLs inside it. Remote images, CSS,
    ///   fonts, iframes and sockets never leave the machine, and a page cannot
    ///   pull in files from elsewhere on disk.
    ///
    /// The rule list is compiled into a throwaway store, returned so the
    /// caller can delete it: the default store would accumulate one compiled
    /// list per folder ever converted.
    static func makeConfiguration(
        allowingFilesIn folder: URL?
    ) async throws -> (WKWebViewConfiguration, URL) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfeng-rules-\(UUID().uuidString)", isDirectory: true)
        guard let store = WKContentRuleListStore(url: storeURL) else {
            throw ConversionError.loadFailed("the offline content rules could not be set up")
        }
        let rules: WKContentRuleList?
        do {
            rules = try await store.compileContentRuleList(
                forIdentifier: "offline", encodedContentRuleList: contentRules(allowingFilesIn: folder)
            )
        } catch {
            discard(storeURL)
            throw ConversionError.loadFailed("the offline content rules could not be compiled: \(error.localizedDescription)")
        }
        guard let rules else {
            discard(storeURL)
            throw ConversionError.loadFailed("the offline content rules could not be compiled")
        }
        configuration.userContentController.add(rules)
        return (configuration, storeURL)
    }

    /// The WebKit content-blocker JSON behind ``makeConfiguration(allowingFilesIn:)``.
    ///
    /// Block-everything first, then exceptions: later `ignore-previous-rules`
    /// entries lift the block for the URLs that match them. An allow-list
    /// rather than a deny-list, so a scheme nobody thought of (`ws:`, `ftp:`,
    /// some future one) is blocked by default.
    nonisolated static func contentRules(allowingFilesIn folder: URL?) -> String {
        var filters = ["^data:", "^about:"]
        if let folder {
            // Percent-encoded, which is the form WebKit matches against, and
            // with a trailing slash so `/docs` does not also admit `/docs-old`.
            var prefix = folder.standardizedFileURL.absoluteString
            if !prefix.hasSuffix("/") { prefix += "/" }
            filters.append("^" + escapeRegex(prefix))
        }
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let allows = filters.map { filter in
            let json = filter.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"trigger":{"url-filter":""# + json + #""},"action":{"type":"ignore-previous-rules"}}"#
        }
        return "[" + ([block] + allows).joined(separator: ",") + "]"
    }

    /// Escapes the regex metacharacters WebKit's url-filter understands, so a
    /// folder name like `Q1 (draft)` is matched literally.
    nonisolated static func escapeRegex(_ text: String) -> String {
        let special: Set<Character> = ["\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "^", "$", "|"]
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    private static func discard(_ storeURL: URL) {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Converts and writes to disk in one step, paginating the result.
    ///
    /// `createPDF` emits a single tall page (see ``PDFPaginator``), so the raw
    /// output is sliced into sheets before saving. Without this a saved article
    /// becomes one 10,000-point page that prints badly and cannot be
    /// reorganised.
    public func convert(
        fileAt source: URL,
        to destination: URL,
        pageSize: PageSize = .letter,
        paginate: Bool = true
    ) async throws {
        let data = try await convert(fileAt: source, pageSize: pageSize)
        try Self.write(data, to: destination, paginate: paginate)
    }

    /// Writes PDF data, slicing it into sheets when needed.
    ///
    /// Never replaces an existing file and never writes through a symbolic
    /// link (see ``AtomicPDFWriter/writeNew(_:to:)``): the destination is
    /// usually derived from an untrusted file's name, so anything already
    /// there — including a planted symlink — is left alone and reported.
    ///
    /// `nonisolated`: pure data processing with no WebKit involvement.
    ///
    /// - Throws: ``PDFCoreError/destinationExists(path:)`` if something is
    ///   already at `destination`.
    public nonisolated static func write(_ data: Data, to destination: URL, paginate: Bool = true) throws {
        guard paginate,
              let document = PDFDocument(data: data),
              PDFPaginator.needsPagination(document),
              let paginated = PDFPaginator.paginate(document)
        else {
            try AtomicPDFWriter.writeNew(data, to: destination)
            return
        }
        try AtomicPDFWriter.writeNew(paginated, to: destination)
    }

    /// Whether a URL looks like something this converter handles.
    ///
    /// `nonisolated` because it only inspects a path extension: callers check
    /// this to decide *whether* to start a conversion, often from outside the
    /// main actor, and requiring an actor hop for a string comparison would be
    /// noise.
    ///
    /// `.webarchive` and `.mhtml` are deliberately absent: they are binary or
    /// MIME containers, not HTML text, so claiming them would only lead to a
    /// guaranteed "could not read" failure after the user picked the file.
    public nonisolated static func isHTML(_ url: URL) -> Bool {
        ["html", "htm", "xhtml"].contains(
            url.pathExtension.lowercased()
        )
    }
}

extension HTMLConverter: WKNavigationDelegate {

    /// Allows exactly one navigation: the load this converter started.
    ///
    /// Everything after it is cancelled — a `<meta http-equiv="refresh">`
    /// (which works with JavaScript off), a link target, a popup, or an
    /// iframe pointing at another file. Content rules already keep these
    /// offline; this keeps them from replacing or adding to what gets
    /// printed, so the PDF is always the file the user chose. `about:` frames
    /// (`about:blank`, `srcdoc`) are inert and stay allowed.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let frame = navigationAction.targetFrame else { return .cancel }
        if frame.isMainFrame {
            guard !initialNavigationDecided else { return .cancel }
            initialNavigationDecided = true
            return .allow
        }
        return navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }

    /// Whether a callback concerns the load we started.
    ///
    /// `initialNavigation` is nil only if WebKit returned no navigation
    /// object, in which case there is nothing to compare and every callback
    /// is taken as ours, as before.
    private func isInitial(_ navigation: WKNavigation?) -> Bool {
        initialNavigation == nil || navigation === initialNavigation
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isInitial(navigation) else { return }
        continuation?.resume()
        continuation = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard isInitial(navigation) else { return }
        continuation?.resume(throwing: ConversionError.loadFailed(error.localizedDescription))
        continuation = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard isInitial(navigation) else { return }
        continuation?.resume(throwing: ConversionError.loadFailed(error.localizedDescription))
        continuation = nil
    }
}
