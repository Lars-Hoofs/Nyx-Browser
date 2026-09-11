import XCTest
@testable import Nyx
import NyxCore

/// LauncherViewModel against a REAL temp-file HistoryStore (same pattern
/// as HistoryRecorderTests) and a real TabManager whose tabs are faked by
/// writing title/urlString/lastActiveAt directly — no navigation, no
/// loaded pages.
@MainActor
final class LauncherViewModelTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: HistoryStore!
    private var manager: TabManager!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-launcher-vm-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = HistoryStore(database: database)
        manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 2))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - Helpers

    private func makeViewModel(
        availableCommands: @escaping () -> [LauncherCommand] = { LauncherCommand.allCases }
    ) -> LauncherViewModel {
        LauncherViewModel(manager: manager, history: store, ranker: LauncherRanker(),
                          availableCommands: availableCommands)
    }

    @discardableResult
    private func addTab(title: String, url: String, select: Bool = false,
                        lastActiveAt: Date = Date()) -> BrowserTab {
        let tab = manager.newTab(select: select)
        tab.title = title
        tab.urlString = url
        tab.lastActiveAt = lastActiveAt   // after newTab — select() stamps its own
        return tab
    }

    private func tabIDs(_ results: [LauncherResult]) -> [String] {
        results.compactMap {
            if case .switchToTab(let tab) = $0 { return tab.id }
            return nil
        }
    }

    private func commandCases(_ results: [LauncherResult]) -> [LauncherCommand] {
        results.compactMap {
            if case .command(let command) = $0 { return command }
            return nil
        }
    }

    private func firstIndex(ofKind matches: (LauncherResult) -> Bool,
                            in viewModel: LauncherViewModel) -> Int? {
        viewModel.results.firstIndex(where: matches)
    }

    // MARK: - Result shapes

    func testEmptyQueryShowsOpenTabsThenRecentHistory() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        let older = addTab(title: "Older", url: "https://older.example",
                           lastActiveAt: Date(timeIntervalSinceNow: -200))
        let newer = addTab(title: "Newer", url: "https://newer.example",
                           lastActiveAt: Date(timeIntervalSinceNow: -100))
        try store.recordVisit(url: "https://history.example/a", title: "A", at: Date())

        let vm = makeViewModel()

        XCTAssertEqual(vm.results.count, 3)
        XCTAssertEqual(tabIDs(vm.results), [newer.id, older.id])
        guard case .history(let entry) = vm.results[2] else {
            return XCTFail("expected a history row last, got \(vm.results[2])")
        }
        XCTAssertEqual(entry.url, "https://history.example/a")
    }

    func testSelectedTabNeverAppearsAsAResult() {
        let selected = addTab(title: "Current", url: "https://current.example", select: true)
        addTab(title: "Other", url: "https://other.example")

        let vm = makeViewModel()
        XCTAssertFalse(tabIDs(vm.results).contains(selected.id))

        // Even when the query matches ONLY the selected tab, it stays out
        // — you are already there.
        vm.query = "current"
        XCTAssertFalse(tabIDs(vm.results).contains(selected.id))
    }

    func testSelectedSpaceTabsRankAheadOfOtherSpacesThenMRU() {
        let aOld = addTab(title: "A old", url: "https://a-old.example",
                          lastActiveAt: Date(timeIntervalSinceNow: -300))
        let aNew = addTab(title: "A new", url: "https://a-new.example",
                          lastActiveAt: Date(timeIntervalSinceNow: -50))
        manager.newSpace(named: "B")
        // Oldest stamp of all — selected-space membership must still put
        // it ahead of every other-space tab.
        let bTab = addTab(title: "B tab", url: "https://b.example",
                          lastActiveAt: Date(timeIntervalSinceNow: -400))
        addTab(title: "B current", url: "https://b-current.example", select: true)

        let vm = makeViewModel()
        XCTAssertEqual(tabIDs(vm.results), [bTab.id, aNew.id, aOld.id])
    }

    func testQueryProducesTabHistoryAndTrailingSearchShapes() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        let forums = addTab(title: "Swift Forums", url: "https://forums.swift.example")
        try store.recordVisit(url: "https://blog.example/swift-tips",
                              title: "Swift Tips", at: Date())

        let vm = makeViewModel()
        vm.query = "swift"

        XCTAssertEqual(vm.results.count, 3)
        guard case .switchToTab(let tab) = vm.results[0] else {
            return XCTFail("expected the tab match first, got \(vm.results[0])")
        }
        XCTAssertEqual(tab.id, forums.id)
        guard case .history(let entry) = vm.results[1] else {
            return XCTFail("expected the history match second, got \(vm.results[1])")
        }
        XCTAssertEqual(entry.url, "https://blog.example/swift-tips")
        guard case .searchWeb("swift") = vm.results[2] else {
            return XCTFail("expected the trailing searchWeb, got \(vm.results[2])")
        }
    }

    func testCommandsComeFromTheAvailabilityClosureOnEveryRecompute() {
        addTab(title: "Current", url: "https://current.example", select: true)
        var available: [LauncherCommand] = [.newTab, .newSpace]
        let vm = makeViewModel(availableCommands: { available })

        vm.query = "new"
        XCTAssertEqual(commandCases(vm.results), [.newTab, .newSpace])

        // Availability changed while the panel is up (coordinator state
        // moved on) — the NEXT recompute must see it, proving the closure
        // is re-consulted rather than captured once.
        available = [.newTab]
        vm.query = "new"
        XCTAssertEqual(commandCases(vm.results), [.newTab])
    }

    // MARK: - Selection

    func testQueryChangeRecomputesSynchronouslyAndResetsSelection() {
        addTab(title: "Current", url: "https://current.example", select: true)
        addTab(title: "Alpha", url: "https://alpha.example")
        let beta = addTab(title: "Beta", url: "https://beta.example")

        let vm = makeViewModel()
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 1)

        vm.query = "beta"
        XCTAssertEqual(vm.selectedIndex, 0)
        // No async hop: the new results are already there on the next line.
        guard case .switchToTab(let top) = vm.results[0] else {
            return XCTFail("expected the beta tab on top, got \(vm.results[0])")
        }
        XCTAssertEqual(top.id, beta.id)
    }

    func testMoveSelectionClampsAtBothEnds() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        addTab(title: "Alpha", url: "https://alpha.example")
        addTab(title: "Beta", url: "https://beta.example")
        try store.recordVisit(url: "https://history.example", title: "H", at: Date())

        let vm = makeViewModel()
        XCTAssertEqual(vm.results.count, 3)

        vm.moveSelection(-1)
        XCTAssertEqual(vm.selectedIndex, 0, "up at the top clamps, not wraps")
        vm.moveSelection(1)
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 2)
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 2, "down at the bottom clamps, not wraps")
        vm.moveSelection(-10)
        XCTAssertEqual(vm.selectedIndex, 0, "oversized deltas clamp too")
    }

    func testEmptyResultsAreSafeForSelectionAndExecute() {
        // Only the selected tab (excluded) and no history: empty-query
        // results are genuinely empty.
        addTab(title: "Only", url: "https://only.example", select: true)

        let vm = makeViewModel()
        XCTAssertTrue(vm.results.isEmpty)
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 0)
        XCTAssertNil(vm.executeSelected(inNewTab: false))
        XCTAssertNil(vm.executeSelected(inNewTab: true))
    }

    // MARK: - executeSelected mapping (every kind, incl. the ⌘Enter variant)

    func testExecuteSwitchToTabIgnoresNewTabFlag() {
        addTab(title: "Current", url: "https://current.example", select: true)
        let other = addTab(title: "Other", url: "https://other.example")

        let vm = makeViewModel()
        XCTAssertEqual(vm.executeSelected(inNewTab: false), .switchToTab(other.id))
        XCTAssertEqual(vm.executeSelected(inNewTab: true), .switchToTab(other.id),
                       "a tab switch has no new-tab variant")
    }

    func testExecuteOpenURLMapsToNavigateRespectingNewTabFlag() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        let vm = makeViewModel()
        vm.query = "example.com"

        let index = try XCTUnwrap(firstIndex(ofKind: {
            if case .openURL = $0 { return true }
            return false
        }, in: vm))
        vm.selectedIndex = index
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(vm.executeSelected(inNewTab: false), .navigate(url, newTab: false))
        XCTAssertEqual(vm.executeSelected(inNewTab: true), .navigate(url, newTab: true))
    }

    func testExecuteSearchWebBuildsASearchURLNotABareNavigation() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        let vm = makeViewModel()
        vm.query = "example.com"

        // The trailing slot is always searchWeb; for domain-like input it
        // must SEARCH for the term, never re-parse it into a navigation.
        vm.selectedIndex = vm.results.count - 1
        let searchURL = try XCTUnwrap(AddressParser.searchURL(for: "example.com"))
        XCTAssertEqual(searchURL.host, "duckduckgo.com")
        XCTAssertEqual(vm.executeSelected(inNewTab: false),
                       .navigate(searchURL, newTab: false))
        XCTAssertEqual(vm.executeSelected(inNewTab: true),
                       .navigate(searchURL, newTab: true))
    }

    func testExecuteHistoryNavigatesToTheEntryURL() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        try store.recordVisit(url: "https://docs.example/guide", title: "Guide", at: Date())

        let vm = makeViewModel()
        vm.query = "guide"
        let index = try XCTUnwrap(firstIndex(ofKind: {
            if case .history = $0 { return true }
            return false
        }, in: vm))
        vm.selectedIndex = index
        let url = URL(string: "https://docs.example/guide")!
        XCTAssertEqual(vm.executeSelected(inNewTab: false), .navigate(url, newTab: false))
        XCTAssertEqual(vm.executeSelected(inNewTab: true), .navigate(url, newTab: true))
    }

    func testExecuteCommandMapsToRunIgnoringNewTabFlag() throws {
        addTab(title: "Current", url: "https://current.example", select: true)
        let vm = makeViewModel()
        vm.query = "close other"

        let index = try XCTUnwrap(firstIndex(ofKind: {
            if case .command(.closeOtherTabs) = $0 { return true }
            return false
        }, in: vm))
        vm.selectedIndex = index
        XCTAssertEqual(vm.executeSelected(inNewTab: false), .run(.closeOtherTabs))
        XCTAssertEqual(vm.executeSelected(inNewTab: true), .run(.closeOtherTabs),
                       "commands have no new-tab variant")
    }
}
