import XCTest
@testable import Nyx
import NyxCore

@MainActor
final class HistoryRecorderTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: HistoryStore!
    private var recorder: HistoryRecorder!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-recorder-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = HistoryStore(database: database)
        recorder = HistoryRecorder(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - isRecordable

    func testIsRecordableAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(HistoryRecorder.isRecordable(URL(string: "http://example.com")!))
        XCTAssertTrue(HistoryRecorder.isRecordable(URL(string: "https://example.com")!))
    }

    func testIsRecordableRejectsNonWebSchemes() {
        XCTAssertFalse(HistoryRecorder.isRecordable(URL(string: "about:blank")!))
        XCTAssertFalse(HistoryRecorder.isRecordable(URL(string: "data:text/plain,hi")!))
        XCTAssertFalse(HistoryRecorder.isRecordable(URL(string: "file:///tmp/foo")!))
        XCTAssertFalse(HistoryRecorder.isRecordable(URL(string: "blob:https://example.com/uuid")!))
    }

    // MARK: - wire(): navigation-committed recording

    func testWiredCommitRecordsVisitIntoRealStore() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        tab.onNavigationCommitted?(URL(string: "https://example.com")!)
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.url), ["https://example.com"])
    }

    func testWiredCommitIgnoresAboutBlank() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        tab.onNavigationCommitted?(URL(string: "about:blank")!)
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }

    func testWiredCommitIgnoresFileURL() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        tab.onNavigationCommitted?(URL(string: "file:///tmp/foo.html")!)
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }

    // MARK: - wire(): title enrichment

    func testWiredTitleChangeEnrichesRecordedEntry() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        let url = URL(string: "https://example.com")!
        tab.onNavigationCommitted?(url)
        tab.onTitleChangedForHistory?(url, "Example Domain")
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.first?.url, url.absoluteString)
        XCTAssertEqual(recent.first?.title, "Example Domain")
    }

    func testWiredTitleChangeIgnoredWhenDeliveredURLNotRecordable() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        tab.onTitleChangedForHistory?(URL(string: "about:blank")!, "Ignored")
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }

    /// Race regression: a title event for the PREVIOUS page in a tab,
    /// still in flight when the tab has already navigated on to a new
    /// URL, must enrich the OLD url's row — never the new one. The
    /// callback is keyed on the URL delivered alongside the title (its own
    /// KVO-synchronous capture), not on the tab's current `urlString`,
    /// which by this point already reads the new page.
    func testWiredTitleChangeUsesDeliveredURLNotTabsCurrentURLString() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        let urlA = URL(string: "https://a.example.com")!
        let urlB = URL(string: "https://b.example.com")!
        tab.onNavigationCommitted?(urlA)
        tab.onNavigationCommitted?(urlB)
        tab.urlString = urlB.absoluteString   // tab has already moved on to B
        tab.onTitleChangedForHistory?(urlA, "Title A")   // late title, still for A
        let recent = try store.recent(limit: 10)
        let entryA = recent.first { $0.url == urlA.absoluteString }
        let entryB = recent.first { $0.url == urlB.absoluteString }
        XCTAssertEqual(entryA?.title, "Title A")
        XCTAssertEqual(entryB?.title, "")
    }
}
