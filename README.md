# Nyx

A minimalist, high-performance native macOS browser. No telemetry, no AI
features, no visual noise. Flat split-view browsing — up to four pages
side by side — as a first-class citizen.

- **Engine:** system WebKit (WKWebView) — Safari-class speed and battery
- **Shell:** AppKit; **chrome:** SwiftUI; **look:** night glass (real
  behind-window vibrancy, grained metal accents)
- **Requires:** macOS 26 (Tahoe) or later

## Status

Milestone M2 (tabs & persistence): sidebar tabs and spaces, GRDB session
store with full restore after quit/crash, tab hibernation (MRU warm
cache), popup adoption (`target="_blank"` opens a real tab), tab-aware
menus. M1 delivered the skeleton: window, vibrancy sidebar, WKWebView,
address field, shortcuts, offline UI smoke test.

Next: M3 — split view (the core feature).

## Build

```sh
brew install xcodegen
make run        # generate project, build, launch
make test-core  # NyxCore unit tests
make test-ui    # UI smoke test
```

Design spec: `docs/superpowers/specs/2026-09-11-nyx-browser-design.md`
