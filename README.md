# usage-tracker

A macOS 14+ menu bar app that shows how much Command Code, Codex, and Claude usage you have left — without scraping pages, reading browser cookies, or inventing numbers.

The menu bar icon opens a popover with one card per provider. Each card shows the provider-reported quota windows when they are available, local token activity for the last day, week, or 30 days, reported or estimated cost, and any caveats about the data.

## What it reads

| Provider | Source | Quota | Local tokens | Cost |
| --- | --- | --- | --- | --- |
| Command Code | `~/.commandcode/projects/**/*.jsonl` | Not in local files | Yes | Reported (`costUsd`) |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | Latest local rate-limit snapshot | Yes | API-equivalent estimate |
| Claude chat | None | Unavailable | No | No |

- **Command Code** reads the assistant `message` entries that carry `usage`. Usage is per turn, and forked or cloned sessions copy entries, so events are deduplicated by `message.meta.messageId`.
- **Codex** reads `event_msg` / `token_count` records. Totals are cumulative per session file, so the app stores the last total per file and emits only deltas. Repeated totals are ignored, and a total that moves backwards is treated as a new accounting segment. Rate-limit windows come from the latest `rate_limits` snapshot written to a rollout.
- **Claude chat** has no verified public personal-usage interface, so the row stays explicitly unavailable and links to the account usage page. The app does not read cookies, scrape chats, or invent an OAuth flow.

Estimated costs use a dated table of verified standard API rates (see `Sources/UsageCore/Pricing/CostEstimator.swift`). Unknown models and long-context tiers stay unavailable rather than showing zero.

## Privacy

Everything stays on the machine. The app reads only the local session files listed above and writes a single cache at `~/Library/Application Support/UsageTracker/usage-cache-v1.json` with `0600` permissions. The cache is disposable: corrupt or outdated caches are deleted and rebuilt from the source files, and events older than 90 days are pruned.

## Requirements

- macOS 14 or later
- Swift 5.9+ (Xcode 15 or later)

`UsageCore` has no Apple-only dependencies, so `swift build` and `swift test` also work on Linux; the app target compiles to a placeholder there.

## Build and run

```sh
swift run UsageTrackerApp
```

The app runs as a menu bar item with no Dock icon. Build a distributable bundle from Xcode or with your preferred packaging step; there is no bundle metadata in the repository.

## Settings

- **Local data sources** — point either provider at a custom sessions folder, or leave the field empty for the default. A missing folder is reported in the popover instead of failing silently.
- **Refresh interval** — how often local session files are scanned (default 20s). Remote quota snapshots refresh at their own cadence, and failures back off exponentially up to 5 minutes.
- **Cache** — reveal or clear the cache. Clearing triggers a full refresh.

## Project layout

```
Sources/UsageCore
  Models/        Provider ids, metrics, snapshots, and usage events
  Providers/     Command Code, Codex, and Claude chat providers
  Storage/       Incremental JSONL reader and the on-disk cache
  Aggregation/   Period summaries and per-model breakdowns
  Pricing/       Verified API-equivalent rate table
  RefreshCoordinator.swift  Scheduling, debouncing, timeouts, backoff
  UsageStore.swift          Observable state for the UI

Sources/UsageTrackerApp
  UsageTrackerApp.swift     MenuBarExtra app and Settings scene
  AppModel.swift            Wires providers to the store, handles wake/activation
  AppSettings.swift         UserDefaults-backed preferences
  Views/                    Popover cards, quota bars, and settings

Tests/UsageCoreTests
  Coverage for aggregation, pricing, JSONL reading, the cache, the refresh
  coordinator, and both local providers.
```

## Tests

```sh
swift test
```

The suite covers period filtering, reported vs. estimated cost handling, incremental JSONL reads and checkpoint resumes, cache deduplication and stale-on-error behaviour, refresh debouncing/timeouts/backoff, and parsing fixtures for both Command Code sessions and Codex rollouts.
