import XCTest
@testable import NyxCore

final class BundledFilterListsTests: XCTestCase {
    func testBothFiltersLoadNonEmpty() throws {
        let easyList = try BundledFilterLists.easyList()
        XCTAssertFalse(easyList.isEmpty, "EasyList should load successfully and be non-empty")
        XCTAssertTrue(easyList.contains("[Adblock Plus"), "EasyList should contain Adblock Plus header")

        let easyPrivacy = try BundledFilterLists.easyPrivacy()
        XCTAssertFalse(easyPrivacy.isEmpty, "EasyPrivacy should load successfully and be non-empty")
        XCTAssertTrue(easyPrivacy.contains("[Adblock Plus"), "EasyPrivacy should contain Adblock Plus header")
    }

    /// Smoke test: convert the real EasyList snapshot, measure time,
    /// and verify rule counts meet expectations. This test has a generous
    /// timeout given the first-run M5 design implications.
    func testEasyListConversionPerformance() throws {
        let easyListText = try BundledFilterLists.easyList()

        let startTime = Date()
        let results = try FilterListConverter.convert(name: "easylist", filterText: easyListText)
        let elapsedSeconds = Date().timeIntervalSince(startTime)

        // Verify non-empty results
        XCTAssertGreaterThan(results.count, 0, "Should produce at least one rule list")

        // Verify rule counts meet expectations
        let totalRuleCount = results.map(\.ruleCount).reduce(0, +)
        XCTAssertGreaterThan(
            totalRuleCount,
            10_000,
            "EasyList should convert to more than 10,000 rules; got \(totalRuleCount)"
        )

        // Verify each list respects the 150k cap
        for (index, list) in results.enumerated() {
            XCTAssertLessThanOrEqual(
                list.ruleCount,
                150_000,
                "List part \(index) exceeds 150k rule cap: \(list.ruleCount) rules"
            )
        }

        // Log timing and counts for the report
        NSLog(
            "BundledFilterListsTests: EasyList conversion completed in %.2f seconds; " +
            "produced %d list(s) with %d total rules",
            elapsedSeconds, results.count, totalRuleCount
        )

        // Flag if conversion took longer than ~60s (impacts first-run design)
        if elapsedSeconds > 60.0 {
            NSLog(
                "WARNING: EasyList conversion exceeded 60 seconds (%.2f s); " +
                "this may impact M5 first-run performance",
                elapsedSeconds
            )
        }
    }

    func testEasyPrivacyConverts() throws {
        let easyPrivacyText = try BundledFilterLists.easyPrivacy()

        let results = try FilterListConverter.convert(name: "easyprivacy", filterText: easyPrivacyText)

        XCTAssertGreaterThan(results.count, 0, "Should produce at least one rule list")

        let totalRuleCount = results.map(\.ruleCount).reduce(0, +)
        XCTAssertGreaterThan(totalRuleCount, 0, "EasyPrivacy should convert to at least some rules")

        for (index, list) in results.enumerated() {
            XCTAssertLessThanOrEqual(
                list.ruleCount,
                150_000,
                "List part \(index) exceeds 150k rule cap: \(list.ruleCount) rules"
            )
        }

        NSLog(
            "BundledFilterListsTests: EasyPrivacy conversion completed; " +
            "produced %d list(s) with %d total rules",
            results.count, totalRuleCount
        )
    }
}
