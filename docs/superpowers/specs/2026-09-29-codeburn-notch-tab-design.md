# CodeBurn Notch Tab — Design

Date: 2026-09-29
Status: approved in brainstorming, pending spec review

## Goal

Bring CodeBurn's core "where did my AI spend go" view into boring.notch as a
new tab in the open notch. Reference implementation: `example/codeburn/`
(Node CLI + native Swift menubar app).

## Scope

In scope (first cut):

- New **CodeBurn** tab in the open notch.
- Period switch: Today / 7d / 30d / Month.
- Hero column: total cost, calls, sessions, cache hit %, live session count.
- Top models column (top 4, name + cost).
- Top projects column (top 4, name + cost).
- Manual refresh button plus "updated Xm ago" label.
- Settings toggle `showCodeBurnTab`, **default ON**.

Out of scope (later cuts, not built now):

- Closed-notch spend glance / live-session indicator.
- Optimize findings, spend heatmap / history, budget alerts.
- Subscription quota rings, Capacity Dock, multi-device.
- Activities (task categories) breakdown.
- Background refresh while the notch is closed.

## Data source

CodeBurn's CLI (`codeburn`, v0.9.25 verified locally) prints the same payload
its menubar app consumes:

```
codeburn status --format menubar-json --period <today|week|30days|month> --no-optimize
```

Measured cost: `today` ~1.7s, `week` ~6.8s. Fetches must be async and cached.

### Sandbox constraint

The main app is sandboxed (`com.apple.security.app-sandbox = true`). A child
process inherits the sandbox and cannot read `~/.claude`, `~/.codex`, etc.
The existing `BoringNotchXPCHelper` XPC service is **not** sandboxed, so the
helper runs the CLI.

Rejected alternatives: dropping the main app's sandbox (weakens the whole
app); an external job writing a JSON file (still needs something to spawn the
CLI, plus user setup).

## Architecture

### XPC helper (privilege boundary)

Protocol method, added identically to both copies of
`BoringNotchXPCHelperProtocol.swift`
(`BoringNotchXPCHelper/` and `boringNotch/XPCHelperClient/`):

```swift
func fetchCodeBurnStatus(period: String, with reply: @escaping (Data?, String?) -> Void)
```

Helper implementation (`BoringNotchXPCHelper.swift`):

- Rejects any `period` not in the allowlist `today`, `week`, `30days`,
  `month`. The app never sends a path or arbitrary arguments.
- Resolves the binary from a fixed candidate list, first executable wins:
  `/opt/homebrew/bin/codeburn`, `/usr/local/bin/codeburn`,
  `~/.npm-global/bin/codeburn`, `~/.local/bin/codeburn`,
  `~/.volta/bin/codeburn`.
- Sets the child's `PATH` to the candidate directories plus
  `/opt/homebrew/opt/node/bin:/usr/bin:/bin`, so an npm-installed
  `#!/usr/bin/env node` shebang resolves from a GUI process.
- Reads stdout and stderr concurrently (large payload, ~130 KB, must not
  deadlock on a full pipe).
- Kills the child after a 60s timeout.
- Replies `(stdout, nil)` on exit 0; `(nil, "not-installed")` when no binary
  is found; `(nil, "<stderr snippet, max 300 chars>")` on non-zero exit or
  timeout.

### App client

`XPCHelperClient.swift` gains an async wrapper
`codeBurnStatus(period:) async -> Result<Data, CodeBurnFetchError>`, following
the existing wrapper pattern in that file. An XPC connection failure maps to
an error; the existing interruption handler reconnects on the next call.

### Model — `boringNotch/models/CodeBurnPayload.swift`

Minimal `Decodable` structs, only fields the tab renders:

- `generated: String`
- `currency: { symbol: String, rate: Double }?` (default `$`, `1`)
- `current: { cost, calls, sessions, cacheHitPercent, topModels[{name, cost}], topProjects[{name, cost}] }`
- `liveSessions: { sessions: [_] }?` — only the count is used.

Costs in the payload are USD; display value is `cost * rate`. Every field not
guaranteed by older CLIs uses `decodeIfPresent` with a default.

### Manager — `boringNotch/managers/CodeBurnManager.swift`

`@MainActor final class CodeBurnManager: ObservableObject`, singleton.

- `@Published period: CodeBurnPeriod` (`today | week | thirtyDays | month`,
  each with its CLI arg).
- Cache: `[CodeBurnPeriod: (payload, fetchedAt)]`.
- `@Published state: idle | loading | notInstalled | error(String)`.
- One in-flight task at a time; a new request for the same period while one
  is running is dropped.
- `refreshIfStale()` — called on tab appear and on period change; fetches
  when the cache for the current period is missing or older than 5 minutes.
- `refresh()` — manual ↻, always fetches.

### View — `boringNotch/components/CodeBurn/CodeBurnView.swift`

Fits the fixed 640×190 open notch (~150pt below the header):

```
[Today|7d|30d|Month]                     ↻ 2m ago
┌──────────────┬───────────────┬───────────────┐
│ $149.96      │ MODELS        │ PROJECTS      │
│ 1,445 calls  │ Opus 5.5  $77 │ ssh-mcp   $99 │
│ 45 sessions  │ Sonnet    $40 │ notch     $30 │
│ 99% cache    │ Haiku      $9 │ api       $12 │
│ ● 2 live     │ ...           │ ...           │
└──────────────┴───────────────┴───────────────┘
```

Matches existing notch styling (white/gray text on black, system fonts).

### Wiring

- `NotchViews` enum (`enums/generic.swift`): add `.codeburn`.
- `TabSelectionView.swift`: tab list becomes computed; CodeBurn entry
  (`flame.fill`) included only when `Defaults[.showCodeBurnTab]`; Shelf entry
  keeps its current behaviour.
- `ContentView.swift`: switch on `currentView` gains `.codeburn`.
- `BoringHeader.swift`: tabs visible when the existing shelf condition holds
  **or** `Defaults[.showCodeBurnTab]`.
- `Constants.swift`: `showCodeBurnTab = Key<Bool>("showCodeBurnTab", default: true)`.
- `SettingsView.swift`: one `Defaults.Toggle` for the tab.
- If the toggle is turned off while the CodeBurn tab is selected,
  `currentView` falls back to `.home`.

## Error states

| State | With cached payload | Without cache |
|---|---|---|
| loading | cached data, spinning ↻ | spinner |
| notInstalled | — | "CodeBurn CLI not found" + `brew install codeburn` / `npm i -g codeburn` |
| error(msg) | cached data + one red line with msg | msg only |
| decode failure | treated as error: "Unexpected CodeBurn output (CLI version?)" | same |

## Testing

No test target exists in the Xcode project; adding one is out of scope.

1. `scripts/codeburn-decode-check.swift` + `scripts/fixtures/codeburn-today.json`
   (trimmed real payload). Compiled together with `CodeBurnPayload.swift` via
   `swiftc` and run. Asserts: decode succeeds; cost × rate display math;
   top-N slicing; payload without `liveSessions` / `currency` still decodes.
2. `xcodebuild -scheme boringNotch build` succeeds.
3. Manual: run the app, open notch, switch to CodeBurn tab, check all four
   periods, screenshot as evidence. Verify the not-installed state by
   temporarily pointing resolution at a missing path.

## Success criteria

- Decode check script exits 0.
- App builds with no new warnings in touched files.
- CodeBurn tab shows the same Today cost as `codeburn status` in the terminal.
- Toggling the setting off hides the tab and returns to Home.
