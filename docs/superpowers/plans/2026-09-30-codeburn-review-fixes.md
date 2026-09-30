# CodeBurn Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 15 findings from the `/code-review` of branch `feat/codeburn-notch-tab` (PR #1 on the fork).

**Architecture:** The code and design are unchanged except for three deliberate changes to the reviewer's suggestions, recorded below. Task 1 rewrites the XPC-helper runner's completion logic around one serial queue. Task 2 hardens the payload and manager. Task 3 fixes view, tab and setting behaviour.

**Tech Stack:** Swift 5 / SwiftUI / Foundation / Dispatch, macOS 14+. Standalone `swiftc` checks run through `scripts/codeburn-check.sh`; there is no XCTest target.

**Spec:** `docs/superpowers/specs/2026-09-29-codeburn-notch-tab-design.md`. That spec still binds. This plan changes only what the findings below require.

## Global Constraints

- `CodeBurnRunner.swift` imports only Foundation, Dispatch, os and Darwin. `CodeBurnPayload.swift` and `CodeBurnManager.swift` must not import SwiftUI or AppKit. `scripts/codeburn-check.sh` compiles these files standalone.
- The runner replies exactly once per `run(...)`. It calls `release()` before `reply(...)`. The only reply codes are `not-installed | busy | timeout | failed`, or data on success.
- The period allowlist (`today, week, 30days, month`) and the environment allowlist (HOME, USER, TMPDIR, LANG, PATH, NODE_ENV=production) do not change. No shell is ever used to discover paths (no `$SHELL -lc`).
- With `showCodeBurnTab` off, the header and tab bar behave exactly as on `main`. The 8 combinations of shelf enabled × shelf empty × alwaysShowTabs must give the same results as before.
- Dragging a file onto a closed notch still opens the Shelf view (`ContentView.swift` sets `currentView = .shelf` on drop targeting), even when the shelf is empty.
- Don't hand-edit `Localizable.xcstrings`.
- Commits: conventional `fix(codeburn): …`. Stage only the files you touched. Never stage `example/`, `.memsearch/` or `.superpowers/`. Do not push.
- Verify every task with `scripts/codeburn-check.sh; echo "exit=$?"`, which must print `PayloadCheck OK`, `RunnerCheck OK`, `ManagerCheck OK`, exit 0. Tasks 2 and 3 also need the unsigned build `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd" CODE_SIGNING_ALLOWED=NO build` to end in `** BUILD SUCCEEDED **` with no new warnings in the touched files. After any RunnerCheck run, `ps -axo pgid=,command= | grep -E 'codeburn-runner-check|POSIX::setsid' | grep -v grep` must print nothing.

## Changes to the reviewer's suggestions

- **Finding 4/13:** the reviewer suggested a generic "current view not visible → Home" rule. That would bounce a file drag on an empty shelf back to Home and break drop-to-shelf. Instead, the Shelf tab stays in `visible(...)` while it is the current view, but only when CodeBurn is on. The CodeBurn-off truth table is unchanged. The CodeBurn reset moves from Settings into the coordinator.
- **Finding 12:** the cancellable-timer half is taken. The blocking `waitpid` thread is kept, because only one run happens at a time. A process dispatch source has an unverified edge when the child has already exited before the source is resumed.
- **Finding 9:** version-manager install directories are discovered by directory listing. The chosen binary's own directory leads the child PATH, so `#!/usr/bin/env node` resolves the node that shipped with it.

---

### Task 1: Runner — exit-driven completion, signal reset, discovery, private logging

Findings 1, 2, 7, 8, 9, 12.

