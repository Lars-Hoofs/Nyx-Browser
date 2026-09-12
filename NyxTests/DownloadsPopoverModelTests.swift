import XCTest
@testable import Nyx
import NyxCore

/// M6 Task 5: `DownloadsPopoverModel` — the pure row-presentation logic
/// `DownloadsPopover` renders from (action mapping, subtitle text, byte
/// formatting, reveal-enabled). No SwiftUI/WebKit/AppKit machinery is
/// exercised here; the view itself (and its `NSWorkspace.
/// activateFileViewerSelecting` call, and the live `ProgressView(Progress)`
/// wiring) can only be verified by the queued UI run (M6 T6) — this suite
/// pins everything that logic is BUILT from.
final class DownloadsPopoverModelTests: XCTestCase {

    private func record(
        state: DownloadRecord.State,
        destinationPath: String? = nil,
        bytesReceived: Int64 = 0,
        errorMessage: String? = nil,
        url: String = "https://example.com/report.pdf"
    ) -> DownloadRecord {
        DownloadRecord(
            id: "d1", url: url, suggestedFilename: "report.pdf",
            destinationPath: destinationPath, state: state,
            bytesReceived: bytesReceived, bytesExpected: -1, resumeData: nil,
            errorMessage: errorMessage, startedAt: Date(timeIntervalSince1970: 1000),
            finishedAt: nil)
    }

    // MARK: - actions(for:) — plan-binding mapping, every state

    func testActionsForRunningIsCancelOnly() {
        XCTAssertEqual(DownloadsPopoverModel.actions(for: .running), [.cancel])
    }

    func testActionsForFailedCancelledInterruptedAreRetryAndRemove() {
        for state: DownloadRecord.State in [.failed, .cancelled, .interrupted] {
            XCTAssertEqual(DownloadsPopoverModel.actions(for: state), [.retry, .remove],
                            "state \(state)")
        }
    }

    func testActionsForFinishedAreRevealAndRemove() {
        XCTAssertEqual(DownloadsPopoverModel.actions(for: .finished), [.reveal, .remove])
    }

    // MARK: - isRevealEnabled — stale-row honesty

    func testRevealEnabledOnlyForFinishedWithAnExistingFile() {
        let finished = record(state: .finished, destinationPath: "/tmp/x/report.pdf")
        XCTAssertTrue(DownloadsPopoverModel.isRevealEnabled(record: finished) { _ in true })
    }

    func testRevealDisabledWhenFileNoLongerExists() {
        // A finished row whose file the user deleted/moved outside the
        // app — reveal must never send Finder hunting for a dead path.
        let finished = record(state: .finished, destinationPath: "/tmp/x/report.pdf")
        XCTAssertFalse(DownloadsPopoverModel.isRevealEnabled(record: finished) { _ in false })
    }

    func testRevealDisabledWhenDestinationPathIsNil() {
        // finished but decideDestination somehow never ran — defensive,
        // should not happen for a real finished row.
        let finished = record(state: .finished, destinationPath: nil)
        XCTAssertFalse(DownloadsPopoverModel.isRevealEnabled(record: finished) { _ in true })
    }

    func testRevealDisabledForEveryNonFinishedStateEvenIfFileExists() {
        for state: DownloadRecord.State in [.running, .failed, .cancelled, .interrupted] {
            let rec = record(state: state, destinationPath: "/tmp/x/report.pdf")
            XCTAssertFalse(DownloadsPopoverModel.isRevealEnabled(record: rec) { _ in true },
                            "state \(state)")
        }
    }

    func testRevealFileExistsClosureIsAskedTheStoredDestinationPath() {
        let finished = record(state: .finished, destinationPath: "/tmp/x/report.pdf")
        var askedPath: String?
        _ = DownloadsPopoverModel.isRevealEnabled(record: finished) { path in
            askedPath = path
            return true
        }
        XCTAssertEqual(askedPath, "/tmp/x/report.pdf")
    }

    // MARK: - subtitle(for:)

    func testSubtitleForFinishedUsesTheSharedByteFormatter() {
        let finished = record(state: .finished, bytesReceived: 4_200_000)
        let expected = DownloadsPopoverModel.byteFormatter.string(fromByteCount: 4_200_000)
        XCTAssertEqual(DownloadsPopoverModel.subtitle(for: finished), expected)
    }

    func testSubtitleForFailedUsesTheStoredErrorMessage() {
        let failed = record(state: .failed, errorMessage: "The network connection was lost.")
        XCTAssertEqual(DownloadsPopoverModel.subtitle(for: failed),
                       "The network connection was lost.")
    }

    func testSubtitleForFailedWithNoErrorMessageFallsBackToFailed() {
        let failed = record(state: .failed, errorMessage: nil)
        XCTAssertEqual(DownloadsPopoverModel.subtitle(for: failed), "Failed")
    }

    func testSubtitleForCancelledAndInterruptedArePlainStateText() {
        XCTAssertEqual(DownloadsPopoverModel.subtitle(for: record(state: .cancelled)), "Cancelled")
        XCTAssertEqual(DownloadsPopoverModel.subtitle(for: record(state: .interrupted)), "Interrupted")
    }

    func testSubtitleForRunningIsNonEmptyFallbackText() {
        // The view never actually shows this (it renders ProgressView
        // instead whenever state == .running) — this only pins that the
        // mapping stays total instead of silently omitting the case.
        XCTAssertFalse(DownloadsPopoverModel.subtitle(for: record(state: .running)).isEmpty)
    }

    // MARK: - host(for:)

    func testHostParsesTheSourceURL() {
        let rec = record(state: .finished, url: "https://files.example.com/a/report.pdf")
        XCTAssertEqual(DownloadsPopoverModel.host(for: rec), "files.example.com")
    }

    func testHostIsEmptyForAnUnparseableURL() {
        let rec = record(state: .finished, url: "")
        XCTAssertEqual(DownloadsPopoverModel.host(for: rec), "")
    }
}
