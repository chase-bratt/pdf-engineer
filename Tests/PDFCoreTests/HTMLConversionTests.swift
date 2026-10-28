import Testing
import PDFKit
import Foundation
@testable import PDFCore

/// HTML → PDF import, and the pagination that WebKit does not do for us.
@Suite("HTMLConversion")
struct HTMLConversionTests {

    // MARK: - File type detection

    @Test("HTML extensions are recognised")
    func recognisesHTML() {
        for ext in ["html", "htm", "xhtml", "HTML", "Htm"] {
            let url = URL(fileURLWithPath: "/tmp/page.\(ext)")
            #expect(HTMLConverter.isHTML(url), "\(ext) should be recognised")
        }
    }

    @Test("PDFs and other files are not treated as HTML")
    func rejectsNonHTML() {
        #expect(!HTMLConverter.isHTML(URL(fileURLWithPath: "/tmp/doc.pdf")))
        #expect(!HTMLConverter.isHTML(URL(fileURLWithPath: "/tmp/image.png")))
        #expect(!HTMLConverter.isHTML(URL(fileURLWithPath: "/tmp/noextension")))
    }

    @Test("web archives are not claimed, since they would always fail to read")
    func rejectsArchives() {
        #expect(!HTMLConverter.isHTML(URL(fileURLWithPath: "/tmp/page.webarchive")))
        #expect(!HTMLConverter.isHTML(URL(fileURLWithPath: "/tmp/page.mhtml")))
    }

    @Test("a Latin-1 file falls back instead of failing as unreadable")
    @MainActor
    func latin1Fallback() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latin1-\(UUID().uuidString).html")
        // 0xE9 is "é" in Latin-1 and an invalid byte sequence in UTF-8.
        var bytes = Data("<html><body><p>caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data(" WOMBAT</p></body></html>".utf8))
        try bytes.write(to: url)

        let data = try await HTMLConverter().convert(fileAt: url)
        let text = PDFDocument(data: data)?.string ?? ""
        #expect(text.contains("WOMBAT"))
        #expect(text.contains("café"))
    }

    // MARK: - Conversion

    @Test("HTML converts to a PDF with real, extractable text")
    @MainActor
    func convertsToRealText() async throws {
        let converter = HTMLConverter()
        let data = try await converter.convert(
            html: "<html><body><h1>ZANZIBAR</h1><p>Body text here.</p></body></html>"
        )

        let document = try #require(PDFDocument(data: data))
        let text = document.page(at: 0)?.string ?? ""
        // The whole point of using WebKit over a rasteriser: the output is
        // selectable and searchable with no OCR pass.
        #expect(text.contains("ZANZIBAR"))
        #expect(text.contains("Body text"))
    }

    @Test("a converted document is immediately searchable")
    @MainActor
    func convertedIsSearchable() async throws {
        let converter = HTMLConverter()
        let data = try await converter.convert(
            html: "<html><body><p>find QUOKKA here</p></body></html>"
        )
        let document = try #require(PDFDocument(data: data))
        #expect(document.findString("quokka", withOptions: [.caseInsensitive]).count == 1)
    }

    @Test("table structure survives conversion")
    @MainActor
    func tablesSurvive() async throws {
        let converter = HTMLConverter()
        let data = try await converter.convert(
            html: """
                <html><body><table>
                <tr><th>Quarter</th><th>Amount</th></tr>
                <tr><td>Q1</td><td>$1,250.00</td></tr>
                </table></body></html>
                """
        )
        let text = try #require(PDFDocument(data: data)?.page(at: 0)?.string)
        #expect(text.contains("Q1"))
        #expect(text.contains("$1,250.00"))
    }

    @Test("a missing image does not fail the conversion")
    @MainActor
    func missingAssetTolerated() async throws {
        // Saved pages routinely reference assets that no longer resolve. The
        // conversion must still produce the text.
        let converter = HTMLConverter()
        let data = try await converter.convert(
            html: "<html><body><img src=\"gone.png\"><p>still here</p></body></html>"
        )
        let text = try #require(PDFDocument(data: data)?.page(at: 0)?.string)
        #expect(text.contains("still here"))
    }

    @Test("converting a file on disk works and resolves its directory")
    @MainActor
    func convertsFileOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("htmltest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("page.html")
        try "<html><body><h1>FROM DISK</h1></body></html>".write(
            to: source, atomically: true, encoding: .utf8
        )

        let destination = directory.appendingPathComponent("page.pdf")
        let converter = HTMLConverter()
        try await converter.convert(fileAt: source, to: destination)

        let text = try #require(PDFDocument(url: destination)?.page(at: 0)?.string)
        #expect(text.contains("FROM DISK"))
    }

