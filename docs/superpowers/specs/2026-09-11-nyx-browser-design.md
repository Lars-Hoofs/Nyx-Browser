# Nyx Browser — Design Spec

**Date:** 2026-09-11
**Status:** Approved direction, pending final review
**Platform:** macOS 26 (Tahoe) and later, Apple silicon
**Language/stack:** Swift · AppKit shell · SwiftUI chrome · WKWebView engine

## 1. What Nyx is

Nyx is a minimalist, high-performance native macOS browser. No telemetry, no AI
features, no visual noise. Its defining feature is **flat split-view browsing**:
two, three, or four pages side by side as first-class citizens of the tab model.

Design pillars, in priority order:

1. **Performance** — measurable budgets, enforced from milestone 1 (see §9).
2. **Aesthetics** — real macOS materials (behind-window vibrancy/blur), dark,
   quiet, Arc-style sidebar. Native controls, native feel, 120 fps interactions.
3. **Daily-driver capability** — adblock, ⌘K launcher, session restore,
   history, downloads, password autofill. All in v1, built in milestones.

### Non-goals for v1

- WebExtensions support (a multi-year effort — even Kagi calls it their
  bottleneck). Revisit after v1.
- Sync beyond what iCloud Keychain gives us for free.
- iOS, Windows, or Linux. A port would be a separate shell on the same core.
- Profiles / multiple website data stores. Spaces are organizational only in v1.
- YouTube video-ad blocking (requires scriptlet warfare; out of scope for v1).

## 2. Engine and platform decisions (researched, settled)

These were verified against Apple docs, WebKit sources, and shipping WKWebView
browsers (Safari, Orion, DuckDuckGo, Beam) in Sept 2026:

- **Engine: system WKWebView.** Safari-class performance and battery life;
  FairPlay DRM (Netflix, Spotify) is enabled by default in WKWebView — verified
  in WebKit's `UnifiedWebPreferences.yaml`. No entitlement needed for playback.
- **Process model is automatic.** One WebContent process per live tab
  (~150–300 MB each); `WKProcessPool` is a deprecated no-op. We do not fight
  this — we design around it with tab hibernation (§5.2).
- **User agent must be byte-identical to Safari.** We set only
  `applicationNameForUserAgent` to match Safari's suffix and never append a Nyx
  token — custom UA tokens are what trigger Netflix's "install the app" page
  and Google's "browser not secure" block. Per-site UA overrides ship in v1 as
  the escape hatch (Firefox UA on `accounts.google.com` if Google ever flags us).
- **iCloud Keychain password autofill does not exist for third-party browsers
  on macOS.** No public API. Nyx therefore ships its own vault (§5.8), the
  Orion model. 1Password's system-wide Universal Autofill (⌘\) works in any
  app from day one at no cost to us.
- **Passkeys require an Apple-approved entitlement**
  (`com.apple.developer.web-browser.public-key-credential`). We apply early —
  approval turns on WKWebView's built-in WebAuthn for all domains
  (`ASAuthorizationWebBrowserPublicKeyCredentialManager`, the same path
  Chrome/Firefox use). Until approval, passkey sites fail; this is expected.
- **macOS 26 minimum.** Gives us Tahoe's system-wide one-time-code autofill in
  our webviews for free, and the newest WebKit. `WKWebExtension` hosting
  (macOS 15.4+) stays available for a future 1Password extension integration.
- **UI architecture: AppKit-first shell, SwiftUI chrome.** Evidence is
  unambiguous: SwiftUI-hosted webviews jank during divider drags
  (documented Apple-forums reports; production fix in cmux PR #1170 was to
  switch to frame-based AppKit hosting). Beam, DuckDuckGo, and Ora all
  converged on this hybrid. SwiftUI `Material` cannot do behind-window blur;
  `NSVisualEffectView` can.

Reference codebases (patterns, not code): `duckduckgo/apple-browsers`
(Apache-2.0 — the Tab / TabViewModel / composable tab-extension architecture),
`the-ora/browser` (GPL-3.0 — read only; closest product analog),
`beamlegacy/beam` (frozen; the model-owned-webview hosting pattern).

## 3. Architecture — three layers

