import XCTest
@testable import NyxCore

final class LauncherRankerTests: XCTestCase {
    private let ranker = LauncherRanker()

    private func tab(_ id: String, _ title: String, _ url: String) -> LauncherTabInfo {
        LauncherTabInfo(id: id, title: title, url: url)
    }

    private func entry(_ url: String, _ title: String) -> HistoryEntry {
        HistoryEntry(url: url, title: title, visitCount: 1, lastVisitedAt: Date())
    }

    // MARK: - empty query

    func testEmptyQueryReturnsOpenTabsThenHistoryInGivenOrder() {
        let tabs = [tab("t1", "Mail", "https://mail.example.com"),
                    tab("t2", "Docs", "https://docs.example.com")]
        let history = [entry("https://a.com", "A"), entry("https://b.com", "B")]
        let results = ranker.results(query: "", openTabs: tabs, history: history,
                                     commands: [], limit: 10)
        XCTAssertEqual(results, [
            .switchToTab(tabs[0]),
            .switchToTab(tabs[1]),
            .history(history[0]),
            .history(history[1])
        ])
    }

    func testEmptyQueryWhitespaceOnlyTreatedAsEmpty() {
        let tabs = [tab("t1", "Mail", "https://mail.example.com")]
        let results = ranker.results(query: "   ", openTabs: tabs, history: [],
                                     commands: [], limit: 10)
        XCTAssertEqual(results, [.switchToTab(tabs[0])])
    }

    func testEmptyQueryRespectsLimit() {
        let tabs = (0..<3).map { tab("t\($0)", "Tab \($0)", "https://tab\($0).example.com") }
        let history = (0..<3).map { entry("https://h\($0).example.com", "H \($0)") }
        let results = ranker.results(query: "", openTabs: tabs, history: history,
                                     commands: [], limit: 4)
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results, [
            .switchToTab(tabs[0]), .switchToTab(tabs[1]), .switchToTab(tabs[2]),
            .history(history[0])
        ])
    }

    // MARK: - tab ranking

    func testTabTitlePrefixBeatsTabURLSubstring() {
        let prefixTab = tab("t1", "Github Issues", "https://example.com/board")
        let substringTab = tab("t2", "Board", "https://github.com/repo")
        let results = ranker.results(query: "git", openTabs: [substringTab, prefixTab],
                                     history: [], commands: [], limit: 10)
        let tabResults = results.compactMap { result -> LauncherTabInfo? in
            if case .switchToTab(let info) = result { return info }
            return nil
        }
        XCTAssertEqual(tabResults, [prefixTab, substringTab],
                       "a title-prefix match must rank above a url-substring match")
    }

    func testNonMatchingTabIsExcluded() {
        let matching = tab("t1", "GitHub", "https://github.com")
        let nonMatching = tab("t2", "Weather", "https://weather.example.com")
        let results = ranker.results(query: "git", openTabs: [matching, nonMatching],
                                     history: [], commands: [], limit: 10)
        XCTAssertTrue(results.contains(.switchToTab(matching)))
        XCTAssertFalse(results.contains(.switchToTab(nonMatching)))
    }

    // MARK: - openURL derivation

    func testURLParseableQueryYieldsOpenURLAboveHistory() {
        let history = [entry("https://apple.com", "Apple")]
        let results = ranker.results(query: "apple.com", openTabs: [], history: history,
                                     commands: [], limit: 10)
        guard case .openURL(let url) = results.first else {
            return XCTFail("expected openURL first, got \(results)")
        }
        XCTAssertEqual(url.absoluteString, "https://apple.com")
        XCTAssertTrue(results.dropFirst().contains(.history(history[0])))
    }

    func testPlainWordQueryHasNoOpenURLOnlySearchWeb() {
        let results = ranker.results(query: "swift", openTabs: [], history: [],
                                     commands: [], limit: 10)
        XCTAssertFalse(results.contains { if case .openURL = $0 { return true }; return false },
                       "a query that AddressParser resolves to a DuckDuckGo search URL must not surface as openURL")
        XCTAssertEqual(results.last, .searchWeb("swift"))
    }

    // MARK: - commands

    func testCommandMatchAppearsForSplit() {
        let results = ranker.results(query: "split", openTabs: [], history: [],
                                     commands: LauncherCommand.allCases, limit: 10)
        XCTAssertTrue(results.contains(.command(.splitWithNextTab)))
    }

    func testNonMatchingCommandIsExcluded() {
        let results = ranker.results(query: "split", openTabs: [], history: [],
                                     commands: LauncherCommand.allCases, limit: 10)
        XCTAssertFalse(results.contains(.command(.newSpace)))
    }

    // MARK: - searchWeb trailing

    func testSearchWebAlwaysLastAndPresentForNonEmptyQuery() {
        let tabs = [tab("t1", "Splitter", "https://example.com")]
        let results = ranker.results(query: "split", openTabs: tabs, history: [],
                                     commands: LauncherCommand.allCases, limit: 10)
        XCTAssertEqual(results.last, .searchWeb("split"))
        XCTAssertEqual(
            results.filter { if case .searchWeb = $0 { return true }; return false }.count, 1,
            "exactly one trailing searchWeb result")
    }

    // MARK: - limit

    func testLimitRespectedWithSearchWebStillIncluded() {
        let tabs = (0..<5).map { tab("t\($0)", "Widget \($0)", "https://widget\($0).example.com") }
        let results = ranker.results(query: "widget", openTabs: tabs, history: [],
                                     commands: [], limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.last, .searchWeb("widget"))
    }

    // MARK: - case-insensitivity

    func testTabMatchingIsCaseInsensitive() {
        let t = tab("t1", "GitHub", "https://github.com")
        let results = ranker.results(query: "GIT", openTabs: [t], history: [],
                                     commands: [], limit: 10)
        XCTAssertTrue(results.contains(.switchToTab(t)))
    }

    func testCommandMatchingIsCaseInsensitive() {
        let results = ranker.results(query: "SPLIT", openTabs: [], history: [],
                                     commands: LauncherCommand.allCases, limit: 10)
        XCTAssertTrue(results.contains(.command(.splitWithNextTab)))
    }

    // MARK: - dedupe (history url == open tab url -> tab wins)

    func testHistoryEntryDuplicatingOpenTabURLIsDropped() {
        let sharedURL = "https://example.com"
        let t = tab("t1", "Example Site", "https://example.com")
        let h = entry(sharedURL, "Example Site")
        let otherHistory = entry("https://other.com", "Other")
        let results = ranker.results(query: "example", openTabs: [t], history: [h, otherHistory],
                                     commands: [], limit: 10)
        XCTAssertFalse(results.contains(.history(h)))
        XCTAssertTrue(results.contains(.switchToTab(t)))
    }

    func testHistoryEntryDuplicatingOpenTabURLDroppedOnEmptyQueryToo() {
        let sharedURL = "https://example.com"
        let t = tab("t1", "Example Site", "https://example.com")
        let h = entry(sharedURL, "Example Site")
        let results = ranker.results(query: "", openTabs: [t], history: [h], commands: [], limit: 10)
        XCTAssertEqual(results, [.switchToTab(t)])
    }
}