    @Test("an unreadable path throws rather than crashing")
    @MainActor
    func unreadableFileThrows() async {
        let converter = HTMLConverter()
        await #expect(throws: (any Error).self) {
            try await converter.convert(
                fileAt: URL(fileURLWithPath: "/nonexistent/nope.html")
            )
        }
    }

    // MARK: - Containment (untrusted pages stay offline)

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("htmlsec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A listening TCP socket on 127.0.0.1, non-blocking, so a test can ask
    /// afterwards whether anything connected without waiting.
    private func makeListener() throws -> (socket: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PDFCoreError.contextCreationFailed }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw PDFCoreError.contextCreationFailed }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    @Test("remote resources are blocked: the page converts, quickly, with no connection made")
    @MainActor
    func remoteResourcesBlocked() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try makeListener()
        defer { close(listener.socket) }

        let remote = "http://127.0.0.1:\(listener.port)"
        let source = directory.appendingPathComponent("page.html")
        try """
            <html><head>
            <link rel="stylesheet" href="\(remote)/style.css">
            <style>@font-face { font-family: X; src: url(\(remote)/font.woff); }</style>
            </head><body>
            <img src="http://127.0.0.1:9/x.png">
            <img src="\(remote)/beacon.png">
            <iframe src="\(remote)/frame.html"></iframe>
            <p>OFFLINE BODY</p>
            </body></html>
            """.write(to: source, atomically: true, encoding: .utf8)

        // A short timeout bounds the test: a request left hanging would turn
        // into a timedOut failure here rather than a stalled suite.
        let clock = ContinuousClock()
        let started = clock.now
        let data = try await HTMLConverter(loadTimeout: .seconds(10)).convert(fileAt: source)
        #expect(clock.now - started < .seconds(10))

        let text = try #require(PDFDocument(data: data)?.string)
        #expect(text.contains("OFFLINE BODY"))

        // Nothing reached the listener: no beacon, stylesheet, font or frame.
        let accepted = accept(listener.socket, nil, nil)
        if accepted >= 0 { close(accepted) }
        #expect(accepted < 0, "the page made a network connection")
    }

    @Test("a meta refresh to another file does not change the output")
    @MainActor
    func metaRefreshIgnored() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "<html><body><p>HIJACKED CONTENT</p></body></html>".write(
            to: directory.appendingPathComponent("other.html"), atomically: true, encoding: .utf8
        )
        let source = directory.appendingPathComponent("page.html")
        try """
            <html><head><meta http-equiv="refresh" content="0; url=other.html"></head>
            <body><p>ORIGINAL CONTENT</p></body></html>
            """.write(to: source, atomically: true, encoding: .utf8)

        let data = try await HTMLConverter(loadTimeout: .seconds(10)).convert(fileAt: source)
        let text = try #require(PDFDocument(data: data)?.string)
        #expect(text.contains("ORIGINAL CONTENT"))
        #expect(!text.contains("HIJACKED"))
    }

    @Test("an iframe cannot pull another local file into the output")
    @MainActor
    func siblingIframeBlocked() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stands in for any readable file beside the page, e.g. in Downloads.
        try "<html><body><p>SIBLING SECRET</p></body></html>".write(
            to: directory.appendingPathComponent("private.html"), atomically: true, encoding: .utf8
        )
        let source = directory.appendingPathComponent("page.html")
        try """
            <html><body><p>VISIBLE PAGE</p>
            <iframe src="private.html" width="600" height="200"></iframe></body></html>
            """.write(to: source, atomically: true, encoding: .utf8)

        let data = try await HTMLConverter(loadTimeout: .seconds(10)).convert(fileAt: source)
        let text = try #require(PDFDocument(data: data)?.string)
        #expect(text.contains("VISIBLE PAGE"))
        #expect(!text.contains("SIBLING SECRET"))
    }

    @Test("content rules allow only the source folder, matched literally")
    func contentRulesAreScoped() throws {
        let folder = URL(fileURLWithPath: "/tmp/Q1 (draft)", isDirectory: true)
        let json = HTMLConverter.contentRules(allowingFilesIn: folder)
        let rules = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]]
        )
        #expect(rules.first?["action"]?["type"] == "block")
        #expect(rules.first?["trigger"]?["url-filter"] == ".*")
        let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] }
        // Escaped parentheses, percent-encoded space, trailing slash.
        #expect(allowed.contains(#"^file:///tmp/Q1%20\(draft\)/"#))
        #expect(!allowed.contains { $0.contains("http") })

        let noFiles = HTMLConverter.contentRules(allowingFilesIn: nil)
        #expect(!noFiles.contains("file:"))
    }

    @Test("write never overwrites an existing file")
    @MainActor
    func writeNeverOverwrites() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.pdf")
        try Data("precious".utf8).write(to: destination)

        let data = try await HTMLConverter().convert(html: "<p>new</p>")
        #expect(throws: PDFCoreError.destinationExists(path: destination.path)) {
            try HTMLConverter.write(data, to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("precious".utf8))
        // No staging file left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["out.pdf"])
    }

    @Test("write never follows a symbolic link at the destination")
    @MainActor
    func writeRefusesSymlink() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("victim.txt")
        try Data("precious".utf8).write(to: victim)
        let link = directory.appendingPathComponent("out.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        // A dangling link must be refused too, not written through.
        let dangling = directory.appendingPathComponent("dangling.pdf")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: directory.appendingPathComponent("created-by-attacker.pdf")
        )

        let data = try await HTMLConverter().convert(html: "<p>new</p>")
        #expect(throws: PDFCoreError.destinationExists(path: link.path)) {
            try HTMLConverter.write(data, to: link)
        }
        #expect(throws: PDFCoreError.destinationExists(path: dangling.path)) {
            try HTMLConverter.write(data, to: dangling)
        }
        #expect(try Data(contentsOf: victim) == Data("precious".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("created-by-attacker.pdf").path
        ))
    }

    // MARK: - Pagination (PDFPaginator)

    /// Builds a document with one page of the given size.
    private func makePage(width: CGFloat, height: CGFloat) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFCoreError.contextCreationFailed }

        var box = CGRect(x: 0, y: 0, width: width, height: height)
        context.beginPage(mediaBox: &box)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(box)
        context.endPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw PDFCoreError.documentLoadFailed
        }
        return document
    }

    @Test("a page that already fits needs no pagination")
    func normalPageNeedsNoPagination() throws {
        let letter = try makePage(width: 612, height: 792)
        #expect(!PDFPaginator.needsPagination(letter))
    }

    @Test("a tall page needs pagination")
    func tallPageNeedsPagination() throws {
        // What WKWebView.createPDF actually produces for a long article.
        let tall = try makePage(width: 816, height: 10_000)
        #expect(PDFPaginator.needsPagination(tall))
    }

    @Test("a tall page is sliced into multiple sheets")
    func tallPageIsSliced() throws {
        let tall = try makePage(width: 816, height: 5_000)
        let data = try #require(PDFPaginator.paginate(tall))
        let result = try #require(PDFDocument(data: data))

        #expect(result.pageCount > 1, "a 5000pt page should become several sheets")
    }

    @Test("every produced sheet is the requested size")
    func sheetsAreUniform() throws {
        let tall = try makePage(width: 816, height: 4_000)
        let data = try #require(PDFPaginator.paginate(tall, sheet: .letter))
        let result = try #require(PDFDocument(data: data))

        for index in 0..<result.pageCount {
            let bounds = try #require(result.page(at: index)).bounds(for: .mediaBox)
            #expect(abs(bounds.width - 612) < 1, "sheet \(index) width")
            #expect(abs(bounds.height - 792) < 1, "sheet \(index) height")
        }
    }

    @Test("a document that already fits passes through unchanged")
    func fittingDocumentPassesThrough() throws {
        let letter = try makePage(width: 612, height: 792)
        let data = try #require(PDFPaginator.paginate(letter))
        let result = try #require(PDFDocument(data: data))

        // Running this on an ordinary PDF must be a no-op, not a re-layout.
        #expect(result.pageCount == 1)
    }

    @Test("A4 sheets are supported")
    func a4Supported() throws {
        let tall = try makePage(width: 794, height: 3_000)
        let data = try #require(PDFPaginator.paginate(tall, sheet: .a4))
        let result = try #require(PDFDocument(data: data))

        let bounds = try #require(result.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }

    @Test("a converted long page ends up paginated on disk")
    @MainActor
    func endToEndPagination() async throws {
        let paragraphs = (0..<120)
            .map { "<p>Line \($0) of filler text to force past one page.</p>" }
            .joined()

        let converter = HTMLConverter()
        let data = try await converter.convert(
            html: "<html><body><h1>START</h1>\(paragraphs)<h2>END MARKER</h2></body></html>"
        )

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("paged-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        try HTMLConverter.write(data, to: destination)

        let result = try #require(PDFDocument(url: destination))
        #expect(result.pageCount > 1, "a long article must paginate")

        // Order must be preserved: the opening heading above the closing one.
        // A sign error in the vertical offset would reverse them, which is the
        // bug worth catching here.
        //
        // Not asserting the closing heading is on the *final* sheet: the
        // overlap means the last band can extend past the content, leaving the
        // final sheet blank. That is cosmetic, and pinning it would make the
        // test brittle against the overlap value.
        let first = try #require(result.findString("START", withOptions: []).first)
        let last = try #require(result.findString("END MARKER", withOptions: []).first)
        let firstPage = result.index(for: try #require(first.pages.first))
        let lastPage = result.index(for: try #require(last.pages.first))

        #expect(firstPage == 0, "the opening heading belongs on the first sheet")
        #expect(lastPage > firstPage, "content order was reversed")
    }
}
