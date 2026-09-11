# M2 morning checklist (gate before merging `m2-tabs-spaces`)

The console locked at ~03:35, so UI tests could not run from Task 9 onward.
Everything else is green (build clean, 22/22 core tests, all task reviews +
final branch review + fix wave complete). **Do these in order:**

## 1. Run the gate

```sh
cd ~/Documents/Projecten/Nyx-Browser
git checkout m2-tabs-spaces
make test-ui        # expect 4 tests green; retry once on the known flake
```

If a test fails, check `docs/…` nothing — check this ranked list first:

1. **`nyx.tabRow` rows not found / count mismatch** → apply the documented
   fallback query in `NyxUITests.swift`: change `tabRows(in:)` to
   `app.outlines.descendants(matching: .any).matching(identifier: "nyx.tabRow")`.
   (SwiftUI List rows sometimes expose identifiers one level deeper.)
2. **Restore test fails only after relaunch** → debounce timing; the constant
   is 2 s (`SessionPersistence.swift:29`), test waits 2.5 s — suspect
   terminate racing the flush on a busy machine.
3. **Row count never increases** → ⌘T menu wiring (verified present in
   `MainMenuBuilder.swift:40-41`, so unlikely).
4. **Known environmental flake**: fails at ~13.3 s timeout, passes on retry
   in ~4 s. Retry once before treating anything as real.

## 2. Manual spot-checks (`make run`) — zero automated coverage exists for these

- Click a `target="_blank"` link → must open as a **new tab** (popup adoption;
  also verifies swipe-back/pinch-zoom work in that tab — final-review fix).
- ⌘L with the sidebar **collapsed** (⇧⌘S first) → sidebar reveals, address
  field focuses.
- Open 8+ tabs, switch through them, return to an early one → page restores
  with scroll position and history (hibernation round-trip).
- Space switcher menu + drag-reorder of tab rows.
- Vibrancy/blur look (also still owed from M1).

## 3. Merge (once green)

Say "merge M2" in the Claude session (or do it yourself):

```sh
git checkout main && git merge --no-ff m2-tabs-spaces && make test-core && make test-ui && git push
```

## Still open for Lars (unchanged)

- Passkey entitlement request: `docs/entitlement-request.md`
- Saans app license (SF Pro until then); app icon (mockup round before M8)
