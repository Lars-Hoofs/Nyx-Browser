import XCTest
import WebKit
@testable import Nyx
import NyxCore

@MainActor
final class RuleListManagerTests: XCTestCase {
    /// A tiny, deliberately 2-rule fixture (task brief: "compile a 2-rule
    /// JSON in-test") — cheap enough to convert+compile synchronously
    /// within a single test, unlike the real bundled EasyList/EasyPrivacy
    /// snapshots.
    static let fixtureFilterText = """
    ||example.com^
    example.com##.ad-banner
    """

    private var ephemeralStoreDirectories: [URL] = []

    override func tearDown() {
        for url in ephemeralStoreDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        ephemeralStoreDirectories = []
        super.tearDown()
    }

    /// A private, on-disk store per test (never `.default()`) so runs
    /// never see another test's — or another run's — cached identifiers.
    private func makeEphemeralStore() -> WKContentRuleListStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleListManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ephemeralStoreDirectories.append(dir)
        return WKContentRuleListStore(url: dir)
    }

    private func fixtureSource(name: String = "fixture") -> FilterListSource {
        FilterListSource(name: name, load: { Self.fixtureFilterText })
    }

    private func awaitReady(_ manager: RuleListManager, timeout: TimeInterval = 15) async {
        if manager.isReady { return }
        let expectation = expectation(description: "onReady")
        manager.onReady = { expectation.fulfill() }
        manager.bootstrap()
        await fulfillment(of: [expectation], timeout: timeout)
    }

    // MARK: - Bootstrap from cache (pre-seeded)

    /// Pre-seeds the store exactly as a *previous* app run would have left
    /// it (compiling the fixture's converted JSON directly), then
    /// bootstraps a fresh manager against the same store and identifiers.
    /// Content-addressing means the identifier `bootstrap()` derives from
    /// the same source text matches what's already cached, so this must be
    /// a pure lookup: `compileInvocationCount` stays at 0.
    func testBootstrapFromCacheSkipsCompile() async throws {
        let store = makeEphemeralStore()
        let converted = try FilterListConverter.convert(name: "fixture", filterText: Self.fixtureFilterText)
        XCTAssertEqual(converted.count, 1)

        _ = try await store.compileContentRuleList(
            forIdentifier: converted[0].identifier,
            encodedContentRuleList: converted[0].json
        )

        let manager = RuleListManager(store: store, sources: [fixtureSource()])
        await awaitReady(manager)

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.compiledLists.count, 1)
        XCTAssertEqual(manager.compileInvocationCount, 0, "identifier was already cached; bootstrap must not recompile it")
    }

    // MARK: - Cache-hit across two full bootstraps

    /// Simulates two app launches sharing the same on-disk store: the first
    /// manager's `bootstrap()` compiles from scratch, the second manager's
    /// `bootstrap()` (same store, same source text → same identifier) must
    /// find it via lookup alone. Asserted via the `compileInvocationCount`
    /// probe seam rather than timing, to stay deterministic; the dedicated
    /// real-lists test below corroborates with wall-clock timing too.
    func testSecondBootstrapIsLookupOnly() async throws {
        let store = makeEphemeralStore()

        let first = RuleListManager(store: store, sources: [fixtureSource()])
        await awaitReady(first)
        XCTAssertEqual(first.compileInvocationCount, 1, "first bootstrap against an empty store must compile")

        let second = RuleListManager(store: store, sources: [fixtureSource()])
        await awaitReady(second)
        XCTAssertEqual(second.compileInvocationCount, 0, "second bootstrap must hit the cache, not recompile")
        XCTAssertEqual(second.compiledLists.count, 1)
    }

    // MARK: - apply / remove round-trip

    /// Exercises `apply`/`remove` against a real `WKUserContentController`
    /// (not a mock — WebKit has no public introspection for "which rule
    /// lists are currently attached", so this is a not-crashing, callable
    /// round-trip check rather than a state assertion).
    func testApplyRemoveRoundTripOnRealController() async throws {
        let store = makeEphemeralStore()
        let manager = RuleListManager(store: store, sources: [fixtureSource()])
        await awaitReady(manager)
        XCTAssertEqual(manager.compiledLists.count, 1)

        let controller = WKUserContentController()
        manager.apply(to: controller)
        manager.remove(from: controller)
        manager.apply(to: controller)
        manager.remove(from: controller)
        // Reaching this line without WebKit trapping/crashing is the assertion.
    }

    // MARK: - Corrupt JSON failure path

    /// `FilterListConverter` only ever emits well-formed JSON for real
    /// filter text, so the "corrupt JSON" failure can't be reached by
    /// feeding `bootstrap()` bad AdBlock syntax — it has to be injected
    /// past conversion, directly at the WebKit-compile boundary. Confirms
    /// WebKit's own rejection of malformed content-blocker JSON surfaces
    /// as a thrown Swift error (not a crash, not a silently-accepted list).
    func testCompileRejectsMalformedJSON() async throws {
        let store = makeEphemeralStore()
        let manager = RuleListManager(store: store, sources: [])
        // ConvertedRuleList has no public initializer in NyxCore (only its
        // fields are public), so a valid instance is corrupted in place
        // rather than built from scratch.
        var corrupt = try FilterListConverter.convert(name: "fixture", filterText: Self.fixtureFilterText)[0]
        corrupt.identifier = "corrupt-vDEADBEEF"
        corrupt.json = "{not valid content-blocker json"

        do {
            _ = try await manager.compile([corrupt])
            XCTFail("WebKit should reject malformed content-blocker JSON")
        } catch {
            // Expected: rejected, not crashed.
        }
    }

    /// End-to-end failure contract: a source that fails to load must leave
    /// `isReady` false, must not throw out of `bootstrap()` (it has no
    /// `throws` to escape through in the first place — this proves nothing
    /// crashes or hangs either), and browsing-blocking state (an empty
    /// `compiledLists`) is exactly what unblocks browsing per spec §6.
    func testBootstrapFailureFromUnreadableSourceLeavesIsReadyFalse() async throws {
        struct LoadError: Error {}
        let store = makeEphemeralStore()
        let failingSource = FilterListSource(name: "broken", load: { throw LoadError() })
        let manager = RuleListManager(store: store, sources: [failingSource])

        manager.bootstrap()
        // No onReady fires on failure; give the background task a moment
        // to run and hit the error path, then assert the failure contract.
        try await Task.sleep(for: .seconds(1))

        XCTAssertFalse(manager.isReady)
        XCTAssertTrue(manager.compiledLists.isEmpty)
    }

    // MARK: - Bootstrap reentrancy fence

    /// A second `bootstrap()` call landing while the first is still
    /// in-flight must be ignored outright (NSLog + return), not queued or
    /// restarted — otherwise `onReady` could double-fire and the store
    /// could receive duplicate concurrent compiles for the same
    /// identifier. Both calls happen back-to-back with no `await` between
    /// them, so this is deterministic (no race): the guard flag is set
    /// synchronously by the first call before the second is even evaluated.
    func testSecondBootstrapCallWhileInFlightIsIgnored() async throws {
        let store = makeEphemeralStore()
        let manager = RuleListManager(store: store, sources: [fixtureSource()])
        var readyFireCount = 0
        let expectation = expectation(description: "onReady")
        manager.onReady = {
            readyFireCount += 1
            expectation.fulfill()
        }

        manager.bootstrap()
        manager.bootstrap() // reentrant call while the first is in-flight

        await fulfillment(of: [expectation], timeout: 15)
        // Give any errant second run a moment to (not) also fire.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(readyFireCount, 1, "onReady must fire exactly once")
        XCTAssertEqual(
            manager.compileInvocationCount, 1,
            "a single fixture source must compile exactly once even with an overlapping bootstrap() call"
        )
    }

    // MARK: - apply(to:) is idempotent (no stacking)

    /// `WKUserContentController` offers no public introspection for "how
    /// many rule lists are attached", so double-application is proven via
    /// a spy subclass confirming `apply(to:)` invokes
    /// `removeAllContentRuleLists()` on every call (including the second),
    /// which is the documented invariant that makes repeat `apply` calls
    /// idempotent by construction.
    func testApplyTwiceInvokesRemoveAllEachTime() async throws {
        final class SpyUserContentController: WKUserContentController {
            private(set) var removeAllCallCount = 0
            override func removeAllContentRuleLists() {
                removeAllCallCount += 1
                super.removeAllContentRuleLists()
            }
        }

        let store = makeEphemeralStore()
        let manager = RuleListManager(store: store, sources: [fixtureSource()])
        await awaitReady(manager)

        let controller = SpyUserContentController()
        manager.apply(to: controller)
        XCTAssertEqual(controller.removeAllCallCount, 1)

        manager.apply(to: controller) // no intervening remove(from:)
        XCTAssertEqual(controller.removeAllCallCount, 2, "apply(to:) must remove-then-add every time, so repeat calls never stack")
    }

    // MARK: - Real bundled lists: measured WebKit compile time

    /// Not required for correctness, but the task explicitly calls for
    /// measuring WebKit's real compile time (conversion is already known
    /// to be fast, ~1.4s total per BundledFilterListsTests/
    /// FilterListConverterTests) — this feeds Task 5/6 first-run UX.
    /// Generous timeout (120s): a slow CI machine must not flake this.
    func testMeasuredCompileTimeForRealBundledLists() async throws {
        let store = makeEphemeralStore()
        let manager = RuleListManager(store: store)

        let clock = ContinuousClock()
        let start = clock.now
        await awaitReady(manager, timeout: 120)
        let elapsed = start.duration(to: clock.now)

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.compiledLists.count, 2, "EasyList + EasyPrivacy, both single-part per Task 3's measurement")
        XCTAssertEqual(manager.compileInvocationCount, 2)

        NSLog("RuleListManager: measured cold bootstrap (convert + compile, real EasyList+EasyPrivacy) = %@", "\(elapsed)")
        print("RuleListManager measured cold bootstrap (convert+compile, real EasyList+EasyPrivacy): \(elapsed)")
    }
}