**Files:**
- Modify: `BoringNotchXPCHelper/CodeBurnRunner.swift`
- Test: `scripts/codeburn-checks/RunnerCheck.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `CodeBurnRunner.init(candidates:timeout:)` is unchanged.
  - `run(period:reply:)` is unchanged.
  - `static func defaultCandidates(home: URL) -> [URL]` returns more entries (see below).
  - `static func childEnvironment(parent: [String: String], home: URL, binary: URL, candidates: [URL]) -> [String: String]` gains a `binary` parameter; `run` passes the chosen binary.
  - `BoringNotchXPCHelper.swift` calls only `run`, so it needs no change.

**Required behaviour:**

1. **Exit is authoritative (finding 1).** A run completes when the child is reaped, not when the pipes reach EOF.
   - After `waitpid` returns, drain both read fds non-blocking until `EAGAIN` or EOF. Everything the child wrote is already in the pipe buffer.
   - Then finish: overflow gives `failed`, a timeout gives `timeout`, a clean exit (status 0) gives the stdout data, and anything else gives `failed`.
   - Do not kill the process group on a clean exit. A descendant left holding the pipe no longer delays or changes the reply.
   - This inverts the current `setsid` escape case in RunnerCheck: the fake exits 0 at once, so the reply must now be success (empty stdout data, code nil) within about 1s, not `timeout`. Update that assertion. Keep killing the escaped perl process by its pid file afterwards.
2. **One serial queue per run (findings 7, 12).**
   - All job state (stdout/stderr buffers, flags, `finished`) lives on one private serial `DispatchQueue`, which removes the `Job` lock.
   - Use raw `pipe()` fds, not `Pipe`/`FileHandle`, and set the read ends to `O_NONBLOCK`.
   - Read with `DispatchSource.makeReadSource(fileDescriptor:queue:)` on that queue. Each source's cancel handler closes its fd. Because cancel and event handlers share the serial queue, a close can never race a read.
   - `finish()` runs on the queue. It is guarded by `finished`, cancels both read sources and all timers, then calls `release()`, then `reply`.
   - Timers are `DispatchWorkItem`s scheduled on the queue and cancelled in `finish()`, so nothing (buffers, fds) outlives a completed run.
   - Keep one global-queue thread doing the blocking `waitpid` with the EINTR retry and the `status = 1 << 8` fallback. It hops to the serial queue with the status.
3. **Timeout (unchanged semantics).** At `timeout`: if not finished, mark it timed out and send `kill(-pid, SIGTERM)`. Two seconds later, send `kill(-pid, SIGKILL)` if not finished. The reply is `timeout` once the child is reaped. Remove the escape grace path, which is no longer needed.
4. **Overflow.** stdout beyond `maxOutputBytes` sets overflowed and sends `kill(-pid, SIGKILL)`. The reply is `failed` on reap. stderr stays capped at 64 KB.
5. **Signal reset (finding 2).** In `spawn`:
   - add `POSIX_SPAWN_SETSIGMASK` with an empty mask (`sigemptyset`, `posix_spawnattr_setsigmask`);
   - add `POSIX_SPAWN_SETSIGDEF` with a full set (`sigfillset`, `posix_spawnattr_setsigdefault`);
   - keep `POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT` and `setpgroup(0)`.
6. **Discovery (finding 9).** `defaultCandidates(home:)` returns, in this order:
   1. the fixed paths as today: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.local/bin`, `~/.volta/bin`;
   2. `~/.bun/bin/codeburn`;
   3. `~/Library/pnpm/codeburn`;
   4. `<version>/bin/codeburn` for each version directory under `~/.nvm/versions/node/`, `~/.asdf/installs/nodejs/`, `~/.local/share/mise/installs/node/` and `~/Library/Application Support/fnm/node-versions/*/installation`, newest first by `localizedStandardCompare` descending. Only directories that exist are listed: use `FileManager.contentsOfDirectory`; a missing directory contributes nothing.

   `run` still picks the first executable candidate.
7. **Child PATH (finding 9).** `childEnvironment(parent:home:binary:candidates:)` builds PATH from:
   1. the chosen binary's directory;
   2. `/opt/homebrew/opt/node/bin`;
   3. the fixed candidate directories;
   4. `/usr/bin`, `/bin`.

   Deduplicate. Do not add every version directory. Rewrite the doc comment: trusting the binary's own directory for `node` is the same trust as executing the binary; nothing from the parent PATH is used.
8. **Private logging (finding 8).** Log stderr with the default (private) redaction, i.e. drop `privacy: .public`.

