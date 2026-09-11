# Nyx M2 — Tabs, Spaces & Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nyx becomes a real multi-tab browser: sidebar tabs and spaces, GRDB-backed session persistence, full restore after quit/crash, and tab hibernation — plus the eight carry-over items from the M1 final review.

**Architecture:** NyxCore gains the persistence layer (`SessionStore` on GRDB) and a pure `TabLifecyclePolicy` (both unit-tested, no UI imports). The Shell gains runtime objects: `BrowserTab` (owns an optional WKWebView; hibernated tabs have none), `TabManager` (the @Observable heart: selection, creation, closing, hibernation, popup adoption, command routing), `SessionPersistence` (debounced saves + restore), `PaneViewController` (swaps the selected tab's webview, frame-based), and `NyxWindowCoordinator` (composition root — AppDelegate slims to bootstrap). The Chrome's `SidebarView` is rewritten to render manager state: space switcher, tab rows with selection/close/reorder, new-tab button. `BrowserViewModel` and the old `WebViewHostController` are deleted — their roles are absorbed by `BrowserTab`/`TabManager`/`PaneViewController` (this also resolves the M1 duplicate-title-KVO finding).

**Tech Stack:** Swift (Swift 5 language mode), AppKit, SwiftUI, WebKit, **GRDB.swift 7.x** (the only new dependency, inside NyxCore only), XcodeGen, XCTest/XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-11-nyx-browser-design.md` — this plan implements Milestone **M2** of §9 plus the M1-final-review carry-overs. Relevant sections: §3 (layers), §4 (data model), §5.2 (hibernation), §5.3 (webview management, popup adoption), §5.4 (sidebar), §7 (testing/budgets).

## Global Constraints

- Everything from the M1 plan still binds: macOS 26.0 target, Xcode 26, Swift language mode 5, XcodeGen-generated project (`Nyx.xcodeproj` gitignored), frame-based webview hosting (no Auto Layout on webviews, no SwiftUI wrapping), Safari-identical UA (only `applicationNameForUserAgent`), sandbox + `network.client`, dark-first `.darkAqua`, `DesignTokens` colors, bundle id `com.larshoofs.Nyx`.
- **GRDB.swift is pinned `from: "7.0.0"` and lives only in `NyxCore`'s Package.swift** — the app target must not depend on it directly, and no other new dependencies are allowed.
- `NyxCore` still never imports AppKit, SwiftUI, or WebKit.
- **IDs are `String`** (UUID uuidString) throughout records and runtime objects — no GRDB UUID-encoding-strategy pitfalls.
- Database lives at `~/Library/Application Support/Nyx/nyx.sqlite` (inside the sandbox container); DEBUG builds honor a `-nyx-db-path <path>` launch argument (read via `ProcessInfo.arguments` — never `UserDefaults`, which mangles launch args; see M1 Task 11).
- All existing tests must stay green after every task. The UI test suite has a documented environmental flake on this shared display (fails at ~13.3s timeout, passes on retry ~4s): retry once before treating a failure as real.
- New interactive chrome gets accessibility identifiers (existing: `"nyx.addressField"`; new in this plan: `"nyx.tabRow"`, `"nyx.newTabButton"`).
- Every commit message ends with these two trailer lines:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01KwgD5hTuE6GZrjfEQx79mw`
- All commands run from the repo root `/Users/lars/Documents/Projecten/Nyx-Browser`.

**Non-goals for M2** (explicitly out of scope): splits/pane canvas (M3), ⌘K launcher + history (M4), real favicons (globe SF Symbol placeholder for now), media-suspend policy for background panes (M3), drag-tab-onto-tab to create splits (M3), snapshot *overlays* during reactivation (M3 polish — M2 only captures/stores snapshots), night-glass shader polish (M8).

---

### Task 1: M1 carry-over cleanup batch

Four small, independent, same-shape edits — one batch, one commit.

**Files:**
- Delete: `NyxCore/Sources/NyxCore/NyxCore.swift`
- Delete: `NyxCore/Tests/NyxCoreTests/SmokeTests.swift`
- Modify: `NyxCore/Sources/NyxCore/AddressParser.swift` (make `searchURL` private)
- Modify: `NyxCore/Tests/NyxCoreTests/AddressParserTests.swift` (add `about:` test)
- Modify: `Nyx/App/AppDelegate.swift` (drop unused `import NyxCore`; wrap test hook in `#if DEBUG`)

**Interfaces:**
- Consumes: M1 tree as merged.
- Produces: no more module-shadowing `NyxCore` enum (Task 2+ can reference the module name unambiguously); `AddressParser.destinationURL(for:)` unchanged and still public.

- [ ] **Step 1: Delete the placeholder enum and its smoke test**

Delete `NyxCore/Sources/NyxCore/NyxCore.swift` and `NyxCore/Tests/NyxCoreTests/SmokeTests.swift` entirely. The AddressParser tests prove the module builds; the version constant had no consumer (M1 review: the type name shadowed the module name, which breaks `NyxCore.X` qualified lookup as the package grows).

- [ ] **Step 2: Tighten `searchURL` visibility and add the missing `about:` test**

In `AddressParser.swift` change:

```swift
    static func searchURL(for query: String) -> URL? {
```

to:

```swift
    private static func searchURL(for query: String) -> URL? {
```

In `AddressParserTests.swift` add:

```swift
    func testAboutSchemePassesThrough() {
        XCTAssertEqual(url("about:blank"), "about:blank")
    }
```

- [ ] **Step 3: AppDelegate hygiene**

Remove the now-unused `import NyxCore` line from `Nyx/App/AppDelegate.swift` (AddressParser is consumed via WebViewHostController, which imports NyxCore itself — verify with a build).

Wrap the test hook so release builds cannot render argv-supplied HTML:

```swift
        #if DEBUG
        if let testHTML = testHTMLLaunchArgument() {
            webView.loadHTMLString(testHTML, baseURL: nil)
        } else {
            content.navigate(to: "https://example.com")
        }
        #else
        content.navigate(to: "https://example.com")
        #endif
```

and wrap `testHTMLLaunchArgument()`'s definition in `#if DEBUG` / `#endif` too.

- [ ] **Step 4: Run everything**

Run: `make test-core` → expect 9 tests (8 parser + new about:, minus deleted smoke) — actually: 8 existing + 1 new = **9 tests, 0 failures**.
Run: `make build` → BUILD SUCCEEDED.
Run: `make test-ui` → TEST SUCCEEDED (retry once on the documented flake).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(m2): M1 review carry-overs — drop placeholder enum, DEBUG-gate test hook"
```

---

### Task 2: GRDB dependency into NyxCore

**Files:**
- Modify: `NyxCore/Package.swift`

**Interfaces:**
- Consumes: Task 1's tree.
- Produces: `import GRDB` available inside NyxCore targets; app target unchanged (transitively links it).

- [ ] **Step 1: Add the dependency**

Rewrite `NyxCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NyxCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NyxCore", targets: ["NyxCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "NyxCore",
                dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
```

- [ ] **Step 2: Resolve and verify**

Run: `make test-core` (SPM fetches GRDB on first run — needs network; report if fetch fails). Expected: 9 tests pass.
Run: `make build` — XcodeGen project resolves the package transitively. Expected: BUILD SUCCEEDED. If xcodebuild fails to resolve the new dependency, run `make clean && make build` once (regenerates the project + fresh resolution) before diagnosing further.

- [ ] **Step 3: Commit**

```bash
git add NyxCore/Package.swift
git commit -m "feat(m2): add GRDB 7 dependency to NyxCore"
```

---

### Task 3: SessionStore (TDD) — records, migration, round-trip

**Files:**
- Create: `NyxCore/Sources/NyxCore/SessionModel.swift`
- Create: `NyxCore/Sources/NyxCore/SessionStore.swift`
- Test: `NyxCore/Tests/NyxCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: GRDB (Task 2).
- Produces (exact API later tasks rely on):

```swift
public struct SpaceRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var orderIndex: Int
    public init(id: String, name: String, orderIndex: Int)
}

public struct TabRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var spaceID: String
    public var urlString: String
    public var title: String
    public var orderIndex: Int
    public var interactionState: Data?
    public var lastActiveAt: Date
    public init(id: String, spaceID: String, urlString: String, title: String,
                orderIndex: Int, interactionState: Data?, lastActiveAt: Date)
}

public struct SessionSnapshot: Equatable {
    public var spaces: [SpaceRecord]
    public var tabs: [TabRecord]
    public var selectedSpaceID: String?
    public var selectedTabID: String?
    public init(spaces: [SpaceRecord], tabs: [TabRecord],
                selectedSpaceID: String?, selectedTabID: String?)
}

public final class SessionStore {
    public init(databaseURL: URL) throws        // creates/migrates; WAL mode
    public func load() throws -> SessionSnapshot // ordered by orderIndex
    public func save(_ snapshot: SessionSnapshot) throws // full replace, one transaction
    public func updateInteractionState(tabID: String, data: Data?) throws
}
```

- [ ] **Step 1: Write the failing tests**

`NyxCore/Tests/NyxCoreTests/SessionStoreTests.swift`:

```swift
import XCTest
@testable import NyxCore

final class SessionStoreTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-store-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func makeSnapshot() -> SessionSnapshot {
        let space = SpaceRecord(id: "s1", name: "Personal", orderIndex: 0)
        let tabA = TabRecord(id: "t1", spaceID: "s1", urlString: "https://example.com",
                             title: "Example", orderIndex: 0,
                             interactionState: Data([0x01, 0x02]),
                             lastActiveAt: Date(timeIntervalSince1970: 1000))
        let tabB = TabRecord(id: "t2", spaceID: "s1", urlString: "https://apple.com",
                             title: "Apple", orderIndex: 1,
                             interactionState: nil,
                             lastActiveAt: Date(timeIntervalSince1970: 2000))
        return SessionSnapshot(spaces: [space], tabs: [tabA, tabB],
                               selectedSpaceID: "s1", selectedTabID: "t2")
    }

    func testFreshDatabaseLoadsEmpty() throws {
        let store = try SessionStore(databaseURL: dbURL)
        let snapshot = try store.load()
        XCTAssertTrue(snapshot.spaces.isEmpty)
        XCTAssertTrue(snapshot.tabs.isEmpty)
        XCTAssertNil(snapshot.selectedTabID)
        XCTAssertNil(snapshot.selectedSpaceID)
    }

    func testSaveLoadRoundTrip() throws {
        let store = try SessionStore(databaseURL: dbURL)
        let original = makeSnapshot()
        try store.save(original)
        let loaded = try store.load()
        XCTAssertEqual(loaded.spaces, original.spaces)
        XCTAssertEqual(loaded.tabs, original.tabs)
        XCTAssertEqual(loaded.selectedSpaceID, "s1")
        XCTAssertEqual(loaded.selectedTabID, "t2")
    }

    func testPersistsAcrossReopen() throws {
        try SessionStore(databaseURL: dbURL).save(makeSnapshot())
        let reopened = try SessionStore(databaseURL: dbURL)
        XCTAssertEqual(try reopened.load().tabs.count, 2)
    }

    func testSaveReplacesRemovedTabs() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        try store.save(snapshot)
        snapshot.tabs.removeLast()          // close t2
        snapshot.selectedTabID = "t1"
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded.tabs.map(\.id), ["t1"])
        XCTAssertEqual(loaded.selectedTabID, "t1")
    }

    func testLoadOrdersByOrderIndex() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        snapshot.tabs[0].orderIndex = 5     // t1 now sorts after t2
        try store.save(snapshot)
        XCTAssertEqual(try store.load().tabs.map(\.id), ["t2", "t1"])
    }

    func testUpdateInteractionState() throws {
        let store = try SessionStore(databaseURL: dbURL)
        try store.save(makeSnapshot())
        try store.updateInteractionState(tabID: "t2", data: Data([0xAB]))
        let loaded = try store.load()
        XCTAssertEqual(loaded.tabs.first(where: { $0.id == "t2" })?.interactionState,
                       Data([0xAB]))
        try store.updateInteractionState(tabID: "t2", data: nil)
        XCTAssertNil(try store.load().tabs.first(where: { $0.id == "t2" })?.interactionState)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-core`
Expected: FAIL — `cannot find 'SessionStore' in scope` (and the record types).

- [ ] **Step 3: Implement the model records**

`NyxCore/Sources/NyxCore/SessionModel.swift`:

```swift
import Foundation
import GRDB

/// Persistent session records (spec §4). IDs are UUID strings; a
/// SessionItem/SplitGroup layer arrives in M3 — the flat tab list with
/// orderIndex is forward-compatible with it.
public struct SpaceRecord: Codable, Equatable, Identifiable,
                           FetchableRecord, PersistableRecord {
    public static let databaseTableName = "space"
    public var id: String
    public var name: String
    public var orderIndex: Int

    public init(id: String, name: String, orderIndex: Int) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
    }
}

public struct TabRecord: Codable, Equatable, Identifiable,
                         FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tab"
    public var id: String
    public var spaceID: String
    public var urlString: String
    public var title: String
    public var orderIndex: Int
    public var interactionState: Data?
    public var lastActiveAt: Date

    public init(id: String, spaceID: String, urlString: String, title: String,
                orderIndex: Int, interactionState: Data?, lastActiveAt: Date) {
        self.id = id
        self.spaceID = spaceID
        self.urlString = urlString
        self.title = title
        self.orderIndex = orderIndex
        self.interactionState = interactionState
        self.lastActiveAt = lastActiveAt
    }
}

public struct SessionSnapshot: Equatable {
    public var spaces: [SpaceRecord]
    public var tabs: [TabRecord]
    public var selectedSpaceID: String?
    public var selectedTabID: String?

    public init(spaces: [SpaceRecord], tabs: [TabRecord],
                selectedSpaceID: String?, selectedTabID: String?) {
        self.spaces = spaces
        self.tabs = tabs
        self.selectedSpaceID = selectedSpaceID
        self.selectedTabID = selectedTabID
    }
}
```

- [ ] **Step 4: Implement the store**

`NyxCore/Sources/NyxCore/SessionStore.swift`:

```swift
import Foundation
import GRDB

/// SQLite-backed session persistence (spec §4): WAL mode for crash
/// safety; save() is a full transactional replace — session scale is
/// tens of rows, so simplicity beats delta updates.
public final class SessionStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "space") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("orderIndex", .integer).notNull()
            }
            try db.create(table: "tab") { t in
                t.column("id", .text).primaryKey()
                t.column("spaceID", .text).notNull().indexed()
                    .references("space", onDelete: .cascade)
                t.column("urlString", .text).notNull()
                t.column("title", .text).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("interactionState", .blob)
                t.column("lastActiveAt", .datetime).notNull()
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
        }
        return migrator
    }

    public func load() throws -> SessionSnapshot {
        try dbQueue.read { db in
            let spaces = try SpaceRecord.order(Column("orderIndex")).fetchAll(db)
            let tabs = try TabRecord.order(Column("orderIndex")).fetchAll(db)
            let selectedSpaceID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedSpaceID'")
            let selectedTabID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedTabID'")
            return SessionSnapshot(spaces: spaces, tabs: tabs,
                                   selectedSpaceID: selectedSpaceID,
                                   selectedTabID: selectedTabID)
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tab")
            try db.execute(sql: "DELETE FROM space")
            for space in snapshot.spaces { try space.insert(db) }
            for tab in snapshot.tabs { try tab.insert(db) }
            try db.execute(sql: "DELETE FROM meta")
            if let id = snapshot.selectedSpaceID {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('selectedSpaceID', ?)",
                               arguments: [id])
            }
            if let id = snapshot.selectedTabID {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('selectedTabID', ?)",
                               arguments: [id])
            }
        }
    }

    public func updateInteractionState(tabID: String, data: Data?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tab SET interactionState = ? WHERE id = ?",
                           arguments: [data, tabID])
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test-core`
Expected: PASS — 15 tests (9 parser + 6 store), 0 failures. If a Date round-trip fails on sub-second precision, compare with `timeIntervalSince1970` accuracy `0.001` in the test — record the change and why in your report.

- [ ] **Step 6: Commit**

```bash
git add NyxCore
git commit -m "feat(m2): SessionStore — GRDB session persistence with WAL"
```

---

### Task 4: TabLifecyclePolicy (TDD) — pure hibernation policy

**Files:**
- Create: `NyxCore/Sources/NyxCore/TabLifecyclePolicy.swift`
- Test: `NyxCore/Tests/NyxCoreTests/TabLifecyclePolicyTests.swift`

**Interfaces:**
- Produces:

```swift
public struct TabLifecyclePolicy {
    public var warmLimit: Int
    public init(warmLimit: Int = 6)
    /// mruLiveTabs: ids of tabs that currently hold a live webview,
    /// most-recently-used first. Returns the ids to hibernate now.
    /// The selected tab is never evicted regardless of position.
    public func evictionCandidates(mruLiveTabs: [String], selected: String?) -> [String]
}
```

- [ ] **Step 1: Write the failing tests**

`NyxCore/Tests/NyxCoreTests/TabLifecyclePolicyTests.swift`:

```swift
import XCTest
@testable import NyxCore

final class TabLifecyclePolicyTests: XCTestCase {
    func testUnderLimitEvictsNothing() {
        let policy = TabLifecyclePolicy(warmLimit: 6)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], selected: "a"), [])
    }

    func testOverLimitEvictsLeastRecentlyUsed() {
        let policy = TabLifecyclePolicy(warmLimit: 2)
        // selected "a" is exempt; of the rest, keep the 2 most recent (b, c)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "d", "e"], selected: "a"), ["d", "e"])
    }

    func testSelectedNeverEvictedEvenAtTail() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "sel"], selected: "sel"), ["b", "c"])
    }

    func testZeroLimitEvictsAllButSelected() {
        let policy = TabLifecyclePolicy(warmLimit: 0)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "sel"], selected: "sel"), ["a", "b"])
    }

    func testNilSelectedTreatsAllAsEvictable() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], selected: nil), ["b", "c"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-core`
Expected: FAIL — `cannot find 'TabLifecyclePolicy' in scope`.

- [ ] **Step 3: Implement**

`NyxCore/Sources/NyxCore/TabLifecyclePolicy.swift`:

```swift
/// Pure hibernation policy (spec §5.2): only the visible pane(s) plus a
/// small MRU cache of warm tabs keep live webviews; everything else is
/// hibernated (interactionState + snapshot on disk, webview destroyed).
public struct TabLifecyclePolicy {
    public var warmLimit: Int

    public init(warmLimit: Int = 6) {
        self.warmLimit = warmLimit
    }

    public func evictionCandidates(mruLiveTabs: [String], selected: String?) -> [String] {
        let evictable = mruLiveTabs.filter { $0 != selected }
        guard evictable.count > warmLimit else { return [] }
        return Array(evictable.dropFirst(warmLimit))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-core`
Expected: PASS — 20 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add NyxCore
git commit -m "feat(m2): TabLifecyclePolicy — pure MRU hibernation policy"
```

---

### Task 5: BrowserTab — runtime tab owning an optional webview

**Files:**
- Create: `Nyx/Shell/BrowserTab.swift`

**Interfaces:**
- Consumes: `TabRecord` (Task 3), `WebViewFactory` (M1), `AddressParser` (M1).
- Produces:

```swift
@MainActor @Observable final class BrowserTab: Identifiable {
    let id: String
    let spaceID: String
    var title: String
    var urlString: String
    var isLoading: Bool
    var progress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    private(set) var webView: WKWebView?          // nil = hibernated
    var pendingInteractionState: Data?
    var lastActiveAt: Date
    var onStateChange: (() -> Void)?              // fired on title/url change

    init(record: TabRecord)                        // hibernated runtime tab
    init(id: String, spaceID: String)              // fresh empty tab
    func attach(_ webView: WKWebView, uiDelegate: WKUIDelegate?)
    func hibernate() -> Data?                      // returns interactionState
    func currentInteractionState() -> Data?
    func record(orderIndex: Int) -> TabRecord
}
```

- [ ] **Step 1: Write `Nyx/Shell/BrowserTab.swift`**

```swift
import Observation
import WebKit
import NyxCore

/// Runtime tab. Owns its WKWebView (spec §5.3: webviews belong to the
/// model, never the view layer); a hibernated tab has webView == nil and
/// carries pendingInteractionState for the next activation.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: String
    let spaceID: String
    var title: String
    var urlString: String
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    private(set) var webView: WKWebView?
    var pendingInteractionState: Data?
    var lastActiveAt: Date
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(record: TabRecord) {
        id = record.id
        spaceID = record.spaceID
        title = record.title
        urlString = record.urlString
        pendingInteractionState = record.interactionState
        lastActiveAt = record.lastActiveAt
    }

    init(id: String = UUID().uuidString, spaceID: String) {
        self.id = id
        self.spaceID = spaceID
        title = ""
        urlString = ""
        pendingInteractionState = nil
        lastActiveAt = Date()
    }

    /// Wires an owned webview: KVO bridging, UI delegate, and interaction
    /// state restore. `webView` may be freshly made (activation) or handed
    /// to us by WebKit (popup adoption) — in the popup case WebKit does
    /// the loading, so we only restore state when we have some pending.
    func attach(_ webView: WKWebView, uiDelegate: WKUIDelegate?) {
        self.webView = webView
        webView.uiDelegate = uiDelegate
        if let state = pendingInteractionState {
            webView.interactionState = state
            pendingInteractionState = nil
        } else if !urlString.isEmpty,
                  webView.url == nil,
                  let url = AddressParser.destinationURL(for: urlString) {
            webView.load(URLRequest(url: url))
        }
        bindObservations(to: webView)
    }

    /// Captures interaction state, tears the webview down, and returns the
    /// captured state (also kept in pendingInteractionState).
    @discardableResult
    func hibernate() -> Data? {
        let state = currentInteractionState()
        pendingInteractionState = state
        observations = []
        webView?.uiDelegate = nil
        webView = nil
        isLoading = false
        progress = 0
        return state
    }

    func currentInteractionState() -> Data? {
        if let webView { return webView.interactionState as? Data }
        return pendingInteractionState
    }

    func record(orderIndex: Int) -> TabRecord {
        TabRecord(id: id, spaceID: spaceID, urlString: urlString, title: title,
                  orderIndex: orderIndex,
                  interactionState: currentInteractionState(),
                  lastActiveAt: lastActiveAt)
    }

    private func bindObservations(to webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.url?.absoluteString ?? ""
                Task { @MainActor in
                    guard let self, self.urlString != value, !value.isEmpty else { return }
                    self.urlString = value
                    self.onStateChange?()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.title ?? ""
                Task { @MainActor in
                    guard let self, self.title != value else { return }
                    self.title = value
                    self.onStateChange?()
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.isLoading
                Task { @MainActor in self?.isLoading = value }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor in self?.progress = value }
            }
        ]
    }
}
```

- [ ] **Step 2: Build**

Run: `make build`
Expected: BUILD SUCCEEDED (nothing consumes the class yet).

- [ ] **Step 3: Commit**

```bash
git add Nyx/Shell/BrowserTab.swift
git commit -m "feat(m2): BrowserTab runtime model with hibernation support"
```

---

### Task 6: TabManager — selection, lifecycle, commands, popup adoption

**Files:**
- Create: `Nyx/Shell/TabManager.swift`

**Interfaces:**
- Consumes: `BrowserTab` (Task 5), `TabLifecyclePolicy`, `SpaceRecord`/`TabRecord`/`SessionSnapshot` (Tasks 3–4), `WebViewFactory`, `AddressParser`, `BrowserCommands` (M1).
- Produces:

```swift
@MainActor @Observable final class TabManager: NSObject {
    private(set) var spaces: [SpaceRecord]
    private(set) var tabs: [BrowserTab]           // all spaces, ordered
    var selectedSpaceID: String?
    private(set) var selectedTabID: String?
    var addressFocusToken: Int
    var onStateChange: (() -> Void)?              // persistence trigger
    var onSelectionChange: ((BrowserTab?) -> Void)? // pane + window title

