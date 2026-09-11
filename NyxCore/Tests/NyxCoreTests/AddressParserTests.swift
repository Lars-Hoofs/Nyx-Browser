import XCTest
@testable import NyxCore

final class AddressParserTests: XCTestCase {
    private func url(_ input: String) -> String? {
        AddressParser.destinationURL(for: input)?.absoluteString
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(url(""))
        XCTAssertNil(url("   "))
    }

    func testFullURLPassesThrough() {
        XCTAssertEqual(url("https://apple.com/mac"), "https://apple.com/mac")
        XCTAssertEqual(url("http://example.org"), "http://example.org")
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(url("apple.com"), "https://apple.com")
        XCTAssertEqual(url("news.ycombinator.com/item?id=1"),
                       "https://news.ycombinator.com/item?id=1")
    }

    func testLocalhostGetsHTTP() {
        XCTAssertEqual(url("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("localhost"), "http://localhost")
    }

    func testSingleWordBecomesSearch() {
        XCTAssertEqual(url("swift"), "https://duckduckgo.com/?q=swift")
    }

    func testPhraseBecomesSearch() {
        XCTAssertEqual(url("swift concurrency guide"),
                       "https://duckduckgo.com/?q=swift%20concurrency%20guide")
    }

    func testDotInPhraseStillSearches() {
        XCTAssertEqual(url("what is swift 6.0"),
                       "https://duckduckgo.com/?q=what%20is%20swift%206.0")
    }

    func testFileURLPassesThrough() {
        XCTAssertEqual(url("file:///tmp/x.html"), "file:///tmp/x.html")
    }
}
