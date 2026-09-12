# Nyx M6 — Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Downloads per spec §5.7: WKDownload wired through policy decisions in the existing NavigationRelay, a DownloadManager that persists state + `resumeData` for crash/quit recovery (spec §6 failure row), and a night-glass SwiftUI popover from the sidebar — no separate window.

**Architecture:** NyxCore gains schema v5 (`download` table), `DownloadStore` (GRDB), and the pure logic that must run headless in CI (spec §7): state-transition validation, unique-filename resolution, resume-vs-fresh-restart decision. The Shell gains `DownloadManager` (@MainActor @Observable, WKDownloadDelegate; owns live items with `NSProgress`, persists every transition, rebuilds from the store on relaunch — in-flight downloads die with the app and surface as interrupted/failed). `NavigationRelay` — today only `didCommit` — gains the two `decidePolicyFor` methods (honoring `shouldPerformDownload`, `canShowMIMEType`, Content-Disposition) plus the two `didBecome` handlers, whose ONLY job is to assign the delegate immediately (forgetting this silently cancels — spec calls this out). UI: sidebar bottom bar button + `DownloadsPopover` (SwiftUI), menu item ⌥⌘L.

**Tech Stack:** No new dependencies. WKDownload/WKDownloadDelegate (macOS 26 SDK), GRDB v5 migration, SwiftUI popover via NSPopover from the AppKit sidebar host (M4 launcher-panel precedent for panel lifecycle).

**Spec:** docs/superpowers/specs/2026-09-11-nyx-browser-design.md §4 (`downloads` table), §5.7 (downloads), §6 (failure row: persist `resumeData`, offer resume, fresh-start fallback), §7 (download state machine headless in CI), §8 (night glass; colors only for states — progress/errors), §9 M6.

## Global Constraints

- Everything from M1–M5 binds. Branch `m6-downloads` from main (post-M5 merge).
- **Speed protocol (ruled, carried):** controller overlaps review(N) with implement(N+1); battery tiering: [CORE] tasks = `make build` + `make test-core` (+`make test-unit` when the unit bundle consumes the change); Shell/UI tasks and milestone gates = full battery. While the console is locked: UI-test execution queues; UI-touching tasks verify with headless `build-for-testing`; MANDATORY green `make test-ui` before the M6 merge.
- **Sandbox:** the app is sandboxed (`Nyx/Nyx.entitlements`). Real downloads require `com.apple.security.files.downloads.read-write` — added in Task 4 (the first task that writes files). Tests NEVER write to the real `~/Downloads`: `DownloadManager` takes an explicit destination directory; a DEBUG launch arg `-nyx-download-dir <path>` (ProcessInfo, house rules — UserDefaults drops `<`-prefixed values) overrides it to an in-container path for UI tests.
- WKDownload contract (spec §5.7, binding): delegate assigned in `didBecome` IMMEDIATELY (first statement); `decideDestination` must produce a path WHERE NO FILE EXISTS (WebKit never overwrites — an existing file fails the download), so unique-ify before answering; `resumeData` persisted on cancel AND failure; nil `resumeData` → fresh-restart fallback.
- Relaunch semantics (spec §5.7): in-flight downloads die with the app. On launch, rows still marked `running` are rewritten as `interrupted` (resume data almost always nil → fresh restart offered).
- Failure rows (spec §6): download fails → persist `resumeData`, offer resume, fallback fresh start. NSLog, never a dialog, never a crash.
- UI (spec §5.7/§8): SwiftUI popover from the sidebar, no separate window; colors only for states (progress, errors); a11y identifiers `nyx.downloads.*`; menu item "Downloads" ⌥⌘L in the View menu.
- All commits carry both trailers (Co-Authored-By + Claude-Session).
- Non-goals M6: download preview/QuickLook, drag-out of the popover, per-download destination picker (system save panel flow = "always ask" setting, deferred to the settings milestone), safe-browsing/quarantine beyond the system default, simultaneous-download throttling.

---

### Task 1 [CORE]: Schema v5 + DownloadStore (TDD)

**Files:**
- Modify: `NyxCore/Sources/NyxCore/NyxDatabase.swift` (append v5 migration — NEVER edit v1–v4)
- Create: `NyxCore/Sources/NyxCore/DownloadModel.swift`, `NyxCore/Sources/NyxCore/DownloadStore.swift`
- Test: `NyxCore/Tests/NyxCoreTests/DownloadStoreTests.swift`

