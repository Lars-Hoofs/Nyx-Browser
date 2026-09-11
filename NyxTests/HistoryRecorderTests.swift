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
        tab.urlString = url.absoluteString
        tab.onTitleChangedForHistory?("Example Domain")
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.first?.url, url.absoluteString)
        XCTAssertEqual(recent.first?.title, "Example Domain")
    }

    func testWiredTitleChangeIgnoredWhenCurrentURLNotRecordable() throws {
        let tab = BrowserTab(spaceID: "s1")
        recorder.wire(tab)
        tab.urlString = "about:blank"
        tab.onTitleChangedForHistory?("Ignored")
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }
}
