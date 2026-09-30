# CodeBurn Notch Tab — Design

Date: 2026-09-29
Status: revised after multi-agent review (security, architecture, integration,
data contract); pending user spec review

## Goal

Bring CodeBurn's core "where did my AI spend go" view into boring.notch as a
new tab in the open notch. Reference implementation: `example/codeburn/`
(Node CLI + native Swift menubar app).

## Scope

In scope (first cut):

- New **CodeBurn** tab in the open notch.
- Period switch: Today / 7d / 30d / Month.
- Hero column: total cost, calls, sessions, cache hit %, active session count.
- Top models column (top 4 priced, name + cost).
- Top projects column (top 4, name + cost).
- Manual refresh button plus "updated Xm ago" label.
- Settings toggle `showCodeBurnTab`, **default OFF** (opt-in; see Security).

Out of scope (later cuts, not built now):

- Closed-notch spend glance / live-session indicator.
- Optimize findings, spend heatmap / history, budget alerts.
- Subscription quota rings, Capacity Dock, multi-device.
- Activities (task categories) breakdown.
- Background refresh while the notch is closed.
- Discovering `codeburn` installed via nvm, bun or pnpm (not on the fixed
  candidate list; see Binary resolution).

## Data source

CodeBurn's CLI (`codeburn`, v0.9.25 verified locally) prints the same payload
its menubar app consumes. The command line is fixed:

```
codeburn status --format menubar-json --period <today|week|30days|month> --no-optimize
```

`--no-optimize` is the flag the CodeBurn menubar app itself passes
(`mac/.../DataClient.swift:134`). It skips the optimize pass and lets the CLI
serve a saved snapshot when no transcript changed, which makes repeat calls
fast. Measured on codeburn 0.9.25:

| Command | Cold | Warm |
|---|---|---|
| `today --no-optimize` | 1.65s | 0.83s |
| `month --no-optimize` | 3.27s | 0.89s |
| `month` (no flag) | ~7s | — |

Consequence of the snapshot path: `generated` and `liveSessions` can be older
than the fetch time. The UI therefore labels freshness from `generated`, not
from when the app fetched.

A per-call spawn is chosen over the resident `codeburn serve --stdio` used by
the CodeBurn app: serve holds ~1GB resident and needs ~870 lines of lifecycle
code (`ServeConnection.swift`) that warm one-shot calls do not justify.

### Sandbox constraint

The main app is sandboxed (`com.apple.security.app-sandbox = true`). A child
process inherits the sandbox and cannot read `~/.claude`, `~/.codex`, etc.
The existing `BoringNotchXPCHelper` XPC service is **not** sandboxed, so the
helper runs the CLI.

Rejected alternatives: dropping the main app's sandbox (weakens the whole
app); an external job writing a JSON file (still needs something to spawn the
CLI, plus user setup).

## Security

- **Who can call the helper.** It is an embedded XPC service
  (`NSXPCListener.service()`), reachable only by the host app. The new method
  is the first one that spawns a process; a compromised app gains only "run
  codeburn with one of four fixed periods".
- **Privacy attribution (TCC).** A process spawned by the helper is
  attributed to Boring Notch and inherits its privacy grants (camera,
  calendars, Apple Events, Accessibility). Every candidate binary location is
  user-writable, so same-user malware could plant a `codeburn` or `node` and
  borrow those grants. This is why the tab is **opt-in (default OFF)**, and why
  the settings text says the tab runs the locally installed `codeburn` CLI.
- **Possible privacy prompt.** Some CodeBurn providers (e.g. Warp) read other
  apps' group containers, which can trigger "Boring Notch would like to access
  data from other apps". The settings text mentions this.
- **Side effects of the CLI.** It writes `~/.cache/codeburn` and refreshes
  LiteLLM pricing from GitHub at most once per 24h (bounded timeout), plus a
  currency API call for non-USD display. Accepted: the same CLI does this from
  the terminal, and suppressing it with `CODEBURN_PRICING_SNAPSHOT_ONLY` was
  rejected because that is a test-only hatch (`src/models.ts:406-413`) that
  ignores the on-disk live pricing cache, so notch totals would drift from the
  terminal. The CLI sends no telemetry itself (only the CodeBurn desktop app
  does).
- **No sensitive text on screen.** Raw stderr (may contain `/Users/<name>/…`)
  goes to `os_log` only; the UI shows short generic messages.

## Architecture

### XPC helper

Protocol method, added identically to both copies of
`BoringNotchXPCHelperProtocol.swift`
(`BoringNotchXPCHelper/` and `boringNotch/XPCHelperClient/`):

```swift
func fetchCodeBurnStatus(period: String, with reply: @escaping (Data?, String?) -> Void)
```

Helper implementation (`BoringNotchXPCHelper.swift`, synchronized folder, no
pbxproj change):

- **Allowlist:** rejects any `period` not in `today`, `week`, `30days`,
  `month`. The app never sends a path or arbitrary arguments.