- [ ] **Step 1: Write failing checks in RunnerCheck.**
  - (a) Signal case: on a `DispatchQueue.global()` thread, block SIGTERM with `pthread_sigmask(SIG_BLOCK, …)`, then call `run`. The fake CLI does `trap 'echo term > "<marker>"; exit 0' TERM; while :; do sleep 0.1; done` with `timeout: 1`. Assert the reply is `timeout` and the marker file exists.
  - (b) Flip the escape assertion to success with nil code within 3s.
  - (c) Update the `defaultCandidates` expectation. Use a temp home containing `.nvm/versions/node/v18.0.0/bin` and `v20.1.0/bin`, and assert v20.1.0 comes before v18.0.0. Missing managers contribute nothing.
  - (d) Update the `childEnvironment` assertions: PATH starts with the binary's directory, then `/opt/homebrew/opt/node/bin`.
  - Run `scripts/codeburn-check.sh` and confirm (a) and (b) fail for the stated reason before the fix.
- [ ] **Step 2: Rewrite `CodeBurnRunner.swift` to the behaviour above.**
- [ ] **Step 3: Run the checks until all pass, plus the leftover-process check.** Existing cases (not-installed, non-zero exit, 5 MB cap, busy, timeout kills the group, exactly-one-reply, argv/env allowlist) must still pass unchanged.
- [ ] **Step 4: Commit** `fix(codeburn): finish runs on child exit, reset signals, find version-manager installs`.

### Task 2: Payload and manager — safe currency, parsed date, localized age, off-main decode, published in-flight flag

Findings 3, 6 (manager half), 10, 11 (date half), 14 (period titles), 15.

**Files:**
- Modify: `boringNotch/models/CodeBurnPayload.swift`, `boringNotch/managers/CodeBurnManager.swift`
- Test: `scripts/codeburn-checks/PayloadCheck.swift`, `scripts/codeburn-checks/ManagerCheck.swift`

**Interfaces:**
- Produces:
  - `CodeBurnPayload.generatedDate: Date?` becomes a stored `let`, parsed once in `init(from:)`.
  - `static func ageText(since: Date, now: Date = Date(), locale: Locale = .current) -> String`.
  - `CodeBurnPeriod.title: String`, localized via `String(localized:)`.
  - `CodeBurnManager.isFetching: Bool` (`@Published private(set)`), true while any fetch is in flight.

**Required behaviour:**

1. **Currency (finding 3).**
   - `formatCost` gets the number of fraction digits for `currency.code` from a static cached `NumberFormatter` (`.currency` style, `currencyCode` set, en_US_POSIX locale), read via `maximumFractionDigits`. This gives JPY/KRW/VND/CLP/ISK 0 and USD/EUR 2.
   - Format with `String(format: "%.*f", digits, value)` and prefix `currency.symbol`.
   - Never convert to `Int`. A non-finite or huge value must not trap.
   - Remove the hard-coded JPY/KRW list.
2. **Date (finding 11).** Parse `generated` once in `init(from:)` using two static `ISO8601DateFormatter`s, one with fractional seconds and one without.
3. **Age (finding 15).**
   - `ageText` returns `String(localized: "now")` under 60s.
   - Otherwise it uses `RelativeDateTimeFormatter` (`unitsStyle = .abbreviated`, `locale` = the parameter) and returns `localizedString(for: since, relativeTo: now)`.
   - Update PayloadCheck to pin `Locale(identifier: "en_US")` and assert the exact strings the formatter produces for 30s ("now"), 240s, 7300s and 3 days. Run the check once and adopt the formatter's real output as the expectation; do not guess it.
4. **Titles (finding 14).** `CodeBurnPeriod.title` returns `String(localized: "Today")`, `String(localized: "7d")`, `String(localized: "30d")`, `String(localized: "Month")`.
5. **Off-main decode (finding 10).**
   - In `CodeBurnManager.refresh()`, decode the `Data` off the main actor: a `nonisolated static func decode(_ data: Data) -> CodeBurnPayload?` awaited through `Task.detached`.
   - Then apply on the main actor.
   - The ordering guarantee stays: the result lands on the requested period, `inFlight` is cleared, then the follow-up `refreshIfStale()` runs when the period changed.
6. **In-flight flag (finding 6).**
   - Rename the private `inFlight` to `@Published private(set) var isFetching`.
   - Keep the refresh guard (one fetch at a time). Do not add a queue: when a fetch lands, the existing `period != requested` follow-up fetches the new period.