    var selectedTab: BrowserTab? { get }
    func tabs(in spaceID: String) -> [BrowserTab]
    @discardableResult func newTab(select: Bool) -> BrowserTab
    func close(_ tab: BrowserTab)
    func select(_ tab: BrowserTab)
    func select(tabID: String)
    func moveTab(fromOffsets: IndexSet, toOffset: Int, in spaceID: String)
    func newSpace(named: String)
    func restore(from snapshot: SessionSnapshot)
    func snapshotForSaving() -> SessionSnapshot
}
// conforms to BrowserCommands (routes to selectedTab) and WKUIDelegate (popup adoption)
```

- [ ] **Step 1: Write `Nyx/Shell/TabManager.swift`**

```swift
import AppKit
import Observation
import WebKit
import NyxCore

/// The heart of M2 (spec §5.2/§5.3): owns all runtime tabs and spaces,
/// drives selection, hibernation (MRU policy), popup adoption, and is the
/// BrowserCommands target for chrome and menu.
@MainActor
@Observable
final class TabManager: NSObject {
    private(set) var spaces: [SpaceRecord] = []
    private(set) var tabs: [BrowserTab] = []
    var selectedSpaceID: String?
    private(set) var selectedTabID: String?
    var addressFocusToken = 0

    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onSelectionChange: ((BrowserTab?) -> Void)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var policy: TabLifecyclePolicy
    /// Most-recently-used first; only ids of tabs holding live webviews.
    @ObservationIgnored private var mruLive: [String] = []
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(factory: WebViewFactory = .shared,
         policy: TabLifecyclePolicy = TabLifecyclePolicy()) {
        self.factory = factory
        self.policy = policy
        super.init()
        installMemoryPressureHandler()
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func tabs(in spaceID: String) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID }
    }

    // MARK: - Creation / closing / selection

    @discardableResult
    func newTab(select: Bool = true) -> BrowserTab {
        let spaceID = selectedSpaceID ?? ensureDefaultSpace()
        let tab = BrowserTab(spaceID: spaceID)
        registerCallbacks(on: tab)
        tabs.append(tab)
        if select {
            self.select(tab)
            addressFocusToken += 1
        }
        onStateChange?()
        return tab
    }

    func close(_ tab: BrowserTab) {
        tab.hibernate()
        mruLive.removeAll { $0 == tab.id }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            let remaining = tabs(in: tab.spaceID)
            if let next = remaining.last {
                select(next)
            } else {
                selectedTabID = nil
                onSelectionChange?(nil)
            }
        }
        onStateChange?()
    }

    func select(tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        select(tab)
    }

    func select(_ tab: BrowserTab) {
        guard selectedTabID != tab.id else { return }
        selectedTabID = tab.id
        selectedSpaceID = tab.spaceID
        tab.lastActiveAt = Date()
        activateIfNeeded(tab)
        touchMRU(tab.id)
        enforcePolicy()
        onSelectionChange?(tab)
        onStateChange?()
    }

    func moveTab(fromOffsets: IndexSet, toOffset: Int, in spaceID: String) {
        var inSpace = tabs(in: spaceID)
        inSpace.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tabs.removeAll { $0.spaceID == spaceID }
        tabs.append(contentsOf: inSpace)
        onStateChange?()
    }

    func newSpace(named name: String) {
        let space = SpaceRecord(id: UUID().uuidString, name: name,
                                orderIndex: (spaces.map(\.orderIndex).max() ?? -1) + 1)
        spaces.append(space)
        selectedSpaceID = space.id
        onStateChange?()
    }

    // MARK: - Persistence bridging

    func restore(from snapshot: SessionSnapshot) {
        spaces = snapshot.spaces
        tabs = snapshot.tabs.map { record in
            let tab = BrowserTab(record: record)
            registerCallbacks(on: tab)
            return tab
        }
        selectedSpaceID = snapshot.selectedSpaceID ?? spaces.first?.id
        if tabs.isEmpty {
            newTab(select: true)
        } else if let id = snapshot.selectedTabID,
                  tabs.contains(where: { $0.id == id }) {
            select(tabID: id)
        } else if let spaceID = selectedSpaceID,
                  let first = tabs(in: spaceID).first {
            select(first)
        } else if let first = tabs.first {
            select(first)
        }
    }

    func snapshotForSaving() -> SessionSnapshot {
        var ordered: [TabRecord] = []
        for (index, tab) in tabs.enumerated() {
            ordered.append(tab.record(orderIndex: index))
        }
        return SessionSnapshot(spaces: spaces, tabs: ordered,
                               selectedSpaceID: selectedSpaceID,
                               selectedTabID: selectedTabID)
    }

    // MARK: - Lifecycle internals

    private func registerCallbacks(on tab: BrowserTab) {
        tab.onStateChange = { [weak self, weak tab] in
            self?.onStateChange?()
            if let self, let tab, tab.id == self.selectedTabID {
                self.onSelectionChange?(tab)   // keeps window title fresh
            }
        }
    }

    private func activateIfNeeded(_ tab: BrowserTab) {
        guard tab.webView == nil else { return }
        tab.attach(factory.makeWebView(), uiDelegate: self)
    }

    private func touchMRU(_ id: String) {
        mruLive.removeAll { $0 == id }
        mruLive.insert(id, at: 0)
    }

    private func enforcePolicy() {
        let victims = policy.evictionCandidates(mruLiveTabs: mruLive,
                                                selected: selectedTabID)
        for id in victims {
            tabs.first { $0.id == id }?.hibernate()
            mruLive.removeAll { $0 == id }
        }
        if !victims.isEmpty { onStateChange?() }
    }

    @discardableResult
    private func ensureDefaultSpace() -> String {
        if let id = selectedSpaceID { return id }
        if let first = spaces.first { selectedSpaceID = first.id; return first.id }
        let space = SpaceRecord(id: UUID().uuidString, name: "Space", orderIndex: 0)
        spaces.append(space)
        selectedSpaceID = space.id
        return space.id
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let squeezed = TabLifecyclePolicy(warmLimit: 1)
            let victims = squeezed.evictionCandidates(
                mruLiveTabs: self.mruLive, selected: self.selectedTabID)
            for id in victims {
                self.tabs.first { $0.id == id }?.hibernate()
                self.mruLive.removeAll { $0 == id }
            }
        }
        source.resume()
        memoryPressureSource = source
    }
}