- **Never blocks the XPC thread.** NSXPCConnection delivers one connection's
  messages serially, and brightness / accessibility calls share this
  connection. The method starts the `Process`, collects stdout/stderr via
  `readabilityHandler`, and replies from `terminationHandler`. It returns
  immediately.
- **Exactly one reply per call**, guarded by a lock-protected flag shared by
  the termination path and the timeout path.
- **Timeout 60s:** SIGTERM, then SIGKILL after 2s. The child runs in its own
  process group so the whole group is killed (the CLI spawns children, e.g.
  `sqlite.ts`).
- **One CLI at a time:** a call arriving while one is running replies
  `(nil, "busy")`; the app retries on its next refresh trigger.
- **Output cap:** stdout over 5 MB kills the child and replies an error.
- **Binary resolution:** fixed candidates, first executable wins, `~` built
  from `FileManager.default.homeDirectoryForCurrentUser`:
  `/opt/homebrew/bin/codeburn`, `/usr/local/bin/codeburn`,
  `~/.npm-global/bin/codeburn`, `~/.local/bin/codeburn`,
  `~/.volta/bin/codeburn`. None found → `(nil, "not-installed")`.
- **Explicit environment allowlist** (not inherited wholesale):
  `HOME`, `USER`, `TMPDIR`, `LANG` copied from the helper's environment;
  `PATH=/opt/homebrew/opt/node/bin:/opt/homebrew/bin:/usr/local/bin:<user candidate dirs>:/usr/bin:/bin`
  (node directory first); `NODE_ENV=production`. Everything else is dropped, including
  `NODE_OPTIONS`, `NODE_PATH`, `DYLD_*`. Known limitation: config that exists
  only in the user's shell (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) is not seen, so
  totals can differ from the terminal for users who rely on those.
- **Replies:** `(stdout, nil)` on exit 0; `(nil, "not-installed" | "busy" |
  "timeout" | "failed")` otherwise, with full stderr logged via `os_log`.

### App client

`XPCHelperClient.swift` gains an async wrapper
`codeBurnStatus(period:) async -> Result<Data, CodeBurnFetchError>`, following
the existing `withContinuation` pattern in that file. An XPC connection
failure maps to an error; the existing interruption handler reconnects on the
next call.

### Model — `boringNotch/models/CodeBurnPayload.swift`

Minimal `Decodable` structs, only fields the tab renders. Standalone (no app
imports) so the decode check script can compile it.

- `generated: String` — ISO 8601 with fractional seconds.
- `stale: Bool?` — true when the CLI served older data under lock contention.
- `currency: { symbol: String, rate: Double, code: String }` — always present
  in 0.9.25; decoded with defaults (`$`, `1`, `USD`) for safety.
- `current`:
  - `label: String` (e.g. "Today (2026-09-29)", "7 Days") — shown as the
    period caption, because `week` spans 8 calendar days.
  - `cost`, `calls`, `sessions`, `cacheHitPercent` (0–100 scale).
  - `sessionCountBasis: String?` — when present and not `identity`, the
    session count is a lower bound and is shown as `≥45`.
  - `topModels: [{name, cost}]` — sorted by cost desc upstream, uncapped.
  - `unpricedModels: [_]?` — only the count is used.
  - `topProjects: [{id?, name, cost}]` — capped at 5 and sorted by
    `cost + savings` upstream; `name` is the folder basename and can collide.
- `liveSessions: { sessions: [_] }?` — absent means "unknown", not zero.

Costs are USD; display value is `cost * rate`. Zero decimals for `JPY` and
`KRW`, two otherwise.

### Manager — `boringNotch/managers/CodeBurnManager.swift`

`@MainActor final class CodeBurnManager: ObservableObject`, singleton.

- `@Published period: CodeBurnPeriod` (`today | week | thirtyDays | month`,
  each with its CLI arg).
- Per-period entry: `[CodeBurnPeriod: Entry]` where
  `Entry = { payload?, fetchedAt?, status: idle | loading | notInstalled | error(String) }`.
  State is per period, so a fetch for one period never changes another's UI.
- A fetch captures its period at start and writes its result to that period's
  entry only. On completion, if the visible period differs and is stale,
  `refreshIfStale()` runs for it.
- One in-flight fetch at a time; the in-flight flag is released with `defer`
  on every path, including XPC errors.
- `refreshIfStale()` — called on tab appear and on period change; fetches when
  the entry has no payload or `fetchedAt` is older than 5 minutes.
- `refresh()` — manual ↻, always fetches (subject to the in-flight rule).

### View — `boringNotch/components/CodeBurn/CodeBurnView.swift`

Height budget ≈ 130pt (190 − 12 bottom padding − header ~32–38 − spacing).
Each column ≈ 185pt wide.

