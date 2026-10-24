# Usage Tracker

Native macOS menu bar app for AI coding limits, written in Swift and SwiftUI.

## Build and test
- `swift build`
- `swift test`
- `swift run UsageTracker --probe` prints live readings as JSON.
- `swift run UsageTracker --refresh-once` refreshes the cache and prints a summary.
- `swift run UsageTracker --render-preview /tmp/panel.png` renders the panel offscreen.
- `scripts/build-app.sh` produces `dist/UsageTracker.app`; `--universal` adds Intel x86_64.

## Layout
- `Sources/UsageCore` — model, CLI runner, parsers, providers, store.
- `Sources/UsageTracker` — menu bar UI, Settings window, and app lifecycle.
- `Tests/UsageCoreTests` — parser, runner, formatting and window tests.
- `Sources/UsageCore/Resources/cli.sb` — sandbox profile used for Codex, Gemini and Grok.
- `scripts/make-icon.swift` — draws the app icon during `build-app.sh`.

## Rules
- Never read, store or send credentials. The app asks installed CLIs and reads their documented local usage files only.
- Never show invented usage numbers. Unavailable values stay unavailable, estimates are labeled.
- Any new provider needs a sanitized fixture and a parser test before it ships.
