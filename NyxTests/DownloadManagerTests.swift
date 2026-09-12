import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// M6 Task 3: `DownloadManager`.
///
/// `WKDownload` has no public initializer — only WebKit itself can create
/// one, by turning a navigation into a download or via
/// `WKWebView.startDownload`/`resumeDownload`. That means the following
/// paths are NOT exercised here and are covered only by the queued UI run
/// (M6 T6): `adopt(_:)`'s delegate-assignment-first ordering and its
/// prepend-into-`items` behavior; all three `WKDownloadDelegate` glue
/// methods (`decideDestination`, `downloadDidFinish`, `didFailWithError`)
/// as WebKit actually calls them; `cancel(id:)`'s real resumeData capture;
/// and `retry(id:host:)`'s resume/fresh-start branches once a host
/// `WKWebView` actually starts a network-touching download. This suite
/// instead drives every PURE and STORE-BACKED piece those methods are
/// built from directly, using `DownloadManager`'s internal test seams
/// (`seedForTesting`, `transition`, `updateRecord`, `isFilenameTaken`,
/// `makeRunningRecord`) — the same "re-compose pieces honestly" approach
/// as `AdblockMenuToggleTests`.
///
/// All file-based assertions write inside a per-test temp directory under
/// `FileManager.default.temporaryDirectory` (this test bundle's own
/// container) — never the real `~/Downloads`.

/// Spy `WKWebView` subclass for the `pendingRetries` re-entrancy test
/// below (same shape as `TabManagerMediaTests.SpyWebView`). Overrides the
/// two download-starting entry points WITHOUT calling `super` or the
/// completion handler, so `finishRetry` never fires and a retry stays
/// "unresolved" indefinitely — exactly the window `pendingRetries` exists
/// to guard, held open deterministically instead of racing a real async
/// WebKit completion.
@MainActor
private final class SpyDownloadHost: WKWebView {
    private(set) var resumeCallCount = 0
    private(set) var startCallCount = 0

    override func resumeDownload(fromResumeData resumeData: Data,
                                  completionHandler: @escaping (WKDownload) -> Void) {
        resumeCallCount += 1
        // Deliberately never call completionHandler.
    }