```
[Today|7d|30d|Month]  Today (2026-09-29)      ↻ 2m ago
┌──────────────┬───────────────┬───────────────┐
│ $149.96      │ MODELS        │ PROJECTS      │
│ 1,445 calls  │ Opus 5.5  $77 │ ssh-mcp   $99 │
│ ≥45 sessions │ Sonnet    $40 │ notch     $30 │
│ 99% cache    │ Haiku      $9 │ api       $12 │
│ ● 2 active   │ +1 unpriced   │               │
└──────────────┴───────────────┴───────────────┘
```

- Fonts: hero `.title3` semibold, rows `.caption`; every row
  `lineLimit(1)` with tail truncation.
- Model and project names use `Text(verbatim:)` so they don't enter the string
  catalog.
- Models column hides `cost == 0` rows; shows "+N unpriced" when
  `unpricedModels` is non-empty.
- Projects rows are identified by `id ?? name`.
- Active row shows `● N active ≤10m` only when `liveSessions` is present;
  hidden otherwise.
- "↻ Xm ago" is computed from `generated`.
- `stale == true` dims the numbers (reduced opacity).
- Matches existing notch styling (white/gray text on black, system fonts).

### Wiring

- `NotchViews` enum (`enums/generic.swift`): add `.codeburn`.
- `Constants.swift`:
  `showCodeBurnTab = Key<Bool>("showCodeBurnTab", default: false)`.
- `TabSelectionView.swift`: `tabs` becomes computed, one gate per tab:
  - Home: always.
  - Shelf: when `boringShelf && (!shelfIsEmpty || alwaysShowTabs)` — the same
    condition that today gates the whole bar, now scoped to Shelf only.
  - CodeBurn (`flame.fill`): when `showCodeBurnTab`.
  - Settings read through `@Default(...)` so the bar re-renders on change.
- `BoringHeader.swift`: shows the tab bar when the computed `tabs.count > 1`.
  Existing behaviour is preserved exactly when `showCodeBurnTab` is off.
- `ContentView.swift`: switch on `currentView` gains `.codeburn`.
- `SettingsView.swift`: `Defaults.Toggle` next to "Always show tabs", with
  caption: "Runs your locally installed codeburn CLI to show AI coding
  spend. macOS may ask Boring Notch for access to other apps' data."
- Toggle turned off while CodeBurn is selected: an `onChange` in the
  coordinator (same pattern as `alwaysShowTabs.didSet`) resets
  `currentView` to `.home`. Closing the notch already returns to Home unless
  "open last tab" is on (`BoringViewModel.swift:214-218`).
- **Xcode project:** the main app target uses classic groups, not
  synchronized folders. `CodeBurnPayload.swift`, `CodeBurnManager.swift` and
  `CodeBurnView.swift` need PBXFileReference, PBXBuildFile and Sources
  entries in `project.pbxproj`, plus a new `CodeBurn` group under
  `components`.
- **Localization:** new `Text("…")` literals are extracted into
  `Localizable.xcstrings` on build; that diff is expected.

## States

| Condition | With cached payload | Without cache |
|---|---|---|
| loading | cached data, spinning ↻ | spinner |
| `calls == 0` | "No usage in this period" | same |
| notInstalled | — | "CodeBurn CLI not found" + `brew install codeburn` / `npm i -g codeburn` |
| busy / timeout / failed | cached data + one red line: "Couldn't refresh CodeBurn" | "Couldn't load CodeBurn data" |
| decode failure | "Unexpected CodeBurn output (CLI version?)" | same |
| `stale == true` | data dimmed | — |

## Testing

No test target exists in the Xcode project; adding one is out of scope.

1. `scripts/codeburn-decode-check.swift` + `scripts/fixtures/codeburn-today.json`
   (trimmed real payload; project paths anonymised). Compiled with
   `CodeBurnPayload.swift` via `swiftc` and run. Asserts:
   - decode succeeds on the fixture;
   - cost × rate display math, including zero-decimal JPY;
   - `$0` models are filtered and unpriced count is reported;
   - `≥` prefix when `sessionCountBasis` is `partial`;
   - a payload without `liveSessions`, `stale`, `sessionCountBasis` or
     `unpricedModels` still decodes;
   - the empty-user payload (`calls: 0`, empty arrays) decodes.
2. `xcodebuild -scheme boringNotch build` succeeds.
3. Manual, with screenshots as evidence:
   - enable the toggle; open notch; CodeBurn tab shows the same Today cost as
     `codeburn status --period today` in the terminal;
   - all four periods load; switching periods mid-fetch never shows another
     period's numbers;
   - brightness keys stay responsive during a cold `month` fetch;
   - toggle off: tab disappears, view returns to Home, Shelf/tabs behave as
     before;
   - not-installed state, by temporarily breaking resolution in a debug build.

## Success criteria

- Decode check script exits 0.
- App builds with no new warnings in touched files.
- CodeBurn tab matches terminal Today cost.
- With the toggle off, header/tab behaviour is identical to `main`.
- Brightness keys are not delayed by CodeBurn fetches.