```
┌─────────────────────────────────────────────────────┐
│ Chrome (SwiftUI via NSHostingView)                  │
│   SidebarView · LauncherPanel (⌘K) · Settings ·     │
│   DownloadsPopover · fill/save popovers             │
├─────────────────────────────────────────────────────┤
│ Shell (AppKit)                                      │
│   NyxWindow(Controller) · PaneCanvas (NSSplitView)  │
│   WebViewHost (frame-based) · TabLifecycleManager   │
│   FocusController · UserAgentManager                │
├─────────────────────────────────────────────────────┤
│ NyxCore (Swift package, no UI imports)              │
│   SessionModel · HistoryStore · AdblockService ·    │
│   DownloadManager · PasswordVault · SettingsStore   │
│   Persistence: GRDB/SQLite (WAL, FTS5)              │
└─────────────────────────────────────────────────────┘
```

- **NyxCore** is a standalone Swift package with unit tests and no AppKit/
  SwiftUI imports. This is the part a future port would reuse conceptually.
- **Shell** owns windows, the pane canvas, and webview lifecycle. AppKit only.
- **Chrome** is all SwiftUI, embedded via `NSHostingView` (the WWDC22
  Shortcuts-app pattern). The sidebar lives inside an `NSVisualEffectView`
  (`.sidebar` material, `.behindWindow` blending) for true desktop blur.
- Project generation with **XcodeGen** (`project.yml`), matching the
  conventions of the author's other projects.

## 4. Data model

```
Space
 ├─ name, icon, order
 └─ items: [SessionItem]          // ordered

SessionItem = tab(Tab) | split(SplitGroup)

SplitGroup
 ├─ tabs: [Tab]                   // 2...4, flat columns only
 └─ weights: [Double]             // divider positions

Tab
 ├─ id, url, title, faviconRef
 ├─ interactionState: Data?      // WKWebView session blob
 ├─ snapshotRef: FileRef?        // hibernation placeholder image
 └─ lastActiveAt
```

Persisted in SQLite (GRDB):

- `spaces`, `session_items`, `tabs` — the live session, written continuously
  (debounced ~2 s after change; `interactionState` blobs on tab deactivation).
  Session restore after quit or crash is a *property of the storage design*,
  not a feature bolted on later. WAL mode makes it crash-safe.
- `history` + FTS5 index — powers ⌘K search. Recorded on committed
  navigations; no third-party embellishment, no cloud.
- `downloads` — state + `resumeData` for crash/quit recovery.
- Settings and per-site overrides (UA, adblock on/off, compat mode) in small
  tables; no UserDefaults sprawl.

## 5. Components

### 5.1 Pane canvas (the split feature)

- `NSSplitView`, vertical dividers, thin style, max 4 columns.
- Each pane hosts its tab's `WKWebView` with
  `translatesAutoresizingMaskIntoConstraints = true` and
  `autoresizingMask = [.width, .height]` — **no Auto Layout, no SwiftUI** in
  the drag path. This is the single most important performance decision in the
  app (see §2, UI architecture).
- WebKit inherently pauses page rendering during live resize (Safari does
  too). We mask it: pane background = the page's `themeColor` /
  `underPageBackgroundColor`, plus a snapshot overlay during divider drags.
- Layout state (weights) is committed to the model **once, on drag end** —
  never per frame through any observable store.
- Creating a split: drag a sidebar tab onto another tab, drag a tab into a
  pane edge drop zone, or ⌘-shortcut / ⌘K command ("split with…").
  Unsplitting: drag out, close pane, or command.
- One pane has focus at all times (visible focus ring on the pane border in a
  subtle accent). ⌥⌘← / ⌥⌘→ moves focus; address bar, ⌘W, ⌘R, and the
  launcher's context all apply to the focused pane.

### 5.2 Tab lifecycle (hibernation)

Tab states: **visible** (live webview, in window) → **warm** (live webview,
out of window — App Nap throttles it) → **hibernated** (no webview; snapshot +
`interactionState` on disk).

- Live webviews: the up-to-4 visible panes + an MRU cache of ~6 warm tabs.
- Hibernate: snapshot via `takeSnapshot` (with `snapshotWidth` bounded — taken
  on deactivation, not lazily), serialize `interactionState`, destroy webview.
