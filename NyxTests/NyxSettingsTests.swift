import XCTest
@testable import Nyx

/// An isolated UserDefaults suite per test — never `.standard` — so a
/// run never leaks the adblock flag into another test or a developer's
/// real defaults domain.
final class NyxSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "NyxSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAdblockEnabledDefaultsToTrueWhenNeverSet() {
        let settings = NyxSettings(defaults: defaults)
        XCTAssertTrue(settings.adblockEnabled,
                      "blocking ON is the spec default until the user opts out")
    }

    func testAdblockEnabledRoundTripsFalse() {
        let settings = NyxSettings(defaults: defaults)
        settings.adblockEnabled = false
        XCTAssertFalse(settings.adblockEnabled)
        // A fresh struct instance backed by the same suite must observe
        // the write — the value lives in UserDefaults, not the struct.
        XCTAssertFalse(NyxSettings(defaults: defaults).adblockEnabled)
    }

    func testAdblockEnabledRoundTripsBackToTrue() {
        let settings = NyxSettings(defaults: defaults)
        settings.adblockEnabled = false
        settings.adblockEnabled = true
        XCTAssertTrue(settings.adblockEnabled)
    }

    func testAdblockEnabledIsNamespacedUnderNyxAdblockEnabled() {
        let settings = NyxSettings(defaults: defaults)
        settings.adblockEnabled = false
        XCTAssertEqual(defaults.object(forKey: "nyx.adblock.enabled") as? Bool, false)
    }

    func testToggleFlipsTheStoredValue() {
        let settings = NyxSettings(defaults: defaults)
        XCTAssertTrue(settings.adblockEnabled)
        settings.adblockEnabled.toggle()
        XCTAssertFalse(settings.adblockEnabled)
        settings.adblockEnabled.toggle()
        XCTAssertTrue(settings.adblockEnabled)
    }
}
