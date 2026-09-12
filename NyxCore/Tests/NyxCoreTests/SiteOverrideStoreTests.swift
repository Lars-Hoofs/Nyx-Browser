import XCTest
@testable import NyxCore

/// Site overrides (M5 spec): default blocking is ON for every host; a row
/// in `site_override` exists only for hosts where the user has switched
/// blocking OFF. Host keys are always lowercased so lookups are
/// case-insensitive regardless of how the caller capitalizes a host.
final class SiteOverrideStoreTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: SiteOverrideStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-site-override-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = SiteOverrideStore(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - default state

    func testIsBlockingDisabledDefaultsFalseForUnknownHost() throws {
        XCTAssertFalse(try store.isBlockingDisabled(host: "example.com"))
    }

    func testDisabledHostsEmptyByDefault() throws {
        XCTAssertTrue(try store.disabledHosts().isEmpty)
    }

    // MARK: - round-trip

    func testSetBlockingDisabledTrueThenIsBlockingDisabledReturnsTrue() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        XCTAssertTrue(try store.isBlockingDisabled(host: "example.com"))
    }

    func testSetBlockingDisabledTrueAddsHostToDisabledHosts() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        XCTAssertEqual(try store.disabledHosts(), ["example.com"])
    }

    func testDisabledHostsListsMultipleDisabledHostsOnly() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        try store.setBlockingDisabled(true, host: "other.com")
        // "still-blocked.com" is never disabled and must not appear.
        XCTAssertEqual(Set(try store.disabledHosts()), Set(["example.com", "other.com"]))
    }

    // MARK: - delete-on-enable

    func testSetBlockingDisabledFalseDeletesRow() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        try store.setBlockingDisabled(false, host: "example.com")
        XCTAssertFalse(try store.isBlockingDisabled(host: "example.com"))
        XCTAssertTrue(try store.disabledHosts().isEmpty)
    }

    func testSetBlockingDisabledFalseForHostNeverDisabledIsNoOp() throws {
        XCTAssertNoThrow(try store.setBlockingDisabled(false, host: "never-disabled.com"))
        XCTAssertFalse(try store.isBlockingDisabled(host: "never-disabled.com"))
        XCTAssertTrue(try store.disabledHosts().isEmpty)
    }

    func testReDisablingAfterEnableRoundTripsAgain() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        try store.setBlockingDisabled(false, host: "example.com")
        try store.setBlockingDisabled(true, host: "example.com")
        XCTAssertTrue(try store.isBlockingDisabled(host: "example.com"))
        XCTAssertEqual(try store.disabledHosts(), ["example.com"])
    }

    // MARK: - lowercase host normalization

    func testHostIsLowercasedOnWrite() throws {
        try store.setBlockingDisabled(true, host: "Example.COM")
        XCTAssertEqual(try store.disabledHosts(), ["example.com"])
    }

    func testIsBlockingDisabledLookupIsCaseInsensitive() throws {
        try store.setBlockingDisabled(true, host: "example.com")
        XCTAssertTrue(try store.isBlockingDisabled(host: "EXAMPLE.com"))
        XCTAssertTrue(try store.isBlockingDisabled(host: "Example.Com"))
    }

    func testSetBlockingDisabledFalseIsCaseInsensitive() throws {
        try store.setBlockingDisabled(true, host: "Example.COM")
        try store.setBlockingDisabled(false, host: "EXAMPLE.com")
        XCTAssertFalse(try store.isBlockingDisabled(host: "example.com"))
        XCTAssertTrue(try store.disabledHosts().isEmpty)
    }
}
