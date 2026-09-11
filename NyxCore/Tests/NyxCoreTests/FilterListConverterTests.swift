import XCTest
@testable import NyxCore

final class FilterListConverterTests: XCTestCase {
    /// A dozen representative lines: comments/blank lines (ignored), a
    /// network block rule, a network exception, two element-hide rules,
    /// a few more network rules, and one rule the converter rejects.
    static let fixture = """
    ! Test filter list
    [Adblock Plus 2.0]

    ||ads.example.com^
    @@||example.com/allowed.js
    example.com##.ad-banner
    ||tracker.io^$third-party
    ||evil.net^$image
    sub.example.com###ad-slot
    @@||good.example.com^$document
    ||analytics.example.com^
    ||bad-cdn.net/ads/*
    example.org##.popup
    zz
    """

    func testNonEmptyParseableJSONWithPlausibleCounts() throws {
        let results = try FilterListConverter.convert(name: "ads", filterText: Self.fixture)

        XCTAssertEqual(results.count, 1)
        let list = results[0]

        XCTAssertFalse(list.json.isEmpty)
        let data = try XCTUnwrap(list.json.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(parsed is [Any])

        // 9 real rules in the fixture; "zz" is rejected as too short.
        XCTAssertGreaterThanOrEqual(list.ruleCount, 5)
        XCTAssertEqual(list.discardedCount, 1)
    }

    func testIdentifierStableAcrossCalls() throws {
        let first = try FilterListConverter.convert(name: "ads", filterText: Self.fixture)
        let second = try FilterListConverter.convert(name: "ads", filterText: Self.fixture)

        XCTAssertEqual(first.map(\.identifier), second.map(\.identifier))
    }

    func testIdentifierDiffersForDifferentInput() throws {
        let base = try FilterListConverter.convert(name: "ads", filterText: Self.fixture)
        let changed = try FilterListConverter.convert(
            name: "ads",
            filterText: Self.fixture + "\n||another-tracker.example.com^"
        )

        XCTAssertNotEqual(base[0].identifier, changed[0].identifier)
    }

    func testIdentifierDiffersForDifferentName() throws {
        let ads = try FilterListConverter.convert(name: "ads", filterText: Self.fixture)
        let privacy = try FilterListConverter.convert(name: "privacy", filterText: Self.fixture)

        XCTAssertNotEqual(ads[0].identifier, privacy[0].identifier)
    }

    func testOversizedInputSplitsAcrossMultipleRuleLists() throws {
        let ruleCount = 25
        let synthetic = (0..<ruleCount)
            .map { "||domain-\($0).example.com^" }
            .joined(separator: "\n")

        let results = try FilterListConverter.convert(name: "big", filterText: synthetic, maxRules: 5)

        XCTAssertEqual(results.count, 5)
        for list in results {
            XCTAssertLessThanOrEqual(list.ruleCount, 5)
        }
        XCTAssertEqual(results.map(\.ruleCount).reduce(0, +), ruleCount)

        // Every part gets its own stable, distinct identifier.
        let identifiers = Set(results.map(\.identifier))
        XCTAssertEqual(identifiers.count, results.count)

        let again = try FilterListConverter.convert(name: "big", filterText: synthetic, maxRules: 5)
        XCTAssertEqual(again.map(\.identifier), results.map(\.identifier))
    }

    func testEmptyFilterTextYieldsSingleEmptyParseableResult() throws {
        let results = try FilterListConverter.convert(name: "empty", filterText: "")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ruleCount, 0)
        XCTAssertEqual(results[0].discardedCount, 0)
        let data = try XCTUnwrap(results[0].json.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)
    }
}