**Interfaces (produces):**
```swift
public struct DownloadRecord: Codable, Equatable, Identifiable {
    public enum State: String, Codable { case running, finished, failed, cancelled, interrupted }
    public var id: String                  // UUID string
    public var url: String                 // source URL
    public var suggestedFilename: String
    public var destinationPath: String?    // nil until decideDestination
    public var state: State
    public var bytesReceived: Int64
    public var bytesExpected: Int64        // -1 = unknown
    public var resumeData: Data?
    public var errorMessage: String?
    public var startedAt: Date
    public var finishedAt: Date?
}
public final class DownloadStore {
    public init(database: NyxDatabase)
    public func upsert(_ record: DownloadRecord) throws
    public func all() throws -> [DownloadRecord]          // newest startedAt first
    public func delete(id: String) throws
    public func clearFinished() throws                    // finished + cancelled rows
    public func interruptInFlight() throws -> Int         // running → interrupted; returns count
}
```

v5 migration: `download` table, TEXT PK `id`, columns matching the record (state TEXT, resume_data BLOB nullable, bytes as INTEGER). TDD: round-trip with and without resumeData/destination; ordering; `interruptInFlight` flips only `running` rows and returns the count; `clearFinished` leaves running/failed/interrupted untouched; v4→v5 migration on a populated v4 database preserves history/session/site_override rows (copy the populated-migration test pattern from `NyxDatabaseTests` v3→v4).

Battery [CORE]: build + test-core. Commit: `feat(m6): schema v5 + DownloadStore`

### Task 2 [CORE]: Download decision logic (TDD — the headless state machine, spec §7)

**Files:**
- Create: `NyxCore/Sources/NyxCore/DownloadLogic.swift`
- Test: `NyxCore/Tests/NyxCoreTests/DownloadLogicTests.swift`

**Interfaces (produces):**
```swift
public enum DownloadLogic {
    /// Valid state transitions; the manager refuses anything else.
    public static func canTransition(from: DownloadRecord.State, to: DownloadRecord.State) -> Bool
    /// "report.pdf" taken → "report (2).pdf"; case-insensitive comparison,
    /// preserves the extension, increments until free.
    public static func uniqueFilename(_ suggested: String, taken: (String) -> Bool) -> String
    /// Spec §6: resumeData present → .resume(data); nil → .freshStart.
    public enum RetryAction: Equatable { case resume(Data), freshStart }
    public static func retryAction(for record: DownloadRecord) -> RetryAction?  // nil when not retryable (finished/running)
}
```

Transition table (test every cell): `running → finished|failed|cancelled` valid; `failed|cancelled|interrupted → running` valid (retry); everything else invalid (`finished` is terminal; `interrupted` is set only by the launch rebuild, never at runtime). `uniqueFilename`: no-extension names, dotfiles (".zshrc"), multi-dot names ("archive.tar.gz" → "archive (2).tar.gz" is acceptable and pinned — document the simple `.lastDotSplit` choice), the counter scans until free. `retryAction`: failed+data → resume, failed+nil → freshStart, interrupted+nil → freshStart, cancelled+data → resume, finished/running → nil.

Battery [CORE]: build + test-core. Commit: `feat(m6): download state machine + naming logic`

### Task 3: DownloadManager (Shell)

**Files:**
- Create: `Nyx/Shell/DownloadManager.swift`
- Test: `NyxTests/DownloadManagerTests.swift` (hosted bundle)

**Interfaces (consumes):** `DownloadStore`, `DownloadLogic`, `DownloadRecord` from T1/T2.
**Interfaces (produces):**
```swift
@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    struct Item: Identifiable { let id: String; var record: DownloadRecord; var progress: Progress? }
    private(set) var items: [Item]                    // newest first; live + historical
    init(store: DownloadStore, destinationDirectory: URL)
    func adopt(_ download: WKDownload)                // delegate = self FIRST STATEMENT; creates running record
    func cancel(id: String)                           // captures resumeData via cancel { }
    func retry(id: String, host: WKWebView)           // DownloadLogic.retryAction → host.resumeDownload(fromResumeData:) or host.startDownload(using: URLRequest(url:))
    func remove(id: String)                           // delete row + drop item (never cancels a running one)
    func clearFinished()
    func rebuildFromStore()                           // called once at startup: store.interruptInFlight() + load all()
    var onItemsChanged: (() -> Void)?                 // coordinator hook (badge, popover refresh)
}
```

