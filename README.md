# Nyx

A minimalist, high-performance native macOS browser. No telemetry, no AI
features, no visual noise. Flat split-view browsing — up to four pages
side by side — as a first-class citizen.

- **Engine:** system WebKit (WKWebView) — Safari-class speed and battery
- **Shell:** AppKit; **chrome:** SwiftUI; **look:** night glass (real
  behind-window vibrancy, grained metal accents)
- **Requires:** macOS 26 (Tahoe) or later

## Status

Milestone M1 (skeleton): window, vibrancy sidebar, one webview,
address field, navigation, shortcuts, UI smoke test.

## Build

```sh
brew install xcodegen
make run        # generate project, build, launch
make test-core  # NyxCore unit tests
make test-ui    # UI smoke test
```

Design spec: `docs/superpowers/specs/2026-09-11-nyx-browser-design.md`
