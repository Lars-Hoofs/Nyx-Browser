# Nyx M4 — ⌘K Launcher & Searchable History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One keystroke (⌘K) opens a glass launcher that searches open tabs, full browsing history (FTS5), commands, and falls through to URL/search — the keyboard-first heart of the spec (§5.5). History is recorded automatically from real navigations.

**Architecture:** Schema ownership moves to a shared `NyxDatabase` (one DatabaseQueue, one migrator v1–v3) with `SessionStore`/`HistoryStore` as facades — v3 adds `history_entry` + an FTS5 mirror with sync triggers. A pure `LauncherRanker` in NyxCore merges/scores sources (TDD). `BrowserTab` gains its first `WKNavigationDelegate` (the seam the M3 final review named): committed http/https navigations flow through a coordinator-wired recorder into the store. The launcher itself is an `NSPanel` + SwiftUI glass overlay driven by a view model that queries the ranker; Enter executes in the current tab, ⌘Enter in a new tab.

**Tech Stack:** unchanged. No new dependencies (FTS5 ships inside GRDB's SQLite).

**Spec:** `docs/superpowers/specs/2026-09-11-nyx-browser-design.md` §4 (history + FTS5), §5.5 (launcher), §9 M4.

## Global Constraints

- Everything from M1–M3 binds (macOS 26, Swift 5 mode, XcodeGen, frame-based webviews, Safari UA, sandbox, dark-first, String ids, GRDB only in NyxCore, ProcessInfo launch args, trailers on every commit — both lines).
- Branch `m4-launcher`, cut from main (post-M3). Full verification battery per task: `make build` (zero warnings) + `make test-core` + `make test-unit` + `make test-ui` (pkill -x Nyx between; one retry on the documented flake signatures; poll-confirm hardening pattern for any new ⌘-keystroke assertions).
- History records **http/https only** — never about:, data:, file:, blob:, or loadHTMLString content. Recording is fire-and-forget: a failed write logs and never blocks navigation.
- Launcher a11y ids: panel `"nyx.launcher"`, field `"nyx.launcherField"`, result rows `"nyx.launcherRow"`.
- ⌘L keeps its current meaning (sidebar address field). ⌘K is the launcher. Esc closes it; it never steals focus while closed.
- Migration discipline: v1/v2 registrations are never edited; v3 appends. `NyxDatabase` owns ALL migrations; the old `SessionStore(databaseURL:)` init keeps working (backed by NyxDatabase internally) so no call site churn outside NyxCore.
- Non-goals M4: adblock/downloads commands in the launcher (arrive with M5/M6), history UI beyond the launcher (no history window), sync, favicons, autocomplete-in-address-field.

---

### Task 1: NyxDatabase refactor + HistoryStore (TDD)

**Files:**
- Create: `NyxCore/Sources/NyxCore/NyxDatabase.swift`
- Create: `NyxCore/Sources/NyxCore/HistoryStore.swift`
- Modify: `NyxCore/Sources/NyxCore/SessionStore.swift` (becomes a facade over NyxDatabase; public init unchanged)
- Test: `NyxCore/Tests/NyxCoreTests/HistoryStoreTests.swift`

**Interfaces:**

```swift
public final class NyxDatabase {
    public init(databaseURL: URL) throws        // opens queue (WAL), runs migrator v1..v3
    // internal: let dbQueue: DatabaseQueue
}

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public var id: String            // the url string (unique key)
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisitedAt: Date
}

public final class HistoryStore {
    public init(database: NyxDatabase)
    public func recordVisit(url: String, title: String, at date: Date) throws
        // upsert on url: visitCount += 1, lastVisitedAt = date, title updated when non-empty
    public func updateTitle(url: String, title: String) throws   // no-op if row absent or title empty
    public func search(_ query: String, limit: Int) throws -> [HistoryEntry]
        // FTS5 prefix match over url+title tokens; ranked by bm25 combined with
        // recency/frequency (frecency = visitCount weighted by lastVisitedAt age)
    public func recent(limit: Int) throws -> [HistoryEntry]      // by lastVisitedAt desc
    public func deleteAll() throws
}

// SessionStore: public init(databaseURL: URL) throws  → internally builds/uses NyxDatabase
//               NEW public init(database: NyxDatabase) — the shared path the app uses from M4 on
```

Migration v3 (appended in NyxDatabase's migrator, which absorbs the v1/v2 registrations VERBATIM from SessionStore — move, don't retype):

```swift
migrator.registerMigration("v3") { db in
    try db.create(table: "history_entry") { t in
        t.column("url", .text).primaryKey()
        t.column("title", .text).notNull()
        t.column("visitCount", .integer).notNull()
        t.column("lastVisitedAt", .datetime).notNull().indexed()
    }
    try db.create(virtualTable: "history_fts", using: FTS5()) { t in
        t.synchronize(withTable: "history_entry")   // GRDB external-content sync
        t.column("url")
        t.column("title")
        t.tokenizer = .unicode61()
    }
}
```

(If GRDB's `synchronize(withTable:)` requires an integer rowid PK, adapt: give `history_entry` an autoincrement id + unique index on url, and record the adaptation. The FTS mirror must stay in sync through the triggers GRDB generates.)

TDD (write first, RED, implement, GREEN): round-trip recordVisit (new + repeat visit increments count and refreshes date), updateTitle semantics, search matches by title word AND by url fragment with prefix queries ("gith" finds github.com), frecency ranking (older-but-frequent vs recent-but-rare — assert a recent frequent entry outranks both), recent() ordering, deleteAll, migration-from-v2 data preserved (SessionStore round-trip still green — the existing 12 SessionStore tests must pass unchanged via the facade).

Commit: `feat(m4): NyxDatabase + HistoryStore with FTS5 search`

---

### Task 2: LauncherRanker (TDD) — pure result merging

**Files:**
- Create: `NyxCore/Sources/NyxCore/LauncherRanker.swift`
- Test: `NyxCore/Tests/NyxCoreTests/LauncherRankerTests.swift`

**Interfaces:**

```swift
public struct LauncherTabInfo: Equatable {
    public var id: String
    public var title: String
    public var url: String
    public init(id: String, title: String, url: String)
}

public enum LauncherCommand: String, CaseIterable, Equatable {
    case newTab = "New Tab"
    case splitWithNextTab = "Split with Next Tab"
    case breakUpSplit = "Break Up Split"
    case closeOtherTabs = "Close Other Tabs"
    case newSpace = "New Space"
}

public enum LauncherResult: Equatable {
    case switchToTab(LauncherTabInfo)
    case openURL(URL)               // AddressParser-derived
    case searchWeb(String)          // DuckDuckGo fallthrough
    case history(HistoryEntry)
    case command(LauncherCommand)
}

public struct LauncherRanker {
    public init()
    /// Empty query → open tabs (MRU order as given) then recent history.
    /// Non-empty → ranked: tab matches (title/url substring, prefix-boosted),
    /// a single openURL when AddressParser parses the query as a URL,
    /// history matches (already store-ranked, passed through), command
    /// matches (name substring), and always a trailing searchWeb.
    /// Max `limit` results; openURL/searchWeb never both absent.
    public func results(query: String,
                        openTabs: [LauncherTabInfo],
                        history: [HistoryEntry],
                        commands: [LauncherCommand],
                        limit: Int) -> [LauncherResult]
}
```

TDD the contract above: empty-query shape; tab title prefix beats tab url substring; URL-parseable query yields openURL above history; command match appears for "split"; searchWeb always last and always present for non-empty queries; limit respected with searchWeb still included; case-insensitive matching; no duplicate of a history entry whose url equals an open tab's url (tab wins, history entry dropped).

Commit: `feat(m4): LauncherRanker — pure launcher result ranking`

---

### Task 3: Navigation recording — the WKNavigationDelegate seam

**Files:**
- Modify: `Nyx/Shell/BrowserTab.swift` (navigation delegate + committed-URL callback)
- Modify: `Nyx/Shell/SessionPersistence.swift` (owns HistoryStore wiring? NO — see below)
- Create: `Nyx/Shell/HistoryRecorder.swift`
- Modify: `Nyx/Shell/NyxWindowCoordinator.swift` (build NyxDatabase once; SessionStore + HistoryStore share it; wire recorder)
- Test: extend `NyxTests` (recorder filtering logic via a pure helper)

**Interfaces:**

```swift
// BrowserTab additions
@ObservationIgnored var onNavigationCommitted: ((URL) -> Void)?
// attach(_:uiDelegate:) also sets webView.navigationDelegate to an internal
// NavigationRelay (NSObject, WKNavigationDelegate) owned by the tab that
// forwards didCommit's webView.url into onNavigationCommitted. The relay is
// created per attach and torn down in hibernate() alongside KVO.

@MainActor final class HistoryRecorder {
    init(store: HistoryStore)
    func wire(_ tab: BrowserTab)     // sets onNavigationCommitted + hooks title
    /// Pure, testable: only http/https URLs are recordable.
    nonisolated static func isRecordable(_ url: URL) -> Bool
}
```

- Coordinator init: `let database = try NyxDatabase(databaseURL: dbURL)` (quarantine/retry logic moves around this call, preserved); `SessionStore(database:)`, `HistoryStore(database:)`, `HistoryRecorder(store:)`. TabManager gains `@ObservationIgnored var onTabCreated: ((BrowserTab) -> Void)?` fired from newTab/popup-adoption/restore-rebuild so the coordinator can `recorder.wire(tab)` every tab exactly once.
- Title enrichment: recorder hooks the tab's existing title flow — on title change of a wired tab whose current url is recordable, `updateTitle`. (Reuse `onStateChange`? NO — that's persistence's. Add the minimal dedicated hook `onTitleChangedForHistory` or have the recorder observe via its own closure slot; record your choice.)
- Failure semantics: recorder try? + NSLog per global constraints.
- Unit tests: `isRecordable` (http/https yes; about/data/file/blob no); a fake-store test that wire→simulated commit records and title-change enriches (HistoryStore against an in-memory/temp NyxDatabase is fine — it's NyxCore, usable from NyxTests).

Commit: `feat(m4): navigation-committed history recording`

---

### Task 4: Launcher panel shell

**Files:**
- Create: `Nyx/Shell/LauncherPanelController.swift`
- Create: `Nyx/Chrome/LauncherView.swift` (static shell this task: field + placeholder list)

**Interfaces:**

```swift
@MainActor final class LauncherPanelController {
    init(contentProvider: @escaping () -> LauncherView)   // or generic AnyView — keep simple, record choice
    func toggle(over window: NSWindow?)   // show centered at top-third, 640×~420 max; hide if visible
    func hide()
    var isVisible: Bool { get }
    var onDismiss: (() -> Void)?
}
```

- NSPanel: `.titled`-less style (`[.nonactivatingPanel]`? NO — the field must type: use a key-able borderless panel: styleMask `[.borderless]`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = false`, `level = .floating`, canBecomeKey override true). Background: `NSVisualEffectView` (.hudWindow material, withinWindow) + rounded 16pt corners + hairline border per §8 tokens; content = NSHostingView(LauncherView).
- Esc closes: the panel's `cancelOperation(_:)` or a keyDown monitor inside the panel — record choice. Clicking outside closes (panel resigns key → hide).
- a11y: panel content view identifier `"nyx.launcher"`.

Commit: `feat(m4): launcher panel shell with glass chrome`

---

### Task 5: Launcher behavior — wiring it all

**Files:**
- Create: `Nyx/Chrome/LauncherViewModel.swift` (@MainActor @Observable)
- Modify: `Nyx/Chrome/LauncherView.swift` (real list, keyboard nav)
- Modify: `Nyx/Shell/NyxWindowCoordinator.swift` (owns panel + view model; `showLauncher()`)

**Interfaces:**

```swift
@MainActor @Observable final class LauncherViewModel {
    var query: String { didSet → recompute }
    private(set) var results: [LauncherResult]
    var selectedIndex: Int
    init(manager: TabManager, history: HistoryStore, ranker: LauncherRanker,
         availableCommands: @escaping () -> [LauncherCommand])
    func moveSelection(_ delta: Int)
    func executeSelected(inNewTab: Bool) -> LauncherAction?   // returns what to do
}

enum LauncherAction: Equatable {
    case switchToTab(String)
    case navigate(URL, newTab: Bool)
    case run(LauncherCommand)
}
```

- Recompute synchronously on query change: openTabs from manager (selected space first, MRU-ish — document), history via `store.search(query, limit: 12)` (`recent` when empty), commands filtered by coordinator state (`splitWithNextTab` only when canSplit etc. via the injected closure). Sub-10ms at realistic history sizes; no async.
- LauncherView: TextField (plain, monospaced for URLs per §8, id `"nyx.launcherField"`, auto-focused on show) + result rows (id `"nyx.launcherRow"`, icon per kind via SF Symbols, selected row = white 8% rounded highlight). ↑/↓ move, Enter executes, ⌘Enter = newTab variant, Esc dismisses.
- Coordinator executes LauncherAction: switchToTab → manager.select(tabID:); navigate → current tab (or newTab first) manager.navigate; run → existing coordinator methods (newTab/splitWithNextTab/breakUpSplit/closeOtherTabs [ADD closeOtherTabs to TabManager: closes all in space except selected, respecting group semantics via close()], newSpace via manager).
- `closeOtherTabs` lands in TabManager with a unit test (survivors: selected tab’s whole group stays).

Commit: `feat(m4): launcher search, keyboard nav, and command execution`

---

### Task 6: Menu integration

**Files:** `Nyx/App/MainMenuBuilder.swift`, `Nyx/App/AppDelegate.swift`

View menu, above Open Location: "Open Launcher" ⌘K → AppDelegate.openLauncher → coordinator.showLauncher(). Validation: always enabled. Collision check (⌘K free today).

Commit: `feat(m4): ⌘K menu command`

---

### Task 7: UI tests

**Files:** `NyxUITests/NyxUITests.swift`, plus a DEBUG seed hook.

- DEBUG launch arg `-nyx-seed-history "<url>|<title>"` (repeatable? one is enough) handled in AppDelegate after coordinator start: seeds HistoryStore via recordVisit. ProcessInfo parsing per house rules.
- `testLauncherOpensAndFilters`: launch with seeded history entry ("https://example.org/docs|Nyx Example Docs"); ⌘K → `"nyx.launcherField"` exists and has focus (type "docs"); a `"nyx.launcherRow"` containing the seeded title appears (poll 5s).
- `testLauncherSwitchesTabs`: two tabs (⌘T with poll-confirm), first tab loaded fixture "Nyx Fixture"; ⌘K, type "fixture", Enter → window title becomes "Nyx Fixture" (poll 10s).
- Existing 6 tests untouched. Full battery: 8/8 UI.

Commit: `test(m4): launcher UI coverage with seeded history`

---

### Task 8: Docs + wrap

README Status → M4 line (⌘K launcher: tabs/history/commands/URL fallthrough, FTS5 history with frecency; next: M5 adblock). Full battery. Commit `docs(m4): status update for launcher and history` (no push).

---

## Self-review notes

- Spec §9 M4 ✓ (launcher with tabs/history/commands ✓ T2/T5, FTS5 history ✓ T1, recording ✓ T3, ⌘K ✓ T4/T6). §5.5's "address bar expanded mode" reading: ⌘L stays sidebar field (constraint), full launcher on ⌘K — matches spec text.
- Carried M3 items placed: WKNavigationDelegate seam (T3, as the M3 review prescribed); constraints-doc db-arg drift → fix in the M4 workspace constraints file at setup (controller); per-space next-tab validation + TabManager extraction remain M5 notes.
- Type consistency: LauncherResult/HistoryEntry shapes consistent T1↔T2↔T5; `"nyx.launcher*"` ids T4/T5↔T7; NyxDatabase shared init T1↔T3.
- Risks flagged to implementers: GRDB FTS5 synchronize-vs-rowid (T1 records adaptation); borderless-panel key handling (T4 records choice); launcher focus vs first-responder guard from M3 (T5: showing the panel makes IT key — the coordinator's responder-follow must not fight the panel; the transition gate only fires on selection changes, so opening the launcher is safe — verify in T5).