WKDownloadDelegate: `decideDestination(suggestedFilename:)` → `DownloadLogic.uniqueFilename` against `FileManager.fileExists` in `destinationDirectory`, persist `destinationPath` + `suggestedFilename`, answer the full URL; `didFinish` → state finished + finishedAt; `didFailWithError(_:resumeData:)` → state failed + resumeData + errorMessage + NSLog (never a dialog). Progress: mirror `download.progress` into the item (`bytesReceived/bytesExpected` persisted on transitions only — no per-byte DB writes; pin with a test that a running item's record in the DB still shows the started values until a transition). Store failures: NSLog + keep the in-memory item consistent (spec §6 — storage trouble never breaks the download itself). Every transition guarded by `DownloadLogic.canTransition` (invalid → NSLog + ignore, test this). `retry` reuses the SAME record id (running again, resumeData cleared). Unit tests drive the record/store paths directly and via the delegate methods with a real `WKDownload`-free seam where needed — house precedent: re-compose pieces honestly (AdblockMenuToggleTests header pattern), document what only the queued UI run proves.

Battery (Shell tier): build + test-core + test-unit. Commit: `feat(m6): DownloadManager — persisted state, resume, relaunch rebuild`

### Task 4: Policy decisions + funnel wiring (NavigationRelay + coordinator + entitlement)

**Files:**
- Modify: `Nyx/Shell/BrowserTab.swift` (NavigationRelay: 2× decidePolicyFor + 2× didBecome; `onDownloadStarted: ((WKDownload) -> Void)?` on BrowserTab, wired in TabManager.registerCallbacks like ContentRulePolicy/onContentRulesActed)
- Modify: `Nyx/Shell/TabManager.swift` (thread the callback), `Nyx/Shell/NyxWindowCoordinator.swift` (owns DownloadManager: store on the shared NyxDatabase, destination = `-nyx-download-dir` override else `FileManager.urls(for: .downloadsDirectory)`; `rebuildFromStore()` in start(); routes `onDownloadStarted` → `downloadManager.adopt`)
- Modify: `Nyx/Nyx.entitlements` (+`com.apple.security.files.downloads.read-write`), `Nyx/App/AppDelegate.swift` (parse `-nyx-download-dir`, ProcessInfo pattern next to `-nyx-db-name`)
- Test: `NyxTests/DownloadPolicyTests.swift`

**Policy (spec §5.7, exact):**
```swift
// NavigationRelay additions — default is ALWAYS .allow; downloads are the exception.
func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
}
func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    decisionHandler(Self.shouldDownload(navigationResponse) ? .download : .allow)
}
// Pure, unit-testable: download iff !canShowMIMEType, or Content-Disposition
// declares an attachment (case-insensitive prefix "attachment" on the header value).
static func shouldDownload(_ response: WKNavigationResponse) -> Bool
```
`didBecome` (both variants): FIRST statement hands the download to the tab callback (which sets the delegate synchronously inside `adopt`) — a comment citing the spec's silent-cancel warning. `shouldDownload` logic extracted so the HTTPURLResponse/Content-Disposition matrix is unit-tested without WebKit fakes: canShow+no-header → allow; canShow+`attachment; filename="x"` → download; canShow+`inline` → allow; !canShow → download; non-HTTP response → download only when !canShow. REGRESSION GUARD: adding `decidePolicyFor` touches every navigation — full unit suite green + `build-for-testing`; the existing UI suite (queued or live) is the real gate that ordinary browsing still navigates.

Battery (Shell tier): full (UI execution queued if console locked). Commit: `feat(m6): download policy decisions + adoption funnel`

### Task 5: DownloadsPopover + sidebar entry + menu (night glass)

**Files:**
- Create: `Nyx/Chrome/DownloadsPopover.swift` (SwiftUI list: filename, host, progress bar or state line, per-row actions cancel/retry/reveal-in-Finder, footer "Clear Finished"; colors only for states per §8 — accent progress tint, red error text; empty state text)
- Modify: `Nyx/Chrome/SidebarView.swift` (bottom bar button, badge dot while any download is running — the spec's "bottom card" slot), `Nyx/Shell/NyxWindowCoordinator.swift` (NSPopover host, `toggleDownloadsPopover()`, M4 LauncherPanelController lifecycle precedent: transient behavior, key-monitor-free — NSPopover handles dismissal), `Nyx/App/MainMenuBuilder.swift` + `Nyx/App/AppDelegate.swift` (View ▸ "Downloads", ⌥⌘L, always enabled)
- Test: `NyxTests/DownloadsPopoverModelTests.swift` (row presentation logic: byte formatting via ByteCountFormatter, state → subtitle/action-set mapping, reveal only when destinationPath exists on disk)

a11y: `nyx.downloads.button` (sidebar), `nyx.downloads.popover`, `nyx.downloads.row` (+ per-row value = filename), `nyx.downloads.clear`. Row action mapping is pure and tested: running → [cancel]; failed/cancelled/interrupted → [retry, remove]; finished → [reveal, remove] (reveal disabled when the file no longer exists — stale-row honesty). `NSWorkspace.activateFileViewerSelecting` for reveal. Retry needs a host webview: coordinator passes the selected tab's (or any live) webview; no live webview → NSLog + no-op, pinned by test.

Battery (Shell/UI tier): full (UI execution queued if console locked). Commit: `feat(m6): downloads popover + sidebar + menu`

### Task 6: UI tests (offline, deterministic)

**Files:**
- Modify: `NyxUITests/NyxUITests.swift` (+2 tests), `Nyx/App/AppDelegate.swift` (DEBUG hook `-nyx-start-test-download` — starts one download of a `data:` URL via the selected tab's `webView.startDownload(using:)` after coordinator start; deterministic, offline, no fixture-server)

Tests (house conventions: fresh db names, `-nyx-download-dir` into the container, fresh queries per phase, bounded polls, `app.activate()` before menu clicks):
1. `testDownloadCompletesAndShowsInPopover` — launch with `-nyx-start-test-download` + in-container download dir; open popover via ⌥⌘L (menu path); poll for `nyx.downloads.row` with the expected filename; assert the file exists at the expected container path.
2. `testDownloadHistoryRestoredAfterRelaunch` — same flow, terminate, relaunch same db-name WITHOUT the start-download arg; open popover; the finished row is still there (store rebuild), and its state is finished (not interrupted — it completed pre-quit).
Pre-authorized fallback (record if used): if `startDownload(using:)` on a `data:` URL proves unreliable, serve the bytes via a `blob:`/anchor-click inside `-nyx-test-html` and drive a real in-page click; if THAT is also unreliable, assert through a `-nyx-dump-downloads-state <path>` file dump (T8/M5 precedent) and keep the popover assertions in test 1 only.
If the console is locked: WRITE+COMPILE mode (headless `build-for-testing`), execution queued into the mandatory pre-merge `make test-ui` run (M5 T8 precedent). Suite target after unlock: 14 UI tests.

Battery: full battery / locked-console tier as applicable. Commit: `test(m6): download UI coverage` (+ "(execution queued)" suffix when applicable)

### Task 7 [DOCS]: Wrap + M5 carried doc-nits

**Files:**
- Modify: `README.md` (M6 line: downloads — WKDownload policy funnel, resume-data persistence, sidebar popover; next: M7 vault)
- Modify: `Nyx/Shell/BrowserTab.swift` (M5 re-review nit N-1: bleed-doc intro clause "lasts only until the marker is next invalidated" → "created and repaired at the same act — the affected side's next evaluation always acts"), `NyxTests/ContentRuleEvaluationTests.swift` (N-2: stale "Without adoption invalidating…" comment → describe the act-time callback), `.superpowers/sdd/2026-09-11-m5-adblock/fixwave-report.md` is NOT touched (reports are frozen records; N-3 noted in the M6 ledger instead).

Battery: docs tier (build + test-core + test-unit — comment-only source edits must not disturb anything). Commit: `docs(m6): status update + M5 doc-nit pass`

---

## Self-review notes

- Spec §5.7 coverage: policy decisions honoring shouldPerformDownload/canShowMIMEType/Content-Disposition ✓ (T4), delegate-in-didBecome-immediately ✓ (T3/T4 + comment), unique destinations ✓ (T2 logic + T3 filesystem check), NSProgress ✓ (T3/T5), resumeData persisted on cancel/failure ✓ (T3), fresh-restart fallback ✓ (T2 retryAction), in-flight dies with app + rebuild from store ✓ (T1 interruptInFlight + T3 rebuildFromStore), sidebar popover not a window ✓ (T5).
- Spec §6 failure row ✓ (T2/T3); §7 headless state machine ✓ (T2 pure); §4 `downloads` table ✓ (T1).
- Type-consistency pass: `DownloadRecord.State` names match between T1 table/T2 transitions/T3 manager/T5 action mapping; `adopt(_:)`/`onDownloadStarted` names consistent T3↔T4.
- Sandbox risk named: downloads entitlement lands in T4 with the first writing code path; UI tests never touch real ~/Downloads (arg override designed in T3's init + T4's parsing).
- Known unknown owned by T6 with pre-authorized fallbacks: `data:`-URL `startDownload` behavior.
- Deliberately NOT planned: popup-window download edge (a download initiated as a new-window navigation) — the response-path policy in the ADOPTED tab covers it through the same relay; if the queued UI run or M7 usage disproves this, it becomes an M7 carried item.
