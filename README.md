# Usage Tracker

A native macOS menu bar app showing how much of each AI coding service's 5-hour and weekly limits you've used, and when they reset. Swift and SwiftUI, no Electron, no background browser.

## What it reads

| Service | Source | Notes |
|---|---|---|
| Claude Code | `claude -p /usage` or the optional status line | Pro/Max plan windows. API-key accounts have no plan windows. |
| Codex CLI | `~/.codex/sessions/**/*.jsonl` | Real `rate_limits`: 5-hour and weekly percent, reset time, plan. Falls back to `codex app-server` (best effort). |
| Gemini (Antigravity) | `agy -p /quota --output-format json` | Per-model-group buckets. Ineligible accounts are reported, not guessed. |
| Grok Build | `grok agent stdio` → `_x.ai/billing` | Weekly credits. Signed-out state points at `grok login`. |
| Command Code | `cmd status --json` + local session logs | **Estimate.** Plan windows are not exposed headlessly; spend is computed from this Mac's session logs. Pick your plan for a percentage. |

The app only asks CLIs that are installed. Missing CLIs stay out of the menu bar and are listed in the panel.

## Build and run

```bash
swift build
swift test
scripts/build-app.sh              # this Mac's architecture
scripts/build-app.sh --universal  # Apple Silicon + Intel
open dist/UsageTracker.app
```

`scripts/build-app.sh` builds a release binary, assembles `dist/UsageTracker.app` with `LSUIElement`, generates the icon, copies the sandbox profile resource bundle, and ad-hoc signs it.

The build is ad-hoc signed, not Developer ID signed or notarized. A copy on another Mac may need right-click Open or `xattr -d com.apple.quarantine`. Smooth double-click distribution requires the paid Apple Developer Program.

## Optional: live Claude limits

Claude Code's headless `/usage` output does not always include plan windows. For live numbers, let Claude Code hand its status-line JSON to this app:

```json
"statusLine": {
  "type": "command",
  "command": "/Applications/UsageTracker.app/Contents/MacOS/UsageTracker --statusline",
  "refreshInterval": 60
}
```

Put that in `~/.claude/settings.json`. It **replaces** any status line you already have, and the app never edits your settings. The helper reads only `rate_limits.five_hour` and `rate_limits.seven_day`, writes percentages and reset times to `~/Library/Caches/usage-tracker/claude-status.json`, and prints a short line for Claude Code.

## Settings

Open the gear in the panel footer, or press Cmd+,. The Settings window has:

- **General** — show service marks, which installed services appear in the menu bar, refresh interval, launch at login, and the Command Code plan used for estimates.
- **Claude Code** — a copyable status-line snippet for live Claude limits.
- **Data** — refresh now, clear cached readings, and the cache location.

## Command line

```bash
UsageTracker --probe                 # every provider's current reading as JSON
UsageTracker --refresh-once          # refresh the cache and print a summary
UsageTracker --statusline            # Claude Code status-line helper (reads stdin)
UsageTracker --render-preview FILE   # offscreen PNG of the panel, for design checks
UsageTracker --render-tray FILE      # offscreen PNG of the menu bar label
```

## Command Code estimate

`/usage` is an interactive slash command; passing it to `cmd -p` sends it to the model as a prompt and spends tokens, so this app never does that. Instead it:

1. asks `cmd status --json` whether you are signed in, and
2. scans `~/.commandcode/projects/**/*.jsonl` for numeric `usage.costUsd` and token counts. Only usage lines are parsed; nothing outside those numbers is stored or displayed.

Spend is grouped into rolling windows that open on the first request and reset 5 hours or 7 days later. With no plan selected, the panel shows dollars only. With a plan selected, it shows a percentage against the documented caps (Go $2/$5, GOAT $14/$35, Pro $16/$40, Max 10× $45/$90, Max 20× $90/$180, Team Pro $12/$24). These are estimates from this Mac, not account-wide billing numbers.

## Privacy and security

- **Never reads credentials.** No token, cookie, keychain item or auth file is opened by the app.
- **No network requests of its own.** Each CLI talks to its vendor; the app does not.
- **Fixed search paths.** The app never trusts its inherited `PATH`. A CLI runs only if its path, real target and ancestors are owned by you or root, not writable by group or others, and carry no write ACL.
- **Minimal environment.** Each CLI gets only `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `NO_COLOR` and a checked `PATH`; your API keys and SSH agent socket are not passed.
- **Private working directory.** CLIs run in an empty folder, never inside a project.
- **Kernel sandbox.** Codex, Antigravity and Grok run under `sandbox-exec` with `Sources/UsageCore/Resources/cli.sb`. If the sandbox is unavailable, they are not run.
- **Hard deadlines.** One CLI at a time, 20–45 seconds, own process group killed afterwards.
- **What is stored.** `~/Library/Caches/usage-tracker/state.json` (percentages, reset times, plan names, estimates) and `claude-status.json`. Directory `0700`, files `0600`. No analytics.

## Design

The panel follows the single-column layout from the reference screenshot: one section per service, a mark, product and plan, a relative update time, full-width limit bars with the percentage, reset time, and a footer with Refresh, Launch at Login and Quit. Weekly windows are marked with a superscript `w` in the menu bar; 90% or more turns red and adds `!`; a stale reading is dimmed; a passed reset shows `—` instead of an old number.

## Tests

```bash
swift test
```

Covers formatting and 99.6→99 rounding, stale/passed-reset behavior, Claude status-file and prose parsing, Codex log and app-server shapes, Gemini group/bucket parsing and eligibility errors, Grok billing, Command Code rolling-window math and plan caps, runner timeouts, environment scrubbing and executable trust checks.