7. **Tests.**
   - PayloadCheck: `formatCost` with `{"code":"JPY","rate":1e300}` does not trap and has no decimal point. VND gives 0 decimals, EUR gives 2. `generatedDate` still parses both fixture forms.
   - ManagerCheck: `isFetching` is true between `refresh()` and completion, false after; existing cases still pass.

- [ ] **Step 1: Add the failing checks.**
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run the checks, then the unsigned build.** `CodeBurnView.swift` still compiles against these APIs.
- [ ] **Step 4: Commit** `fix(codeburn): safe currency format, localized age and titles, decode off main`.

### Task 3: View, tabs, coordinator — stable rows, live age, spinner, tab consistency

Findings 4, 5, 6 (view half), 11 (view half), 13, 14 (catalog).

**Files:**
- Modify:
  - `boringNotch/components/CodeBurn/CodeBurnView.swift`
  - `boringNotch/components/Tabs/TabSelectionView.swift`
  - `boringNotch/components/Notch/BoringHeader.swift`
  - `boringNotch/BoringViewCoordinator.swift`
  - `boringNotch/components/Settings/SettingsView.swift`
- Possibly modify: `boringNotch/Localizable.xcstrings`, but only via the export step below.

**Interfaces:**
- Consumes (from Task 2): `CodeBurnPayload.generatedDate`, `ageText(since:now:locale:)`, `CodeBurnManager.isFetching`.
- Produces: `TabModel.visible(shelfEnabled:shelfEmpty:alwaysShowTabs:codeBurnEnabled:currentView:)`.

**Required behaviour:**

1. **Row identity (finding 5).** Rows are identified by position. Build rows with `enumerated()` and set `Row.id` to the offset (`Int`), so duplicate names or ids never collide.
2. **Live age (finding 11).** Wrap the age `Text` in `TimelineView(.periodic(from: .now, by: 60))` and pass `context.date` as `now`.
3. **Spinner (finding 6).** The header shows the `ProgressView` when `manager.current.status == .loading || manager.isFetching`. Otherwise it shows the ↻ button.
4. **Tab consistency (finding 4).** Add a `currentView: NotchViews` parameter to `TabModel.visible`. The Shelf tab is included when `shelfEnabled && (!shelfEmpty || alwaysShowTabs || (codeBurnEnabled && currentView == .shelf))`. Pass `coordinator.currentView` from both `TabSelectionView` and `BoringHeader`. With CodeBurn off, the extra term is false, so all 8 combinations match `main`. Verify this with a throwaway `swiftc` truth-table program over the 8 cases × currentView ∈ {home, shelf} × codeBurn ∈ {off, on}, and paste its output into the report. Do not commit that program.
5. **Reset in the coordinator (finding 13).**
   - Remove the `.onChange(of: showCodeBurnTab)` block from `SettingsView.swift`.
   - In `BoringViewCoordinator`, observe the key: `Defaults.publisher(.showCodeBurnTab)` sink stored in a cancellable, on the main actor, following the existing Combine usage in that file.
   - When the key turns false while `currentView == .codeburn`, set `currentView = .home`.
   - Remove the `@Default(.showCodeBurnTab)` property from the Settings struct if nothing else uses it.
6. **Catalog (finding 14).**
   - Run `xcodebuild -exportLocalizations -project boringNotch.xcodeproj -localizationPath "$TMPDIR/cb-loc" -exportLanguage en`, then `git diff --stat boringNotch/Localizable.xcstrings`.
   - If the catalog changed and the diff only adds new keys (no edits to existing entries' translations or states), commit it in a separate commit, `chore(codeburn): add CodeBurn source strings to the string catalog`.
   - Otherwise, `git checkout boringNotch/Localizable.xcstrings` and report "catalog not updated" with the diff stat and the reason.

- [ ] **Step 1: Implement 1–5.**
- [ ] **Step 2: Run the truth-table program, the checks and the unsigned build.**
- [ ] **Step 3: Commit** `fix(codeburn): stable row ids, live age, fetch spinner, tab consistency`.
- [ ] **Step 4: Catalog step (6).**
