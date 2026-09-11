import XCTest
@testable import NyxCore

final class SplitWeightsTests: XCTestCase {
    private func assertNormalized(_ weights: [Double],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(weights.reduce(0, +), 1.0, accuracy: 0.0001, file: file, line: line)
        for weight in weights {
            XCTAssertGreaterThanOrEqual(weight, SplitWeights.minimumFraction - 0.0001,
                                        file: file, line: line)
        }
    }

    func testEqualCounts() {
        XCTAssertEqual(SplitWeights.equal(count: 2), [0.5, 0.5])
        XCTAssertEqual(SplitWeights.equal(count: 4), [0.25, 0.25, 0.25, 0.25])
        XCTAssertEqual(SplitWeights.equal(count: 0), [1.0])   // clamped to 1
        XCTAssertEqual(SplitWeights.equal(count: 9), [0.25, 0.25, 0.25, 0.25]) // clamped to 4
    }

    func testSanitizedNormalizesAndClamps() {
        assertNormalized(SplitWeights.sanitized([3, 1], count: 2))
        XCTAssertEqual(SplitWeights.sanitized([3, 1], count: 2)[0], 0.75, accuracy: 0.0001)
        assertNormalized(SplitWeights.sanitized([0.99, 0.01], count: 2)) // clamp floor
    }

    func testSanitizedRejectsGarbage() {
        XCTAssertEqual(SplitWeights.sanitized([], count: 3), SplitWeights.equal(count: 3))
        XCTAssertEqual(SplitWeights.sanitized([Double.nan, 1], count: 2),
                       SplitWeights.equal(count: 2))
        XCTAssertEqual(SplitWeights.sanitized([0, 0], count: 2), SplitWeights.equal(count: 2))
        XCTAssertEqual(SplitWeights.sanitized([0.5], count: 3), SplitWeights.equal(count: 3)) // count mismatch
    }

    func testRemovingRedistributesProportionally() {
        let result = SplitWeights.removing(index: 0, from: [0.5, 0.25, 0.25])
        XCTAssertEqual(result, [0.5, 0.5])
        assertNormalized(result)
    }

    func testAppendingScalesDown() {
        let result = SplitWeights.appending(to: [0.5, 0.5])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[2], 1.0 / 3.0, accuracy: 0.0001)
        assertNormalized(result)
    }

    func testSanitizedConvergesOnPingPongInput() {
        assertNormalized(SplitWeights.sanitized([0.01, 0.01, 0.16, 0.82], count: 4))
    }

    func testSanitizedConvergesOnAdversarialFourPane() {
        assertNormalized(SplitWeights.sanitized([0.804, 0.004, 0.180, 0.179], count: 4))
    }
}
