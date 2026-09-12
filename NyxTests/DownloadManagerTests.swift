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
/// I-1 (final review) note: the same gap applies to the byte-count capture
/// those three delegate paths now perform (`download.progress
/// .completedUnitCount`/`totalUnitCount` written into the transitioning
/// record) — a real `Progress` with non-zero counts needs a real
/// `WKDownload` in flight, so that capture itself is queued-UI-run
/// territory too. What this suite pins instead is the seam it writes
/// through: `testTransitionMutateClosureLandsByteCounts`, below.
///
/// M-1 (final review, folded) note: same gap again for `finishRetry`'s
/// remove-during-pending-retry orphan guard (`download.cancel` +
/// `untrack` when the item is gone by the time a real host's completion
/// fires) — `finishRetry` only ever runs from a real `WKDownload`
/// completion, so the guard's cancel/untrack branch itself is
/// queued-UI-run territory too. What IS pinned here, extending the
/// `SpyDownloadHost` pattern below (which already holds `retry`'s async
/// window open by never calling its completion handler): that
/// `remove(id:)` cleanly drops a row DURING that exact window — see
/// `testRemoveDuringPendingRetryDropsItem`.
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

    /// I-1 (final review): `downloadDidFinish`/`didFailWithError`/`cancel`'s
    /// completion now each capture `download.progress.completedUnitCount`/
    /// `totalUnitCount` into the mutate closure they hand `transition(id:
    /// to:mutate:)` — this seam is what actually lands those bytes into the
    /// record and the store. Driving `WKDownload.progress` itself needs a
    /// real `WKDownload`, which only WebKit can construct (this file's own
    /// honesty header, above) — that half stays queued-UI-run territory
    /// (`testDownloadCompletesAndShowsInPopover` observes a real finish,
    /// but has no `nyx.downloads.*` a11y surface for byte counts either,
    /// so it can't pin this by itself — see that test's own doc comment).
    /// What CAN be pinned here, honestly, is the seam every one of those
    /// three call sites shares: a `transition` mutate closure that writes
    /// non-zero/non--1 byte counts must have them land in `items` AND in
    /// the store — exactly the shape those three fixes rely on.
    func testTransitionMutateClosureLandsByteCounts() throws {
        let record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        manager.seedForTesting(record)

        manager.transition(id: record.id, to: .finished) { r in
            r.bytesReceived = 2048
            r.bytesExpected = 2048
        }

        XCTAssertEqual(manager.items.first?.record.bytesReceived, 2048,
                       "the transition's mutate closure must be able to overwrite the 0 seed in memory")
        XCTAssertEqual(manager.items.first?.record.bytesExpected, 2048)

        let stored = try store.all().first { $0.id == record.id }
        XCTAssertEqual(stored?.bytesReceived, 2048, "and persist it — the popover subtitle reads from the store on relaunch")
        XCTAssertEqual(stored?.bytesExpected, 2048)
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

    /// M-1 (final review, folded): pins the testable half of the
    /// remove-during-pending-retry scenario `finishRetry`'s new orphan
    /// guard exists for. `finishRetry` itself only ever runs from a real
    /// `WKDownload` completion (only WebKit can construct one — this
    /// file's own honesty header, above), so the guard's
    /// `download.cancel`/`untrack` branch is exercised only by the
    /// queued UI run, exactly like `adopt(_:)` and the delegate glue
    /// methods. `SpyDownloadHost` already holds `retry`'s async window
    /// open (it never calls its completion handler), which is exactly
    /// the window a user could remove the row in: the record is
    /// `.failed`, not `.running`, so `remove(id:)`'s running-guard does
    /// not protect it. This asserts that removal succeeds cleanly —
    /// the row is gone, nothing crashes — which is the precondition
    /// `finishRetry`'s guard has to detect whenever the still-pending
    /// host completion eventually does fire.
    func testRemoveDuringPendingRetryDropsItem() {
        var record = DownloadManager.makeRunningRecord(url: URL(string: "https://example.com/a.zip")!)
        record.state = .failed
        record.resumeData = Data([0x01, 0x02]) // → RetryAction.resume
        manager.seedForTesting(record)
        let host = SpyDownloadHost(frame: .zero)

        manager.retry(id: record.id, host: host) // reaches host, never resolves — pending window open
        XCTAssertEqual(host.resumeCallCount, 1)

        manager.remove(id: record.id)

        XCTAssertTrue(manager.items.isEmpty,
                       "remove(id:) must drop the row even mid-retry — its state is " +
                       ".failed, not .running, so the running-only guard never fires")
    }
}
