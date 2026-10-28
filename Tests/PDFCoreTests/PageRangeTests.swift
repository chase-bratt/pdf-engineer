import Testing
@testable import PDFCore

@Suite("PageRange")
struct PageRangeTests {

    @Test func singlePagesAndRanges() throws {
        #expect(try PageRange.parse("1-3, 5,8-end", pageCount: 9) == [0, 1, 2, 4, 7, 8])
    }

    @Test func duplicatesAndOrderAreNormalised() throws {
        #expect(try PageRange.parse("4,2,2-3,last", pageCount: 4) == [1, 2, 3])
    }

    @Test func rejectsBadInput() {
        #expect(throws: PageRange.ParseError.empty) { try PageRange.parse(" , ", pageCount: 3) }
        #expect(throws: PageRange.ParseError.invalidToken("x")) { try PageRange.parse("x", pageCount: 3) }
        #expect(throws: PageRange.ParseError.invalidToken("1-2-3")) { try PageRange.parse("1-2-3", pageCount: 3) }
        #expect(throws: PageRange.ParseError.outOfRange(page: 4, pageCount: 3)) { try PageRange.parse("4", pageCount: 3) }
        #expect(throws: PageRange.ParseError.outOfRange(page: 0, pageCount: 3)) { try PageRange.parse("0", pageCount: 3) }
        #expect(throws: PageRange.ParseError.reversed("3-1")) { try PageRange.parse("3-1", pageCount: 3) }
    }

    @Test func chunksCoverEveryPage() {
        #expect(PageRange.chunks(pageCount: 5, size: 2) == [[0, 1], [2, 3], [4]])
        #expect(PageRange.chunks(pageCount: 5, size: 0).isEmpty)
    }
}