// MARK: - BrowserCommands (chrome + menu route here)

extension TabManager: BrowserCommands {
    func navigate(to input: String) {
        guard let tab = selectedTab else { return }
        activateIfNeeded(tab)
        guard let url = AddressParser.destinationURL(for: input),
              let webView = tab.webView else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { selectedTab?.webView?.goBack() }
    func goForward() { selectedTab?.webView?.goForward() }
    func reload() { selectedTab?.webView?.reload() }
    func stopLoading() { selectedTab?.webView?.stopLoading() }
}

// MARK: - WKUIDelegate (real popup adoption, spec §5.3 — replaces the M1
// same-webview fallback: target=_blank and window.open become new tabs,
// created from the configuration WebKit hands us so window.opener works)

extension TabManager: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        let sourceTab = tabs.first { $0.webView === webView }
        let spaceID = sourceTab?.spaceID ?? selectedSpaceID ?? ensureDefaultSpace()
        let tab = BrowserTab(spaceID: spaceID)
        registerCallbacks(on: tab)
        tab.attach(popup, uiDelegate: self)
        tabs.append(tab)
        select(tab)
        onStateChange?()
        return popup
    }
}
```

- [ ] **Step 2: Build**

Run: `make build`
Expected: BUILD SUCCEEDED. If `@Observable` + `NSObject` inheritance produces a macro error, report BLOCKED with the exact diagnostic — do not restructure on your own.

- [ ] **Step 3: Commit**

```bash
git add Nyx/Shell/TabManager.swift
git commit -m "feat(m2): TabManager — selection, hibernation, popup adoption"
```

---

### Task 7: SessionPersistence + database location

**Files:**
- Create: `Nyx/Shell/DatabaseLocation.swift`
- Create: `Nyx/Shell/SessionPersistence.swift`

**Interfaces:**
- Consumes: `SessionStore` (Task 3), `TabManager` (Task 6).
- Produces:

```swift
enum DatabaseLocation {
    static func url() -> URL   // App Support/Nyx/nyx.sqlite; DEBUG: -nyx-db-path override
}