- Activate: recreate webview from shared configuration, restore
  `interactionState`, swap the snapshot out when the first paint lands.
- Panes leaving the visible split get `setAllMediaPlaybackSuspended(true)`.
- Memory pressure (`DispatchSource.makeMemoryPressureSource`) shrinks the warm
  cache aggressively.

### 5.3 WebView management

- All webviews built from a shared `WKWebViewConfiguration` template with one
  `WKWebsiteDataStore`, but a **per-tab `WKUserContentController`** — required
  from day one so adblock can be toggled per tab/site (retrofitting is painful).
- `window.open` popups honor the configuration WebKit hands us in
  `createWebViewWith` (keeps opener relationships working) and open as new
  tabs.
- Crash resilience: `webViewWebContentProcessDidTerminate` → auto-reload
  (user-toggleable, Orion-style), plus a blank-view watchdog because WebKit
  does not fire the callback in every termination scenario.

### 5.4 Sidebar

- SwiftUI inside `NSVisualEffectView` (behind-window). Spaces at top, ordered
  tabs below; a `SplitGroup` renders as a nested group of its panes.
- Drag & drop: reorder, move between spaces, drop-on-tab to create a split.
- Collapsible (⇧⌘S) for a zero-chrome full-content mode; a slim overlay strip
  appears on hover at the left edge.

### 5.5 ⌘K launcher

- `NSPanel` + SwiftUI, Spotlight-like, dark, blurred.
- One input, ranked results across: open tabs (switch), history (FTS5 fuzzy),
  URL/search fallthrough, and commands (new tab, split with…, close others,
  toggle adblock here, downloads…).
- Also serves as the address bar's expanded mode; ⌘L focuses the compact
  in-pane address field, ⌘K opens the full launcher.

### 5.6 Adblock

- Pipeline: fetch EasyList/EasyPrivacy → convert with AdGuard's
  **SafariConverterLib** → compile via `WKContentRuleListStore` under
  versioned identifiers (`easylist-<version>`) → `lookUpContentRuleList` on
  launch, recompile off the main thread only when upstream lists change.
- 2–4 compiled lists (ads / privacy / user), each ≤150k rules post-conversion.
- Per-site and per-tab toggle = remove/add rule lists on that tab's content
  controller + reload (communicated in UI, since it needs a reload).
- "Enhanced blocking" setting (off by default in v1.0, on when stable):
  SafariConverterLib's advanced rules (extended-CSS + scriptlets) injected via
  `WKUserScript` in a dedicated `WKContentWorld`, per-site disable.
- First-run: pages load unblocked while the first compile runs (seconds);
  subtle status shown. Compile failure → load without blocking, retry in
  background, never block browsing.

### 5.7 Downloads

- `WKDownload`: policy decisions in `decidePolicyFor` (honoring
  `shouldPerformDownload`, `canShowMIMEType`, Content-Disposition); delegate
  assigned immediately in `didBecome` (forgetting this silently cancels).
- Unique destination filenames (WebKit never overwrites), `NSProgress` for UI,
  `resumeData` persisted on cancel/failure, fresh-restart fallback when
  `resumeData` is nil. In-flight downloads die with the app — state is rebuilt
  from the store on relaunch.
- UI: SwiftUI popover from the sidebar; no separate window.

### 5.8 Passwords (Nyx Vault)

- Storage: synchronizable items in Nyx's own Keychain access group → iCloud
  sync across the user's Macs for free. Never touches Safari's keychain.
- Fill: form detection + fill via injected JS in an isolated `WKContentWorld`;
  native SwiftUI popover anchored to the focused field for account selection.
- Save: submission heuristics trigger a native save/update prompt.
- Passkeys: entitlement application filed at milestone 1 (lead time!);
  integration via `ASAuthorizationWebBrowserPublicKeyCredentialManager`.
- Out of scope v1: importing from other browsers (v1.1), 1Password extension
  hosting via `WKWebExtension` (future; ⌘\ Universal Autofill already works).

### 5.9 Site compatibility

