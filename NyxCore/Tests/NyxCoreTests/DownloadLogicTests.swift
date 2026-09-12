import XCTest
@testable import NyxCore

final class DownloadLogicTests: XCTestCase {

    // MARK: - canTransition (exhaustive 5x5 matrix)

    private static let allStates: [DownloadRecord.State] = [.running, .finished, .failed, .cancelled, .interrupted]

    /// Every valid (from, to) pair per the spec §7 table:
    /// running -> finished|failed|cancelled (terminal outcomes of a live download);
    /// failed|cancelled|interrupted -> running (retry). Everything else — including
    /// every self-transition, and any transition out of `finished` (terminal) or
    /// into `interrupted` (launch-rebuild only, never at runtime) — is invalid.
    private static let validPairs: Set<[DownloadRecord.State]> = [
        [.running, .finished],
        [.running, .failed],
        [.running, .cancelled],
        [.failed, .running],
        [.cancelled, .running],
        [.interrupted, .running],
    ]

    func testCanTransitionMatchesTheFullTransitionTableForEveryCell() {
        for from in Self.allStates {
            for to in Self.allStates {
                let expected = Self.validPairs.contains([from, to])
                XCTAssertEqual(DownloadLogic.canTransition(from: from, to: to), expected,
                                "from \(from) to \(to) expected \(expected)")
            }
        }
    }

    func testFinishedIsTerminalNoOutgoingTransitions() {
        for to in Self.allStates {
            XCTAssertFalse(DownloadLogic.canTransition(from: .finished, to: to),
                            "finished must have no outgoing transitions, got one to \(to)")
        }
    }

    func testInterruptedIsNeverAValidDestinationAtRuntime() {
        for from in Self.allStates {
            XCTAssertFalse(DownloadLogic.canTransition(from: from, to: .interrupted),
                            "nothing should transition into interrupted at runtime, got one from \(from)")
        }
    }

    func testNoStateTransitionsToItself() {
        for state in Self.allStates {
            XCTAssertFalse(DownloadLogic.canTransition(from: state, to: state),
                            "\(state) must not transition to itself")
        }
    }

    // MARK: - uniqueFilename

    func testFreeNameReturnsUnchanged() {
        let result = DownloadLogic.uniqueFilename("report.pdf") { _ in false }
        XCTAssertEqual(result, "report.pdf")
    }

    func testSingleCollisionAppendsCounterTwo() {
        let result = DownloadLogic.uniqueFilename("report.pdf") { $0 == "report.pdf" }
        XCTAssertEqual(result, "report (2).pdf")
    }

    func testProbesUntilFreeAcrossMultipleCollisions() {
        let taken: Set<String> = ["report.pdf", "report (2).pdf", "report (3).pdf"]
        let result = DownloadLogic.uniqueFilename("report.pdf") { taken.contains($0) }
        XCTAssertEqual(result, "report (4).pdf")
    }

    func testCaseInsensitiveComparisonStillProbesCorrectly() {
        // The taken-closure may itself compare case-insensitively; uniqueFilename
        // must still call it with each incrementing candidate and stop at the
        // first one it reports free, regardless of how the closure compares.
        let taken: Set<String> = ["REPORT.PDF", "report (2).pdf"]
        let result = DownloadLogic.uniqueFilename("report.pdf") { candidate in
            taken.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        XCTAssertEqual(result, "report (3).pdf")
    }

    func testNoExtensionNameGetsCounterAppendedDirectly() {
        let result = DownloadLogic.uniqueFilename("Makefile") { $0 == "Makefile" }
        XCTAssertEqual(result, "Makefile (2)")
    }

    func testNoExtensionNameAlreadyFreeReturnsUnchanged() {
        let result = DownloadLogic.uniqueFilename("Makefile") { _ in false }
        XCTAssertEqual(result, "Makefile")
    }

    func testDotfileLeadingDotIsNotTreatedAsExtensionSeparator() {
        let result = DownloadLogic.uniqueFilename(".zshrc") { $0 == ".zshrc" }
        XCTAssertEqual(result, ".zshrc (2)")
    }

    func testDotfileAlreadyFreeReturnsUnchanged() {
        let result = DownloadLogic.uniqueFilename(".zshrc") { _ in false }
        XCTAssertEqual(result, ".zshrc")
    }

    func testMultiDotNameSplitsOnLastDotOnly() {
        // Pinned lastDotSplit choice: "archive.tar.gz" splits into base
        // "archive.tar" and extension "gz", so the counter lands right
        // before the final extension: "archive.tar (2).gz".
        let result = DownloadLogic.uniqueFilename("archive.tar.gz") { $0 == "archive.tar.gz" }
        XCTAssertEqual(result, "archive.tar (2).gz")
    }

    func testMultiDotNameAlreadyFreeReturnsUnchanged() {
        let result = DownloadLogic.uniqueFilename("archive.tar.gz") { _ in false }
        XCTAssertEqual(result, "archive.tar.gz")
    }

    func testMultiDotNameProbesUntilFree() {
        let taken: Set<String> = ["archive.tar.gz", "archive.tar (2).gz"]
        let result = DownloadLogic.uniqueFilename("archive.tar.gz") { taken.contains($0) }
        XCTAssertEqual(result, "archive.tar (3).gz")
    }

    // MARK: - retryAction

    private func record(state: DownloadRecord.State, resumeData: Data?) -> DownloadRecord {
        DownloadRecord(id: "d1", url: "https://example.com/file", suggestedFilename: "file",
                        destinationPath: nil, state: state, bytesReceived: 0, bytesExpected: -1,
                        resumeData: resumeData, errorMessage: nil,
                        startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
    }

    func testRetryActionForEveryStateAndResumeDataCombination() {
        let data = Data([0x01, 0x02])
        let cases: [(DownloadRecord.State, Data?, DownloadLogic.RetryAction?)] = [
            (.failed, data, .resume(data)),
            (.failed, nil, .freshStart),
            (.cancelled, data, .resume(data)),
            (.cancelled, nil, .freshStart),
            (.interrupted, data, .resume(data)),
            (.interrupted, nil, .freshStart),
            (.finished, data, nil),
            (.finished, nil, nil),
            (.running, data, nil),
            (.running, nil, nil),
        ]
        for (state, resumeData, expected) in cases {
            let result = DownloadLogic.retryAction(for: record(state: state, resumeData: resumeData))
            XCTAssertEqual(result, expected, "state \(state) resumeData=\(resumeData != nil) expected \(String(describing: expected))")
        }
    }
}