@MainActor final class SessionPersistence {
    init(store: SessionStore, manager: TabManager)
    func restoreOrBootstrap()  // load + manager.restore; wires manager.onStateChange → scheduleSave
    func flushNow()            // synchronous save (terminate path)
}
```

- [ ] **Step 1: Write `Nyx/Shell/DatabaseLocation.swift`**

```swift
import Foundation

enum DatabaseLocation {
    /// Session database path. DEBUG builds honor `-nyx-db-path <path>` so
    /// UI tests get isolated databases; read via ProcessInfo — UserDefaults
    /// mangles launch arguments (see M1 Task 11's `<`-prefix bug).
    static func url() -> URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "-nyx-db-path"),
           args.index(after: flagIndex) < args.count {
            let path = args[args.index(after: flagIndex)]
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        #endif
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Nyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nyx.sqlite")
    }
}
```

- [ ] **Step 2: Write `Nyx/Shell/SessionPersistence.swift`**

```swift
import Foundation
import NyxCore

/// Debounced session writes (spec §4: continuous, ~2 s after change) plus
/// the synchronous flush for app termination. Writes are tens of rows —
/// doing them on the main actor behind a debounce is deliberate M2
/// simplicity; revisit only if profiling ever shows it.
@MainActor
final class SessionPersistence {
    private let store: SessionStore
    private let manager: TabManager
    private var saveTask: Task<Void, Never>?