    override func startDownload(using request: URLRequest,
                                 completionHandler: @escaping (WKDownload) -> Void) {
        startCallCount += 1
        // Deliberately never call completionHandler.
    }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: DownloadStore!
    private var destinationDirectory: URL!
    private var manager: DownloadManager!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-download-manager-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = DownloadStore(database: database)
        destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-download-manager-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        manager = DownloadManager(store: store, destinationDirectory: destinationDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: destinationDirectory)
    }

    // MARK: - makeRunningRecord (the shape adopt(_:) produces)

    func testMakeRunningRecordShape() {
        let url = URL(string: "https://example.com/report.pdf")!
        let record = DownloadManager.makeRunningRecord(url: url)

        XCTAssertEqual(record.url, "https://example.com/report.pdf")
        XCTAssertEqual(record.state, .running)
        XCTAssertEqual(record.bytesReceived, 0)
        XCTAssertEqual(record.bytesExpected, -1)
        XCTAssertNil(record.destinationPath)
        XCTAssertNil(record.resumeData)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.finishedAt)
        XCTAssertFalse(record.id.isEmpty)
    }

    func testMakeRunningRecordFallsBackToEmptyURLWhenNil() {
        let record = DownloadManager.makeRunningRecord(url: nil)
        XCTAssertEqual(record.url, "")
    }

    // MARK: - transition: guarded by DownloadLogic.canTransition

    func testTransitionAppliesValidChangeAndPersists() throws {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)

        manager.transition(id: record.id, to: .finished) { $0.finishedAt = Date() }

        XCTAssertEqual(manager.items.first?.record.state, .finished)
        XCTAssertNotNil(manager.items.first?.record.finishedAt)

        let stored = try store.all().first { $0.id == record.id }
        XCTAssertEqual(stored?.state, .finished, "a valid transition must be persisted")
    }

    func testTransitionIgnoresInvalidChangeAndNeverCallsMutate() throws {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .finished // terminal — no outgoing transitions
        manager.seedForTesting(record)

        var mutateCalled = false
        manager.transition(id: record.id, to: .running) { _ in mutateCalled = true }

        XCTAssertFalse(mutateCalled, "mutate must not run when the transition itself is rejected")
        XCTAssertEqual(manager.items.first?.record.state, .finished, "state must be unchanged")
        // Never seeded into the store, so nothing to have written — the
        // guard fired before persist() could even be reached.
        XCTAssertTrue(try store.all().isEmpty)
    }

    func testTransitionOnUnknownIDIsANoOp() {
        // No item with this id was ever seeded.
        manager.transition(id: "not-a-real-id", to: .finished)
        XCTAssertTrue(manager.items.isEmpty)
    }

    // MARK: - updateRecord (decideDestination's non-transition field write)

    func testUpdateRecordPersistsFieldsWithoutChangingState() throws {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)

        manager.updateRecord(id: record.id) { r in
            r.suggestedFilename = "a.zip"
            r.destinationPath = "/container/a.zip"
        }

        XCTAssertEqual(manager.items.first?.record.state, .running, "not a state transition")
        XCTAssertEqual(manager.items.first?.record.suggestedFilename, "a.zip")
        let stored = try store.all().first { $0.id == record.id }
        XCTAssertEqual(stored?.destinationPath, "/container/a.zip")
    }

    // MARK: - Progress persisted on transitions only (no per-byte DB writes)

    func testRunningRecordBytesUnchangedUntilATransition() throws {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)
        manager.updateRecord(id: record.id) { $0.suggestedFilename = "a.zip" } // e.g. decideDestination
        manager.updateRecord(id: record.id) { $0.suggestedFilename = "a.zip" } // simulate more "in-flight" activity

        let storedWhileRunning = try store.all().first { $0.id == record.id }
        XCTAssertEqual(storedWhileRunning?.bytesReceived, 0)
        XCTAssertEqual(storedWhileRunning?.bytesExpected, -1)
        XCTAssertEqual(storedWhileRunning?.state, .running,
                       "bytes only ever move via a transition's mutate closure — never a bare update")
    }

    // MARK: - decideDestination's naming: isFilenameTaken wraps a FULL-PATH check

    func testIsFilenameTakenChecksFullPathInDestinationDirectory() throws {
        let existing = destinationDirectory.appendingPathComponent("report.pdf")
        try "x".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertTrue(manager.isFilenameTaken("report.pdf"))
        XCTAssertFalse(manager.isFilenameTaken("other.pdf"))
    }

    func testUniqueFilenameWiredThroughManagerAvoidsExistingFile() throws {
        try "x".write(to: destinationDirectory.appendingPathComponent("report.pdf"),
                      atomically: true, encoding: .utf8)
        try "x".write(to: destinationDirectory.appendingPathComponent("report (2).pdf"),
                      atomically: true, encoding: .utf8)

        let resolved = DownloadLogic.uniqueFilename("report.pdf", taken: manager.isFilenameTaken)
        XCTAssertEqual(resolved, "report (3).pdf")
    }

    // MARK: - cancel: no-op without a live WKDownload

    func testCancelOnUnknownIDIsANoOp() {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)

        manager.cancel(id: record.id) // never adopted → no activeDownloads entry
        XCTAssertEqual(manager.items.first?.record.state, .running, "nothing to cancel; state untouched")
    }

    // MARK: - remove: never cancels a running item

    func testRemoveRefusesARunningItem() throws {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)
        try store.upsert(record)

        manager.remove(id: record.id)

        XCTAssertEqual(manager.items.count, 1, "running item must stay")
        XCTAssertFalse(try store.all().isEmpty, "running row must stay in the store too")
    }

    func testRemoveDropsAFinishedItemFromMemoryAndStore() throws {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .finished
        manager.seedForTesting(record)
        try store.upsert(record)

        manager.remove(id: record.id)

        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try store.all().isEmpty)
    }

    // MARK: - clearFinished: mirrors DownloadStore semantics

    func testClearFinishedRemovesOnlyFinishedAndCancelledRows() throws {
        var finished = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/1.zip")!)
        finished.state = .finished
        var cancelled = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/2.zip")!)
        cancelled.state = .cancelled
        var failed = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/3.zip")!)
        failed.state = .failed
        let running = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/4.zip")!)

        for record in [finished, cancelled, failed, running] {
            manager.seedForTesting(record)
            try store.upsert(record)
        }

        manager.clearFinished()

        let remainingIDs = Set(manager.items.map(\.id))
        XCTAssertEqual(remainingIDs, [failed.id, running.id])
        let storedIDs = Set(try store.all().map(\.id))
        XCTAssertEqual(storedIDs, [failed.id, running.id])
    }

    // MARK: - rebuildFromStore: interruptInFlight + load, progress-less

    func testRebuildFromStoreInterruptsRunningAndLoadsHistoryProgressLess() throws {
        let older = DownloadManager.makeRunningRecord(
            url: URL(string: "https://example.com/old.zip")!, startedAt: Date(timeIntervalSinceNow: -60))
        var finished = DownloadManager.makeRunningRecord(
            url: URL(string: "https://example.com/done.zip")!, startedAt: Date(timeIntervalSinceNow: -30))
        finished.state = .finished
        try store.upsert(older) // left running — must come back interrupted
        try store.upsert(finished)

        manager.rebuildFromStore()

        XCTAssertEqual(manager.items.count, 2)
        XCTAssertTrue(manager.items.allSatisfy { $0.progress == nil })
        // Newest startedAt first.
        XCTAssertEqual(manager.items.map(\.id), [finished.id, older.id])
        let rebuiltOlder = manager.items.first { $0.id == older.id }
        XCTAssertEqual(rebuiltOlder?.record.state, .interrupted)
        let rebuiltFinished = manager.items.first { $0.id == finished.id }
        XCTAssertEqual(rebuiltFinished?.record.state, .finished, "already-finished rows are untouched")
    }

    func testRebuildFromStoreFiresOnItemsChanged() throws {
        var firedCount = 0
        manager.onItemsChanged = { firedCount += 1 }
        manager.rebuildFromStore()
        XCTAssertEqual(firedCount, 1)
    }

    // MARK: - retry: nil RetryAction (finished/running) is a no-op — no host touched

    func testRetryOnFinishedRecordIsANoOp() {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .finished
        manager.seedForTesting(record)
        let host = WKWebView(frame: .zero)

        manager.retry(id: record.id, host: host)

        XCTAssertEqual(manager.items.first?.record.state, .finished, "finished is terminal; retry must no-op")
    }

    func testRetryOnRunningRecordIsANoOp() {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)
        let host = WKWebView(frame: .zero)

        manager.retry(id: record.id, host: host)

        XCTAssertEqual(manager.items.first?.record.state, .running, "already in flight; retry must no-op")
    }

    func testRetryOnUnknownIDIsANoOp() {
        let host = WKWebView(frame: .zero)
        manager.retry(id: "not-a-real-id", host: host) // must not crash
        XCTAssertTrue(manager.items.isEmpty)
    }

    func testRetryFreshStartWithInvalidStoredURLIsANoOpBeforeTouchingHost() {
        var record = DownloadManager.makeRunningRecord(url: nil) // url == "" → URL(string:) fails
        record.state = .failed
        record.resumeData = nil // forces .freshStart, not .resume
        manager.seedForTesting(record)
        let host = WKWebView(frame: .zero)

        manager.retry(id: record.id, host: host)

        XCTAssertEqual(manager.items.first?.record.state, .failed,
                       "invalid URL must be caught before any host.startDownload call")
    }

    // MARK: - retry: pendingRetries re-entrancy guard

    func testSecondRetryWhileFirstIsUnresolvedNeverCallsHostAgain_resumeBranch() {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .failed
        record.resumeData = Data([0x01, 0x02]) // → RetryAction.resume
        manager.seedForTesting(record)
        let host = SpyDownloadHost(frame: .zero)

        manager.retry(id: record.id, host: host) // first call: reaches host, never resolves
        manager.retry(id: record.id, host: host) // second call: must be blocked by pendingRetries

        XCTAssertEqual(host.resumeCallCount, 1,
                       "a second retry while the first is unresolved must never reach the host")
        XCTAssertEqual(host.startCallCount, 0)
        XCTAssertEqual(manager.items.first?.record.state, .failed,
                       "state must not change until finishRetry actually runs")
    }

    func testSecondRetryWhileFirstIsUnresolvedNeverCallsHostAgain_freshStartBranch() {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .failed
        record.resumeData = nil // forces .freshStart, not .resume
        manager.seedForTesting(record)
        let host = SpyDownloadHost(frame: .zero)

        manager.retry(id: record.id, host: host) // first call: reaches host, never resolves
        manager.retry(id: record.id, host: host) // second call: must be blocked by pendingRetries

        XCTAssertEqual(host.startCallCount, 1,
                       "a second retry while the first is unresolved must never reach the host")
        XCTAssertEqual(host.resumeCallCount, 0)
        XCTAssertEqual(manager.items.first?.record.state, .failed,
                       "state must not change until finishRetry actually runs")
    }
}