- `UserAgentManager`: Safari-identical default UA, per-site override table
  (seeded empty; Firefox-UA quirk for Google login only if ever needed),
  per-site "compat mode" (disables adblock + injections).
- Smoke-test checklist run on every macOS update: Netflix, Spotify web,
  Google sign-in, YouTube, Gmail, Docs. DRM regressions historically appear
  about once per macOS release cycle — this is a maintenance fact of life.

## 6. Error handling summary

| Failure | Response |
|---|---|
| WebContent process killed | Auto-reload (toggleable) + blank-view watchdog |
| Adblock compile fails | Browse unblocked, retry in background, log |
| Download fails | Persist `resumeData`, offer resume; fallback fresh start |
| App crash / force quit | SQLite WAL + continuous session writes → full restore |
| Snapshot fails at hibernation | Hibernate anyway; placeholder is a solid themeColor |
| Passkey entitlement not yet granted | Expected failure state with a clear in-app message |

## 7. Testing

- **NyxCore**: plain XCTest unit tests — session model operations (split
  create/dissolve/reorder), adblock conversion pipeline (fixture filter lists),
  launcher ranking, download state machine. Runs headless in CI.
- **Shell**: XCUITest smoke — launch, navigate, split, restore session.
- **Performance**: `os_signpost` instrumentation + budgets asserted in tests
  where possible: cold launch < 500 ms to first window paint; tab activation
  from hibernation < 250 ms to snapshot-swap; divider drag ≥ 60 fps on
  ProMotion hardware (target 120); memory: ≤ 6 live background webviews
  (the warm MRU cache of §5.2) beyond visible panes by default.
- **Site compat**: the manual checklist of §5.9 as a release gate.

## 8. Visual design language

Dark-first, quiet, glassy. Reference: the aesthetic of the user's shared
screenshots (Steel dashboard) — near-black surfaces, generous spacing, one
accent color, small type, real blur. Concrete rules:

- Materials: `NSVisualEffectView` sidebar; content area is edge-to-edge page.
- One accent color (default: a desaturated violet, "Nyx" night theme);
  focus rings, active tab, and launcher selection all use it.
- Traffic lights inset into the sidebar (`fullSizeContentView`, hidden title).
- Animations: short (≤ 200 ms), spring-free where possible, never decorative.
- App icon and final palette: **open item** — mood-board/mockup round before
  M8 polish (reference images from the user welcome).

## 9. Milestones

Each milestone ends with a usable browser.

- **M1 — Skeleton.** Window with vibrancy sidebar shell, one webview, address
  field, back/forward/reload, ⌘L/⌘T/⌘W. Passkey entitlement application filed.
- **M2 — Tabs, spaces, persistence.** Sidebar tabs + spaces, GRDB store,
  session restore, hibernation with snapshots.
- **M3 — Splits.** The core feature: drag-to-split, up to 4 columns, focus
  model, resize masking, split persistence.
- **M4 — ⌘K + history.** Launcher with tabs/history/commands, FTS5 history.
- **M5 — Adblock.** Full pipeline + per-site toggles.
- **M6 — Downloads.**
- **M7 — Vault.** Passwords + save prompts + (entitlement permitting) passkeys.
- **M8 — Polish.** Animation pass, icon, palette, performance budget
  enforcement, site-compat checklist, README.

## 10. Risks

1. **Autofill is the largest single work item** (form detection JS is fiddly,
   sites are hostile). Mitigation: Orion-proven architecture, ⌘\ exists
   meanwhile, milestone-late so the rest of the browser doesn't wait on it.
2. **Passkey entitlement approval timing** is Apple's call. Mitigation: apply
   at M1; ship v1 without it if needed (clear error state).
3. **DRM/UA regressions on macOS updates.** Mitigation: smoke checklist,
   per-site UA overrides, expectation that streaming is 1080p-class, not 4K.
4. **WebKit memory kills under pressure.** Mitigation: hibernation +
   watchdog + auto-reload; this is how every WKWebView browser lives.
5. **Greenfield split view.** No mature open-source prior art exists for flat
   multi-pane on WKWebView. Mitigation: it's an NSSplitView with frame-based
   hosting — the risky part (drag performance) is already de-risked by
   research; M3 validates it early.