    init(store: SessionStore, manager: TabManager) {
        self.store = store
        self.manager = manager
    }

    func restoreOrBootstrap() {
        let snapshot = (try? store.load())
            ?? SessionSnapshot(spaces: [], tabs: [], selectedSpaceID: nil, selectedTabID: nil)
        manager.restore(from: snapshot)
        manager.onStateChange = { [weak self] in self?.scheduleSave() }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.performSave()
        }
    }

    func flushNow() {
        saveTask?.cancel()
        performSave()
    }

    private func performSave() {
        let snapshot = manager.snapshotForSaving()
        do {
            try store.save(snapshot)
        } catch {
            NSLog("Nyx session save failed: %@", String(describing: error))
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `make build` — BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Nyx/Shell/DatabaseLocation.swift Nyx/Shell/SessionPersistence.swift
git commit -m "feat(m2): SessionPersistence — debounced saves and restore"
```

---

### Task 8: PaneViewController — swappable webview host

**Files:**
- Create: `Nyx/Shell/PaneViewController.swift`

**Interfaces:**
- Consumes: `DesignTokens` (M1).
- Produces: `@MainActor final class PaneViewController: NSViewController` with `func present(_ webView: WKWebView?)` — nil shows the empty charcoal state. Replaces the M1 `WebViewHostController` at the swap (Task 9); until then both exist.

- [ ] **Step 1: Write `Nyx/Shell/PaneViewController.swift`**

```swift
import AppKit
import WebKit

/// Hosts the selected tab's webview, frame-based (spec §5.1) — the
/// webview belongs to its BrowserTab; this controller only presents it.
/// In M3 the pane canvas will hold up to four of these side by side.
@MainActor
final class PaneViewController: NSViewController {
    private var currentWebView: WKWebView?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DesignTokens.baseSurface.cgColor
        view = container
    }

    func present(_ webView: WKWebView?) {
        guard webView !== currentWebView else { return }
        currentWebView?.removeFromSuperview()
        currentWebView = webView
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = view.bounds
        view.addSubview(webView)
    }
}
```

- [ ] **Step 2: Build**

Run: `make build` — BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Nyx/Shell/PaneViewController.swift
git commit -m "feat(m2): PaneViewController presents the selected tab's webview"
```

---

### Task 9: The swap — WindowCoordinator, manager-driven sidebar, old path deleted

The riskiest task of M2: the app moves from single-webview wiring to the tab architecture in one coherent change. Everything new already compiles (Tasks 5–8); this task rewires and deletes.

**Files:**
- Create: `Nyx/Shell/NyxWindowCoordinator.swift`
- Rewrite: `Nyx/Chrome/SidebarView.swift`
- Rewrite: `Nyx/App/AppDelegate.swift`
- Delete: `Nyx/Shell/BrowserViewModel.swift`
- Delete: `Nyx/Shell/WebViewHostController.swift`

**Interfaces:**
- Consumes: `TabManager`, `SessionPersistence`, `PaneViewController`, `DatabaseLocation`, `NyxSplitViewController`, `NyxWindowController`, `SessionStore`, `MainMenuBuilder` (menu actions retarget in Task 10 — this task keeps the existing selectors compiling by routing them through the coordinator).
- Produces:

```swift
@MainActor final class NyxWindowCoordinator: NSObject {
    let manager: TabManager
    init() throws                       // builds store→persistence→manager→UI
    func start()                        // restore session, show window
    func flushSession()                 // for termination
    func focusAddress()                 // reveals sidebar if collapsed, then focuses
    // menu plumbing:
    func newTab(); func closeTab(); func reloadPage()
    func goBack(); func goForward()
    func selectNextTab(); func selectPreviousTab()
    var canGoBack: Bool { get }; var canGoForward: Bool { get }
    var canCloseTab: Bool { get }
}
```

- [ ] **Step 1: Write `Nyx/Shell/NyxWindowCoordinator.swift`**

```swift
import AppKit
import SwiftUI
import WebKit
import NyxCore

/// Composition root (M1 final-review recommendation): owns the window,
/// the split, the pane, the manager, and persistence. AppDelegate only
/// bootstraps this and forwards menu actions.
@MainActor
final class NyxWindowCoordinator: NSObject {
    let manager: TabManager
    private let persistence: SessionPersistence
    private let pane = PaneViewController()
    private var splitViewController: NyxSplitViewController!
    private var windowController: NyxWindowController!

    init() throws {
        let store = try SessionStore(databaseURL: DatabaseLocation.url())
        manager = TabManager()
        persistence = SessionPersistence(store: store, manager: manager)
        super.init()

        let sidebar = NSHostingController(rootView: SidebarView(manager: manager))
        splitViewController = NyxSplitViewController(sidebar: sidebar, content: pane)
        windowController = NyxWindowController(contentViewController: splitViewController)

        manager.onSelectionChange = { [weak self] tab in
            self?.pane.present(tab?.webView)
            let title = tab?.title ?? ""
            self?.windowController.window?.title = title.isEmpty ? "Nyx" : title
        }
    }

    func start() {
        persistence.restoreOrBootstrap()
        windowController.showWindow(nil)
    }

    func flushSession() { persistence.flushNow() }

    // MARK: - Menu plumbing

    func newTab() { manager.newTab() }

    func closeTab() {
        guard let tab = manager.selectedTab else { return }
        manager.close(tab)
        if manager.tabs.isEmpty == false { return }
        windowController.window?.performClose(nil)
    }

    func reloadPage() { manager.reload() }
    func goBack() { manager.goBack() }
    func goForward() { manager.goForward() }

    func focusAddress() {
        // ⌘L with a collapsed sidebar must reveal it first (M1 review).
        if let item = splitViewController.splitViewItems.first, item.isCollapsed {
            item.animator().isCollapsed = false
        }
        manager.addressFocusToken += 1
    }

    func selectNextTab() { selectAdjacentTab(offset: 1) }
    func selectPreviousTab() { selectAdjacentTab(offset: -1) }

    var canGoBack: Bool { manager.selectedTab?.canGoBack ?? false }
    var canGoForward: Bool { manager.selectedTab?.canGoForward ?? false }
    var canCloseTab: Bool { manager.selectedTab != nil }

    private func selectAdjacentTab(offset: Int) {
        guard let spaceID = manager.selectedSpaceID else { return }
        let inSpace = manager.tabs(in: spaceID)
        guard !inSpace.isEmpty,
              let current = manager.selectedTab,
              let index = inSpace.firstIndex(where: { $0.id == current.id })
        else { return }
        let next = (index + offset + inSpace.count) % inSpace.count
        manager.select(inSpace[next])
    }

    #if DEBUG
    /// Test hook (offline UI tests): load inline HTML into the selected tab.
    func loadTestHTML(_ html: String) {
        guard let tab = manager.selectedTab else { return }
        if tab.webView == nil { manager.select(tab) }
        tab.webView?.loadHTMLString(html, baseURL: nil)
    }
    #endif
}
```

- [ ] **Step 2: Rewrite `Nyx/Chrome/SidebarView.swift` (manager-driven, M2 baseline)**

```swift
import SwiftUI

/// M2 sidebar: address field + tab rows for the selected space + new-tab
/// button. Space switcher and reorder arrive in Task 10; night-glass
/// polish is M8 — styling stays on DesignTokens-level restraint.
struct SidebarView: View {
    @Bindable var manager: TabManager

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var selectedSpaceTabs: [BrowserTab] {
        guard let spaceID = manager.selectedSpaceID else { return [] }
        return manager.tabs(in: spaceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer().frame(height: 30)

            navigationControls

            addressField

            if manager.selectedTab?.isLoading == true {
                ProgressView(value: manager.selectedTab?.progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
            }

            tabList

            newTabButton
        }
        .padding(12)
        .onChange(of: manager.selectedTab?.urlString ?? "") { _, newValue in
            if !addressFocused { addressText = newValue }
        }
        .onChange(of: manager.selectedTabID) { _, _ in
            addressText = manager.selectedTab?.urlString ?? ""
        }
        .onChange(of: manager.addressFocusToken) { _, _ in
            addressFocused = true
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", enabled: manager.selectedTab?.canGoBack ?? false) {
                manager.goBack()
            }
            navButton("chevron.right", enabled: manager.selectedTab?.canGoForward ?? false) {
                manager.goForward()
            }
            if manager.selectedTab?.isLoading == true {
                navButton("xmark", enabled: true) { manager.stopLoading() }
            } else {
                navButton("arrow.clockwise", enabled: manager.selectedTab != nil) {
                    manager.reload()
                }
            }
        }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(addressFocused ? 0.18 : 0.07))
            )
            .focused($addressFocused)
            .onSubmit {
                manager.navigate(to: addressText)
                addressFocused = false
            }
            .accessibilityIdentifier("nyx.addressField")
    }

    private var tabList: some View {
        List(selection: Binding(
            get: { manager.selectedTabID },
            set: { id in if let id { manager.select(tabID: id) } }
        )) {
            ForEach(selectedSpaceTabs) { tab in
                TabRow(tab: tab) { manager.close(tab) }
                    .tag(tab.id)
                    .accessibilityIdentifier("nyx.tabRow")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var newTabButton: some View {
        Button {
            manager.newTab()
        } label: {
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("nyx.newTabButton")
    }

    private func navButton(_ symbol: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// One sidebar tab row: globe placeholder (real favicons are a later
/// milestone), title or host, close button on hover.
private struct TabRow: View {
    let tab: BrowserTab
    let onClose: () -> Void

    @State private var hovering = false

    private var displayTitle: String {
        if !tab.title.isEmpty { return tab.title }
        if let host = URL(string: tab.urlString)?.host { return host }
        return "New Tab"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 3: Rewrite `Nyx/App/AppDelegate.swift`**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var coordinator: NyxWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build(delegate: self)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        do {
            let coordinator = try NyxWindowCoordinator()
            self.coordinator = coordinator
            coordinator.start()

            #if DEBUG
            if let testHTML = testHTMLLaunchArgument() {
                coordinator.loadTestHTML(testHTML)
            }
            #endif
        } catch {
            NSLog("Nyx failed to start: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.flushSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions (Task 10 extends the menu itself)

    @objc func newTab(_ sender: Any?) { coordinator?.newTab() }
    @objc func closeTab(_ sender: Any?) { coordinator?.closeTab() }
    @objc func focusAddressField(_ sender: Any?) { coordinator?.focusAddress() }
    @objc func reloadPage(_ sender: Any?) { coordinator?.reloadPage() }
    @objc func goBack(_ sender: Any?) { coordinator?.goBack() }
    @objc func goForward(_ sender: Any?) { coordinator?.goForward() }
    @objc func selectNextTab(_ sender: Any?) { coordinator?.selectNextTab() }
    @objc func selectPreviousTab(_ sender: Any?) { coordinator?.selectPreviousTab() }

    #if DEBUG
    private func testHTMLLaunchArgument() -> String? {
        // ProcessInfo, not UserDefaults: UserDefaults drops values that
        // start with '<' (parsed as plist hex-data; see M1 Task 11).
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-nyx-test-html"),
              args.index(after: flagIndex) < args.count else { return nil }
        return args[args.index(after: flagIndex)]
    }
    #endif
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return coordinator?.canGoBack ?? false
        case #selector(goForward(_:)): return coordinator?.canGoForward ?? false
        case #selector(closeTab(_:)): return coordinator?.canCloseTab ?? false
        default: return true
        }
    }
}
```

Note: `MainMenuBuilder` still references `AppDelegate.newTab`/`focusAddressField`/`reloadPage`/`goBack`/`goForward` — those selectors still exist above, so the M1 menu keeps compiling. `closeTab`/`selectNextTab`/`selectPreviousTab` become reachable when Task 10 adds their menu items (⌘W stays "Close Window" until then — acceptable for one task).

- [ ] **Step 4: Delete the superseded files**

Delete `Nyx/Shell/BrowserViewModel.swift` and `Nyx/Shell/WebViewHostController.swift`. Search the tree for remaining references (`BrowserViewModel`, `WebViewHostController`) — there must be none.

- [ ] **Step 5: Build + full test pass**

Run: `make build` → BUILD SUCCEEDED.
Run: `make test-core` → 20 tests, 0 failures.
Run: `make test-ui` → TEST SUCCEEDED (retry once on the documented flake). The existing smoke test must still pass: window appears, "Nyx Fixture" title lands (now via the coordinator's title mirroring), address field present.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(m2): tab architecture swap — coordinator, manager-driven sidebar"
```

---

### Task 10: Spaces UI + tab reorder + row polish

**Files:**
- Modify: `Nyx/Chrome/SidebarView.swift`

**Interfaces:**
- Consumes: `TabManager.spaces`, `.newSpace(named:)`, `.moveTab(fromOffsets:toOffset:in:)`, `.selectedSpaceID` (Task 6).
- Produces: sidebar with a space switcher menu and drag-reorderable tab rows.

- [ ] **Step 1: Add the space switcher above the navigation controls**

In `SidebarView.body`, insert between the top spacer and `navigationControls`:

```swift
            spaceSwitcher
```

and add the view + helper:

```swift
    private var spaceSwitcher: some View {
        Menu {
            ForEach(manager.spaces) { space in
                Button {
                    manager.selectedSpaceID = space.id
                    if let first = manager.tabs(in: space.id).first {
                        manager.select(first)
                    }
                } label: {
                    if space.id == manager.selectedSpaceID {
                        Label(space.name, systemImage: "checkmark")
                    } else {
                        Text(space.name)
                    }
                }
            }
            Divider()
            Button("New Space") {
                manager.newSpace(named: "Space \(manager.spaces.count + 1)")
                manager.newTab()
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedSpaceName)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("nyx.spaceSwitcher")
    }

    private var selectedSpaceName: String {
        manager.spaces.first { $0.id == manager.selectedSpaceID }?.name ?? "Space"
    }
```

(The small-caps tracked label follows spec §8's sidebar anatomy with existing system styling — full night-glass treatment stays M8.)

- [ ] **Step 2: Enable drag reorder on the tab list**

Add `.onMove` to the `ForEach` inside `tabList`:

```swift
            ForEach(selectedSpaceTabs) { tab in
                TabRow(tab: tab) { manager.close(tab) }
                    .tag(tab.id)
                    .accessibilityIdentifier("nyx.tabRow")
            }
            .onMove { offsets, destination in
                if let spaceID = manager.selectedSpaceID {
                    manager.moveTab(fromOffsets: offsets, toOffset: destination,
                                    in: spaceID)
                }
            }
```

- [ ] **Step 3: Build + tests**

Run: `make build`, `make test-ui` (retry once on flake). Expected: green. Manually verifiable behavior (deferred to the human spot-check): switching spaces swaps the tab list; dragging rows reorders; reorder survives restart (persistence already wired via `onStateChange`).

- [ ] **Step 4: Commit**

```bash
git add Nyx/Chrome/SidebarView.swift
git commit -m "feat(m2): space switcher and drag-reorderable tab rows"
```

---

### Task 11: Menu v2 — tab semantics + standard macOS items

**Files:**
- Modify: `Nyx/App/MainMenuBuilder.swift`

**Interfaces:**
- Consumes: `AppDelegate.closeTab(_:)`, `.selectNextTab(_:)`, `.selectPreviousTab(_:)` (Task 9).
- Produces: ⌘W closes the tab (window when none left — already the coordinator's behavior), ⇧⌘W closes the window, ⌘⇧]/⌘⇧[ cycle tabs, plus the HIG-standard items the M1 review flagged: Hide/Hide Others/Show All, Services, Window menu (Minimize/Zoom/Bring All to Front).

- [ ] **Step 1: App menu — Services and Hide block**

In `MainMenuBuilder.build`, replace the app-menu construction with:

```swift
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nyx",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nyx",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nyx",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Nyx"))
```

- [ ] **Step 2: File menu — tab-aware close semantics**

Replace the File menu's Close item block with:

```swift
        let closeTab = NSMenuItem(title: "Close Tab",
                                  action: #selector(AppDelegate.closeTab(_:)),
                                  keyEquivalent: "w")
        closeTab.target = delegate
        fileMenu.addItem(closeTab)
        let closeWindow = NSMenuItem(title: "Close Window",
                                     action: #selector(NSWindow.performClose(_:)),
                                     keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)
```

- [ ] **Step 3: View menu — tab cycling**

After the Toggle Sidebar item, add:

```swift
        viewMenu.addItem(.separator())
        let nextTab = NSMenuItem(title: "Show Next Tab",
                                 action: #selector(AppDelegate.selectNextTab(_:)),
                                 keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = delegate
        viewMenu.addItem(nextTab)
        let previousTab = NSMenuItem(title: "Show Previous Tab",
                                     action: #selector(AppDelegate.selectPreviousTab(_:)),
                                     keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        previousTab.target = delegate
        viewMenu.addItem(previousTab)
```

- [ ] **Step 4: Window menu**

Before `return main`, add:

```swift
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu
```

- [ ] **Step 5: Build + tests**

Run: `make build`, `make test-ui` (retry once on flake). Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Nyx/App/MainMenuBuilder.swift
git commit -m "feat(m2): tab-aware menu with standard macOS items"
```

---

### Task 12: UI tests — session restore, tab flow, launch baseline

**Files:**
- Modify: `NyxUITests/NyxUITests.swift`

**Interfaces:**
- Consumes: `-nyx-db-path` (Task 7), `-nyx-test-html` (M1/Task 9), `"nyx.tabRow"`/`"nyx.newTabButton"` (Task 9), ⌘T (menu).
- Produces: three UI tests + one launch-performance baseline.

- [ ] **Step 1: Rewrite `NyxUITests/NyxUITests.swift`**

```swift
import XCTest

final class NyxUITests: XCTestCase {
    private let fixtureHTML =
        "<html><head><title>Nyx Fixture</title></head><body>ok</body></html>"

    private func freshDatabasePath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-uitest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.sqlite").path
    }

    private func launch(dbPath: String, withFixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-nyx-db-path", dbPath]
        if withFixture { arguments += ["-nyx-test-html", fixtureHTML] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func tabRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "nyx.tabRow")
    }

    func testLaunchRendersPageAndChrome() {
        let app = launch(dbPath: freshDatabasePath())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["nyx.addressField"].waitForExistence(timeout: 10))
    }

    func testNewTabAppearsInSidebar() {
        let app = launch(dbPath: freshDatabasePath())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let initialCount = rows.count
        app.typeKey("t", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while rows.count < initialCount + 1 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(rows.count, initialCount + 1)
    }

    func testSessionRestoresAcrossRelaunch() {
        let dbPath = freshDatabasePath()
        var app = launch(dbPath: dbPath)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while rows.count < 3 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(rows.count, 3)

        // Debounce is 2 s; give the save a beat, then quit cleanly
        // (applicationWillTerminate also flushes synchronously).
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        app.terminate()

        app = launch(dbPath: dbPath, withFixture: false)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restoredRows = tabRows(in: app)
        let restoreDeadline = Date().addingTimeInterval(10)
        while restoredRows.count < 3 && Date() < restoreDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(restoredRows.count, 3)
    }

    func testLaunchPerformanceBaseline() {
        // Spec §7: cold launch < 500 ms to first paint. This records the
        // baseline metric (visible in the xcresult); hard-assert once the
        // number is stable across runs.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-nyx-db-path", freshDatabasePath()]
            app.launch()
            app.terminate()
        }
    }
}
```

- [ ] **Step 2: Run the suite**

Run: `make test-ui` (this environment's known flake: retry a failed run once before diagnosing). Expected: 4 tests, TEST SUCCEEDED. If `tabRows` matches nothing, inspect the accessibility tree (`XCUIApplication().debugDescription` via a temporary breakpoint-free assertion message) — List rows on macOS sometimes expose identifiers on a child element; adjust the query to `app.outlines.descendants(matching: .any).matching(identifier: "nyx.tabRow")` and record the change.
Run: `make test-core` — still 20 tests green.

- [ ] **Step 3: Commit**

```bash
git add NyxUITests/NyxUITests.swift
git commit -m "test(m2): session-restore, tab-flow, and launch-baseline UI tests"
```

---

### Task 13: Docs + wrap-up

**Files:**
- Modify: `README.md`

**Interfaces:** none new.

- [ ] **Step 1: Update the status section of `README.md`**

Replace the `## Status` section with:

```markdown
## Status

Milestone M2 (tabs & persistence): sidebar tabs and spaces, GRDB session
store with full restore after quit/crash, tab hibernation (MRU warm
cache), popup adoption (`target="_blank"` opens a real tab), tab-aware
menus. M1 delivered the skeleton: window, vibrancy sidebar, WKWebView,
address field, shortcuts, offline UI smoke test.

Next: M3 — split view (the core feature).
```

- [ ] **Step 2: Final full-suite pass**

Run: `make test-core` (20 tests) and `make test-ui` (4 tests; retry once on flake). Both green.

- [ ] **Step 3: Commit (no push — the controller pushes after the final branch review)**

```bash
git add README.md
git commit -m "docs(m2): status update for tabs, spaces, persistence"
```

---

## Self-review notes

- **Spec coverage (M2, spec §9):** sidebar tabs + spaces ✓ (T6, T9, T10), GRDB store ✓ (T2–T3), session restore ✓ (T7, T9, T12), hibernation ✓ (T4–T6; snapshots-to-disk intentionally reduced to interactionState-only — visual snapshot files add value only with the M3 canvas overlays, and spec §5.2's restore path needs only interactionState. This is a deliberate YAGNI trim recorded here).
- **Carry-overs from the M1 final review, all placed:** NyxCore enum rename→deleted (T1), real popup adoption (T6), title-mirror consolidation (T9: BrowserViewModel deleted, single per-tab KVO), standard menu items (T11), `#if DEBUG` hook (T1), launch-perf baseline (T12), AddressParser `about:` test + private `searchURL` (T1), ⌘L reveal-then-focus (T9). IPv6/`http:`-no-slashes parser polish is consciously deferred to M4 (⌘K) where address handling is next rebuilt.
- **Type consistency:** ids are `String` everywhere (records T3, policy T4, BrowserTab/TabManager T5–T6, coordinator T9). `BrowserCommands` signatures unchanged from M1; `TabManager` conformance (T6) matches what SidebarView (T9) and AppDelegate/menu (T9, T11) call. Accessibility ids `"nyx.addressField"`/`"nyx.tabRow"`/`"nyx.newTabButton"` consistent between T9 and T12. `-nyx-db-path` consistent between T7 and T12. Menu selectors added in T11 (`closeTab`, `selectNextTab`, `selectPreviousTab`) exist on AppDelegate from T9.
- **Compile-green ordering:** T5–T8 only add files; the old single-tab path keeps building until T9 swaps and deletes in one commit; T10–T11 extend the new path.
- **Known risks, called out to implementers:** `@Observable` on an `NSObject` subclass (T6 — report BLOCKED with the diagnostic if the macro objects); List-row accessibility identifier exposure on macOS (T12 — fallback query documented); GRDB fetch needs network once (T2).
