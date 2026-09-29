# CodeBurn Notch Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in CodeBurn tab to the open notch that shows AI coding spend (cost, calls, sessions, cache hit, active sessions, top models, top projects) for Today / 7d / 30d / Month, sourced from the locally installed `codeburn` CLI.

**Architecture:** The sandboxed app cannot read `~/.claude` etc., so the existing unsandboxed XPC helper spawns `codeburn status --format menubar-json --period <p> --no-optimize` (via `posix_spawn` in its own process group, non-blocking) and returns stdout. The app decodes a minimal payload subset, caches it per period in a `@MainActor` manager, and renders a three-column SwiftUI view behind a Settings toggle (default OFF).

**Tech Stack:** Swift 5 mode, SwiftUI, macOS 14+, NSXPCConnection via `AsyncXPCConnection`, `Defaults` package, `posix_spawn`, `swiftc` standalone check programs (the Xcode project has no test target).

**Spec:** `docs/superpowers/specs/2026-09-29-codeburn-notch-tab-design.md`

## Global Constraints

- CLI command line is fixed: `codeburn status --format menubar-json --period <today|week|30days|month> --no-optimize`.
- Helper period allowlist: `today`, `week`, `30days`, `month`. The app never sends a path or arbitrary arguments.
- Helper reply codes: `(stdout, nil)` on success; `(nil, "not-installed" | "busy" | "timeout" | "failed")` otherwise.
- Binary candidates, first executable wins: `/opt/homebrew/bin/codeburn`, `/usr/local/bin/codeburn`, `~/.npm-global/bin/codeburn`, `~/.local/bin/codeburn`, `~/.volta/bin/codeburn` (`~` from `FileManager.default.homeDirectoryForCurrentUser`).
- Child environment allowlist: `HOME`, `USER`, `TMPDIR`, `LANG`, `PATH`, `NODE_ENV=production`. PATH starts with `/opt/homebrew/opt/node/bin`, then candidate dirs, then `/usr/bin:/bin`.
- Timeout 60s: SIGTERM to the process group, SIGKILL 2s later. One CLI at a time. stdout cap 5 MB.
- Raw stderr never reaches the UI; it goes to `os_log` (subsystem `theboringteam.boringnotch.BoringNotchXPCHelper`, category `CodeBurn`).
- Settings key: `showCodeBurnTab`, default `false`.
- Cache max age: 5 minutes per period.
- Costs in the payload are USD; display = `cost * currency.rate`; zero decimals for `JPY` and `KRW`, two otherwise.
- Model and project names are rendered with `Text(verbatim:)`.
- With `showCodeBurnTab` off, header and tab behaviour must be identical to `main`.
- New app-target files are NOT auto-included: each needs PBXFileReference, PBXBuildFile, group child and Sources entries in `boringNotch.xcodeproj/project.pbxproj`. Helper files (`BoringNotchXPCHelper/`) are in a synchronized folder and need no pbxproj edit.
- Reserved pbxproj IDs for this plan: `CB0000000000000000000001` … `CB0000000000000000000007` (verified unused).
- Build gate command (run from repo root; expected last line `** BUILD SUCCEEDED **`):
  ```bash
  xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
  ```
  The gate is "no new errors, and no new warnings in files this plan touches" relative to the baseline build of `main`, with one accepted exception: the new `codeBurnStatus` wrapper in `XPCHelperClient.swift` carries the same two Swift 6 Sendable warnings (`RemoteXPCService … does not conform to 'Sendable'`, `capture of 'self' with non-Sendable type 'XPCHelperClient'`) that every existing wrapper in that file has. Warning counts in untouched files can vary by one between builds.
- Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Never commit anything under `example/` or any scratchpad file.

## File Map

| File | Status | Responsibility |
|---|---|---|
| `boringNotch/models/CodeBurnPayload.swift` | create | Period enum, fetch error enum, payload subset + display helpers (Foundation only) |
| `BoringNotchXPCHelper/CodeBurnRunner.swift` | create | Resolve binary, build env, `posix_spawn` CLI, timeout, reply once (Foundation only) |
| `BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift` | modify | Add `fetchCodeBurnStatus` |
| `boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift` | modify | Same method, identical |
| `BoringNotchXPCHelper/BoringNotchXPCHelper.swift` | modify | `@objc` method delegating to `CodeBurnRunner` |
| `boringNotch/XPCHelperClient/XPCHelperClient.swift` | modify | Async wrapper `codeBurnStatus(period:)` |
| `boringNotch/managers/CodeBurnManager.swift` | create | Per-period cache, one in-flight fetch, staleness |
| `boringNotch/components/CodeBurn/CodeBurnView.swift` | create | Tab UI |
| `boringNotch/enums/generic.swift` | modify | `NotchViews.codeburn` |
| `boringNotch/ContentView.swift` | modify | Route `.codeburn` to `CodeBurnView` |
| `boringNotch/models/Constants.swift` | modify | `showCodeBurnTab` key |
| `boringNotch/components/Tabs/TabSelectionView.swift` | modify | Per-tab gating, stable tab ids |
| `boringNotch/components/Notch/BoringHeader.swift` | modify | Show bar when `visible(...).count > 1` |
| `boringNotch/components/Settings/SettingsView.swift` | modify | Toggle + fall back to Home |
| `boringNotch.xcodeproj/project.pbxproj` | modify | Register the three new app files |
| `scripts/codeburn-check.sh` | create | One command: compile + run all standalone checks |
| `scripts/codeburn-checks/Check.swift` | create | `check()` assertion helper |
| `scripts/codeburn-checks/PayloadCheck.swift` | create | Payload decode + display checks |
| `scripts/codeburn-checks/RunnerCheck.swift` | create | Runner checks with fake CLIs |
| `scripts/codeburn-checks/ManagerCheck.swift` | create | Manager checks with stub XPC client |
| `scripts/codeburn-checks/fixtures/codeburn-today.json` | create | Anonymised real-shaped payload |

Paths refine the spec's testing section (`scripts/codeburn-decode-check.swift` became `scripts/codeburn-checks/PayloadCheck.swift`, driven by `scripts/codeburn-check.sh`). Check programs use `@main` and are compiled with `swiftc -parse-as-library`, because top-level code is only allowed in a file named `main.swift`.

---

### Task 0: Baseline

**Files:** none

- [ ] **Step 1: Confirm branch and clean tree**

Run: `git status --short && git branch --show-current`
Expected: branch `feat/codeburn-notch-tab`; only `?? example/` untracked.

- [ ] **Step 2: Baseline build of unchanged code**

Build unchanged code, keeping the full log:
```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd" \
  CODE_SIGNING_ALLOWED=NO build > "$TMPDIR/baseline-build.log" 2>&1; echo "exit=$?"
grep -c ' warning: ' "$TMPDIR/baseline-build.log"; tail -1 "$TMPDIR/baseline-build.log"
```
Expected: `exit=0`, last line `** BUILD SUCCEEDED **`. Record the warning count (57 when this plan was written); later builds compare against it. If the baseline fails, STOP and report — do not start Task 1.

---

### Task 1: Payload model and decode check

**Files:**
- Create: `boringNotch/models/CodeBurnPayload.swift`
- Create: `scripts/codeburn-checks/Check.swift`
- Create: `scripts/codeburn-checks/PayloadCheck.swift`
- Create: `scripts/codeburn-checks/fixtures/codeburn-today.json`
- Create: `scripts/codeburn-check.sh`
- Modify: `boringNotch.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `enum CodeBurnPeriod: String, CaseIterable, Identifiable { case today, week, thirtyDays = "30days", month }` with `var cliArg: String`, `var title: String`
  - `enum CodeBurnFetchError: Error, Equatable { case notInstalled, busy, timeout, failed, decode }` with `init(helperCode: String?)`
  - `struct CodeBurnPayload: Decodable, Equatable` with `generated: String`, `stale: Bool?`, `currency: Currency`, `current: Current`, `liveSessions: LiveSessions?`
  - `CodeBurnPayload.Current`: `label: String`, `cost: Double`, `calls: Int`, `sessions: Int`, `cacheHitPercent: Double`, `sessionCountBasis: String?`, `topModels: [Model]`, `unpricedModelCount: Int`, `topProjects: [Project]`
  - `CodeBurnPayload.Model`: `name: String`, `cost: Double`
  - `CodeBurnPayload.Project`: `id: String?`, `name: String`, `cost: Double`, `var rowID: String`
  - `CodeBurnPayload.LiveSessions`: `count: Int`
  - `func formatCost(_ usd: Double) -> String`, `var sessionsText: String`, `var pricedModels: [Model]`, `var generatedDate: Date?`, `static func ageText(since: Date, now: Date = Date()) -> String`
  - `func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line)` in `Check.swift`

- [ ] **Step 1: Write the assertion helper**

`scripts/codeburn-checks/Check.swift`:
```swift
import Foundation

/// Minimal assertion for the standalone CodeBurn check programs (no XCTest target exists).
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8))
        exit(1)
    }
}
```

- [ ] **Step 2: Write the fixture**

`scripts/codeburn-checks/fixtures/codeburn-today.json` (real-shaped values from codeburn 0.9.25, names anonymised, extra fields kept to prove unknown keys are ignored):
```json
{
  "generated": "2026-09-29T09:09:22.900Z",
  "currency": { "code": "USD", "symbol": "$", "rate": 1 },
  "current": {
    "label": "Today (2026-09-29)",
    "cost": 149.9569006,
    "calls": 1445,
    "sessions": 45,
    "sessionCountBasis": "partial",
    "oneShotRate": 0.5555555555555556,
    "inputTokens": 1838130,
    "outputTokens": 1254155,
    "cacheReadTokens": 292593822,
    "cacheWriteTokens": 10273567,
    "cacheHitPercent": 99.37570294680518,
    "topModels": [
      { "name": "Opus 5.5", "cost": 77.05049, "calls": 575, "savingsUSD": 0 },
      { "name": "Sonnet 5.5", "cost": 40.1201, "calls": 400, "savingsUSD": 0 },
      { "name": "Haiku 4.5", "cost": 9.3, "calls": 300, "savingsUSD": 0 },
      { "name": "GPT-5", "cost": 6.1, "calls": 20, "savingsUSD": 0 },
      { "name": "local-llama", "cost": 0, "calls": 150, "savingsUSD": 1.2 }
    ],
    "unpricedModels": [ { "model": "mystery-model", "calls": 3, "tokens": 1200 } ],
    "topProjects": [
      { "id": "/Users/dev/work/alpha", "name": "alpha", "cost": 99.4197856, "savingsUSD": 0, "sessions": 14 },
      { "id": "/Users/dev/other/alpha", "name": "alpha", "cost": 30.12, "savingsUSD": 0, "sessions": 5 },
      { "name": "beta", "cost": 12.5, "savingsUSD": 0, "sessions": 3 }
    ],
    "providers": { "claude": 149.9569006 }
  },
  "optimize": { "findingCount": 0, "savingsUSD": 0, "topFindings": [] },
  "history": { "daily": [] },
  "liveSessions": {
    "windowSeconds": 600,
    "sessions": [
      { "id": "s1", "provider": "claude", "project": "alpha" },
      { "id": "s2", "provider": "codex", "project": "beta" }
    ]
  }
}
```

- [ ] **Step 3: Write the failing check program**

`scripts/codeburn-checks/PayloadCheck.swift`:
```swift
import Foundation

@main
enum PayloadCheck {
    static func main() throws {
        let checksDir = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> CodeBurnPayload {
            try decoder.decode(CodeBurnPayload.self, from: Data(json.utf8))
        }

        // Real-shaped fixture.
        let data = try Data(contentsOf: checksDir.appendingPathComponent("fixtures/codeburn-today.json"))
        let p = try decoder.decode(CodeBurnPayload.self, from: data)
        check(p.current.label == "Today (2026-09-29)", "label")
        check(p.current.calls == 1445, "calls")
        check(p.formatCost(p.current.cost) == "$149.96", "USD cost: \(p.formatCost(p.current.cost))")
        check(p.sessionsText == "≥45", "partial sessions: \(p.sessionsText)")
        check(p.pricedModels.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Haiku 4.5", "GPT-5"], "priced models: \(p.pricedModels.map(\.name))")
        check(p.current.unpricedModelCount == 1, "unpriced count")
        check(p.current.topProjects.map(\.rowID) == ["/Users/dev/work/alpha", "/Users/dev/other/alpha", "beta"], "project row ids")
        check(p.liveSessions?.count == 2, "live count")
        check(p.stale == nil, "stale absent")
        check(p.generatedDate != nil, "generated parses with fractional seconds")

        // Optional blocks absent, JPY, identity session basis, stale.
        let minimal = try decode("""
        {"generated":"2026-09-29T09:09:22Z","stale":true,
         "currency":{"code":"JPY","symbol":"¥","rate":150},
         "current":{"label":"7 Days","cost":10.004,"calls":3,"sessions":2,"sessionCountBasis":"identity",
                    "cacheHitPercent":50,"topModels":[],"topProjects":[]}}
        """)
        check(minimal.formatCost(minimal.current.cost) == "¥1501", "JPY zero decimals: \(minimal.formatCost(minimal.current.cost))")
        check(minimal.sessionsText == "2", "identity sessions: \(minimal.sessionsText)")
        check(minimal.liveSessions == nil, "liveSessions absent means unknown")
        check(minimal.current.unpricedModelCount == 0, "unpricedModels absent")
        check(minimal.stale == true, "stale true")
        check(minimal.generatedDate != nil, "generated parses without fractional seconds")

        // No currency block at all: USD defaults.
        let noCurrency = try decode("""
        {"generated":"2026-09-29T09:09:22.900Z",
         "current":{"label":"Month","cost":1.5,"calls":1,"sessions":1,"cacheHitPercent":0,"topModels":[],"topProjects":[]}}
        """)
        check(noCurrency.formatCost(1.5) == "$1.50", "default currency: \(noCurrency.formatCost(1.5))")

        // Fresh user: CLI exits 0 with zeros and empty arrays.
        let empty = try decode("""
        {"generated":"2026-09-29T09:09:22.900Z","currency":{"code":"USD","symbol":"$","rate":1},
         "current":{"label":"Today (2026-09-29)","cost":0,"calls":0,"sessions":0,"cacheHitPercent":0,
                    "topModels":[],"unpricedModels":[],"topProjects":[]},
         "liveSessions":{"windowSeconds":600,"sessions":[]}}
        """)
        check(empty.current.calls == 0, "empty calls")
        check(empty.liveSessions?.count == 0, "empty live sessions")

        // Freshness label.
        let base = Date(timeIntervalSince1970: 1_000_000)
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(30)) == "now", "age now")
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(240)) == "4m ago", "age minutes")
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(7300)) == "2h ago", "age hours")

        // Periods match the helper allowlist; helper codes map to errors.
        check(CodeBurnPeriod.allCases.map(\.cliArg) == ["today", "week", "30days", "month"], "period cli args")
        check(CodeBurnFetchError(helperCode: "not-installed") == .notInstalled, "not-installed")
        check(CodeBurnFetchError(helperCode: "busy") == .busy, "busy")
        check(CodeBurnFetchError(helperCode: "timeout") == .timeout, "timeout")
        check(CodeBurnFetchError(helperCode: "failed") == .failed, "failed")
        check(CodeBurnFetchError(helperCode: nil) == .failed, "nil code")

        print("PayloadCheck OK")
    }
}
```

- [ ] **Step 4: Write the check runner script**

`scripts/codeburn-check.sh`:
```sh
#!/bin/sh
# Compiles and runs the standalone CodeBurn checks (the Xcode project has no test target).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
C="$ROOT/scripts/codeburn-checks"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -parse-as-library -o "$OUT/payload" \
  "$C/Check.swift" "$C/PayloadCheck.swift" "$ROOT/boringNotch/models/CodeBurnPayload.swift"
"$OUT/payload" "$C"
```
Run: `chmod +x scripts/codeburn-check.sh`

- [ ] **Step 5: Run to verify it fails**

Run: `scripts/codeburn-check.sh`
Expected: compile error, `error: no such file or directory: '.../boringNotch/models/CodeBurnPayload.swift'`.

- [ ] **Step 6: Write the model**

`boringNotch/models/CodeBurnPayload.swift`:
```swift
//
//  CodeBurnPayload.swift
//  boringNotch
//
//  The subset of `codeburn status --format menubar-json` that the CodeBurn tab
//  renders. Foundation-only so scripts/codeburn-check.sh can compile it standalone.
//

import Foundation

enum CodeBurnPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case thirtyDays = "30days"
    case month

    var id: String { rawValue }
    var cliArg: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7d"
        case .thirtyDays: return "30d"
        case .month: return "Month"
        }
    }
}

enum CodeBurnFetchError: Error, Equatable {
    case notInstalled
    case busy
    case timeout
    case failed
    case decode

    /// Maps the XPC helper's reply code (see CodeBurnRunner) to an app error.
    init(helperCode: String?) {
        switch helperCode {
        case "not-installed": self = .notInstalled
        case "busy": self = .busy
        case "timeout": self = .timeout
        default: self = .failed
        }
    }
}

struct CodeBurnPayload: Decodable, Equatable {
    struct Currency: Decodable, Equatable {
        var code: String
        var symbol: String
        var rate: Double

        init(code: String = "USD", symbol: String = "$", rate: Double = 1) {
            self.code = code
            self.symbol = symbol
            self.rate = rate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? "USD"
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "$"
            rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        }

        private enum CodingKeys: String, CodingKey { case code, symbol, rate }
    }

    struct Model: Decodable, Equatable {
        let name: String
        let cost: Double
    }

    struct Project: Decodable, Equatable {
        /// Full project path when the CLI knows it.
        let id: String?
        /// Folder basename; two projects can share it.
        let name: String
        let cost: Double

        var rowID: String { id ?? name }
    }

    struct Current: Decodable, Equatable {
        let label: String
        let cost: Double
        let calls: Int
        let sessions: Int
        /// 0–100.
        let cacheHitPercent: Double
        /// Anything but `identity` means `sessions` is a lower bound.
        let sessionCountBasis: String?
        /// Sorted by cost, uncapped, may contain $0 rows.
        let topModels: [Model]
        /// Models that ran but have no price (shown as $0 upstream).
        let unpricedModelCount: Int
        let topProjects: [Project]

        private enum CodingKeys: String, CodingKey {
            case label, cost, calls, sessions, cacheHitPercent, sessionCountBasis
            case topModels, unpricedModels, topProjects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            cost = try c.decode(Double.self, forKey: .cost)
            calls = try c.decode(Int.self, forKey: .calls)
            sessions = try c.decode(Int.self, forKey: .sessions)
            cacheHitPercent = try c.decodeIfPresent(Double.self, forKey: .cacheHitPercent) ?? 0
            sessionCountBasis = try c.decodeIfPresent(String.self, forKey: .sessionCountBasis)
            topModels = try c.decodeIfPresent([Model].self, forKey: .topModels) ?? []
            unpricedModelCount = try c.decodeIfPresent([Ignored].self, forKey: .unpricedModels)?.count ?? 0
            topProjects = try c.decodeIfPresent([Project].self, forKey: .topProjects) ?? []
        }
    }

    struct LiveSessions: Decodable, Equatable {
        let count: Int

        private enum CodingKeys: String, CodingKey { case sessions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = try c.decodeIfPresent([Ignored].self, forKey: .sessions)?.count ?? 0
        }
    }

    /// Consumes one JSON value without keeping it; used where only a count matters.
    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    let generated: String
    /// True when the CLI served older data because another process held its cache lock.
    let stale: Bool?
    let currency: Currency
    let current: Current
    /// Absent means "unknown", not zero.
    let liveSessions: LiveSessions?

    private enum CodingKeys: String, CodingKey { case generated, stale, currency, current, liveSessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated = try c.decode(String.self, forKey: .generated)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        currency = try c.decodeIfPresent(Currency.self, forKey: .currency) ?? Currency()
        current = try c.decode(Current.self, forKey: .current)
        liveSessions = try c.decodeIfPresent(LiveSessions.self, forKey: .liveSessions)
    }

    // MARK: - Display

    /// Payload costs are USD. JPY and KRW have no minor unit.
    func formatCost(_ usd: Double) -> String {
        let value = usd * currency.rate
        if ["JPY", "KRW"].contains(currency.code) {
            return "\(currency.symbol)\(Int(value.rounded()))"
        }
        return currency.symbol + String(format: "%.2f", value)
    }

    var sessionsText: String {
        let basis = current.sessionCountBasis
        let isExact = basis == nil || basis == "identity"
        return (isExact ? "" : "≥") + "\(current.sessions)"
    }

    /// $0 rows (local, free or unpriced models) are left out; unpriced ones are counted separately.
    var pricedModels: [Model] { current.topModels.filter { $0.cost > 0 } }

    var generatedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: generated) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: generated)
    }

    /// Freshness of the data itself (the CLI may serve a saved snapshot), not of the fetch.
    static func ageText(since date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
```

- [ ] **Step 7: Run the check to verify it passes**

Run: `scripts/codeburn-check.sh`
Expected: `PayloadCheck OK`, exit 0.

- [ ] **Step 8: Register the file in the Xcode project**

Run from repo root:
```bash
python3 - <<'EOF'
p = "boringNotch.xcodeproj/project.pbxproj"
s = open(p).read()
def after(anchor, line):
    global s
    assert s.count(anchor) == 1, "anchor not unique: " + anchor
    s = s.replace(anchor, anchor + "\n" + line, 1)
# PBXBuildFile
after('1153BD912D986DB300979FB0 /* PlaybackState.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1153BD902D986DB300979FB0 /* PlaybackState.swift */; };',
      '\t\tCB0000000000000000000002 /* CodeBurnPayload.swift in Sources */ = {isa = PBXBuildFile; fileRef = CB0000000000000000000001 /* CodeBurnPayload.swift */; };')
# PBXFileReference
after('1153BD902D986DB300979FB0 /* PlaybackState.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PlaybackState.swift; sourceTree = "<group>"; };',
      '\t\tCB0000000000000000000001 /* CodeBurnPayload.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CodeBurnPayload.swift; sourceTree = "<group>"; };')
# models group child
after('1153BD902D986DB300979FB0 /* PlaybackState.swift */,',
      '\t\t\t\tCB0000000000000000000001 /* CodeBurnPayload.swift */,')
# app Sources build phase
after('1153BD912D986DB300979FB0 /* PlaybackState.swift in Sources */,',
      '\t\t\t\tCB0000000000000000000002 /* CodeBurnPayload.swift in Sources */,')
open(p, "w").write(s)
EOF
plutil -lint boringNotch.xcodeproj/project.pbxproj
```
Expected: `boringNotch.xcodeproj/project.pbxproj: OK`

- [ ] **Step 9: Build gate**

Run the build gate command from Global Constraints.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add boringNotch/models/CodeBurnPayload.swift scripts/codeburn-check.sh scripts/codeburn-checks boringNotch.xcodeproj/project.pbxproj
git commit -m "feat(codeburn): add payload model and decode check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: CLI runner in the XPC helper

**Files:**
- Create: `BoringNotchXPCHelper/CodeBurnRunner.swift`
- Create: `scripts/codeburn-checks/RunnerCheck.swift`
- Modify: `scripts/codeburn-check.sh`

**Interfaces:**
- Consumes: `check(...)` from `scripts/codeburn-checks/Check.swift`.
- Produces:
  - `final class CodeBurnRunner` with `init(candidates: [URL] = CodeBurnRunner.defaultCandidates(home: FileManager.default.homeDirectoryForCurrentUser), timeout: TimeInterval = 60)`
  - `func run(period: String, reply: @escaping (Data?, String?) -> Void)` — never blocks, replies exactly once
  - `static func defaultCandidates(home: URL) -> [URL]`
  - `static func childEnvironment(parent: [String: String], home: URL, candidates: [URL]) -> [String: String]`
  - `static let allowedPeriods: Set<String>`, `static let maxOutputBytes: Int`

Design notes the implementer must keep:
- `posix_spawn` (not `Process`) with `POSIX_SPAWN_SETPGROUP` + `posix_spawnattr_setpgroup(&attr, 0)`, so `kill(-pid, …)` reaches node and anything it started. `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps the helper's XPC descriptors out of the child.
- Reap with a blocking `waitpid` on a global queue (a process dispatch source can miss an exit that happened before it was registered).
- A `DispatchGroup` with three entries (stdout EOF, stderr EOF, waitpid). The single `reply` call lives in its `notify`, so "exactly once" holds by construction. The busy flag is released there too, before replying, so a dying first run can never overlap a second.

- [ ] **Step 1: Write the failing check program**

`scripts/codeburn-checks/RunnerCheck.swift`:
```swift
import Foundation

@main
enum RunnerCheck {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeburn-runner-check-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func fake(_ name: String, _ body: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func call(_ runner: CodeBurnRunner, _ period: String, wait: TimeInterval = 10) -> (data: Data?, code: String?) {
            let done = DispatchSemaphore(value: 0)
            var result: (Data?, String?) = (nil, nil)
            runner.run(period: period) { data, code in
                result = (data, code)
                done.signal()
            }
            check(done.wait(timeout: .now() + wait) == .success, "no reply for \(period)")
            return result
        }

        // Pure environment allowlist.
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidates = CodeBurnRunner.defaultCandidates(home: home)
        check(candidates.map(\.path) == [
            "/opt/homebrew/bin/codeburn", "/usr/local/bin/codeburn",
            "/Users/tester/.npm-global/bin/codeburn", "/Users/tester/.local/bin/codeburn",
            "/Users/tester/.volta/bin/codeburn",
        ], "default candidates: \(candidates.map(\.path))")
        let env = CodeBurnRunner.childEnvironment(
            parent: ["USER": "tester", "TMPDIR": "/tmp/x", "LANG": "en_US.UTF-8", "HOME": "/elsewhere",
                     "NODE_OPTIONS": "--inspect", "NODE_PATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                     "PATH": "/evil/bin"],
            home: home, candidates: candidates)
        check(Set(env.keys) == ["HOME", "USER", "TMPDIR", "LANG", "PATH", "NODE_ENV"], "env keys: \(env.keys.sorted())")
        check(env["HOME"] == "/Users/tester", "HOME comes from the resolved home, not the parent")
        check(env["NODE_ENV"] == "production", "NODE_ENV")
        check(env["PATH"] == "/opt/homebrew/opt/node/bin:/opt/homebrew/bin:/usr/local/bin:/Users/tester/.npm-global/bin:/Users/tester/.local/bin:/Users/tester/.volta/bin:/usr/bin:/bin",
              "PATH: \(env["PATH"] ?? "nil")")

        // Allowlist and resolution.
        let missing = CodeBurnRunner(candidates: [dir.appendingPathComponent("missing")])
        check(call(missing, "all").code == "failed", "period outside allowlist is rejected")
        check(call(missing, "today").code == "not-installed", "no executable candidate")

        // Exact argv.
        let args = CodeBurnRunner(candidates: [try fake("args", "echo \"$@\"")])
        let argsResult = call(args, "week")
        check(argsResult.code == nil, "args run succeeded: \(argsResult.code ?? "")")
        check(argsResult.data.map { String(decoding: $0, as: UTF8.self) } == "status --format menubar-json --period week --no-optimize\n",
              "argv: \(argsResult.data.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")

        // Environment reaching the child.
        setenv("NODE_OPTIONS", "--inspect", 1)
        // Not named "env": candidate dirs precede /usr/bin on PATH, so the fake would call itself.
        let envRunner = CodeBurnRunner(candidates: [try fake("print-env", "/usr/bin/env")])
        let childEnv = call(envRunner, "today").data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(childEnv.contains("NODE_ENV=production"), "child sees NODE_ENV")
        check(!childEnv.contains("NODE_OPTIONS="), "child does not see NODE_OPTIONS")

        // Non-zero exit.
        let failing = CodeBurnRunner(candidates: [try fake("fail", "echo boom >&2\nexit 3")])
        let failResult = call(failing, "today")
        check(failResult.data == nil && failResult.code == "failed", "non-zero exit maps to failed")

        // Output cap.
        let big = CodeBurnRunner(candidates: [try fake("big", "head -c 6000000 /dev/zero")])
        check(call(big, "today").code == "failed", "stdout over 5 MB maps to failed")

        // Timeout, busy, process group kill, exactly one reply.
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let slow = CodeBurnRunner(candidates: [try fake("slow", "sleep 30 &\necho $! > '\(pidFile.path)'\nwait")], timeout: 1)
        let first = DispatchSemaphore(value: 0)
        var replies = 0
        var firstCode: String?
        slow.run(period: "today") { _, code in
            replies += 1
            firstCode = code
            first.signal()
        }
        check(call(slow, "today").code == "busy", "second call while running is busy")
        check(first.wait(timeout: .now() + 8) == .success, "timed-out run replied")
        check(firstCode == "timeout", "timeout code: \(firstCode ?? "nil")")
        Thread.sleep(forTimeInterval: 3)
        check(replies == 1, "exactly one reply, got \(replies)")
        let grandchild = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        check(grandchild > 0 && kill(grandchild, 0) != 0, "grandchild \(grandchild) was killed with the process group")
        check(call(slow, "today").code == "timeout", "runner is free again after a timeout")

        print("RunnerCheck OK")
    }
}
```

- [ ] **Step 2: Add the runner check to the script**

Append to `scripts/codeburn-check.sh`:
```sh

swiftc -parse-as-library -o "$OUT/runner" \
  "$C/Check.swift" "$C/RunnerCheck.swift" "$ROOT/BoringNotchXPCHelper/CodeBurnRunner.swift"
"$OUT/runner"
```

- [ ] **Step 3: Run to verify it fails**

Run: `scripts/codeburn-check.sh`
Expected: `PayloadCheck OK`, then compile error `no such file or directory: '.../BoringNotchXPCHelper/CodeBurnRunner.swift'`.

- [ ] **Step 4: Write the runner**

`BoringNotchXPCHelper/CodeBurnRunner.swift`:
```swift
//
//  CodeBurnRunner.swift
//  BoringNotchXPCHelper
//
//  Runs the user's `codeburn` CLI for the app's CodeBurn tab. The sandboxed app
//  cannot read ~/.claude and friends, so this unsandboxed helper spawns the CLI.
//  Foundation-only so scripts/codeburn-check.sh can compile it standalone.
//

import Foundation
import os

final class CodeBurnRunner: @unchecked Sendable {
    static let allowedPeriods: Set<String> = ["today", "week", "30days", "month"]
    static let maxOutputBytes = 5 * 1024 * 1024

    private static let log = os.Logger(subsystem: "theboringteam.boringnotch.BoringNotchXPCHelper", category: "CodeBurn")

    private let candidates: [URL]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var isRunning = false

    init(candidates: [URL] = CodeBurnRunner.defaultCandidates(home: FileManager.default.homeDirectoryForCurrentUser),
         timeout: TimeInterval = 60) {
        self.candidates = candidates
        self.timeout = timeout
    }

    static func defaultCandidates(home: URL) -> [URL] {
        ["/opt/homebrew/bin/codeburn", "/usr/local/bin/codeburn"].map { URL(fileURLWithPath: $0) }
            + [".npm-global/bin", ".local/bin", ".volta/bin"].map {
                home.appendingPathComponent($0).appendingPathComponent("codeburn")
            }
    }

    /// Explicit allowlist: nothing else from the helper's environment reaches the CLI
    /// (drops NODE_OPTIONS, NODE_PATH, DYLD_* and friends). The node directory comes
    /// first so a `#!/usr/bin/env node` shebang can't pick up a planted `node`.
    static func childEnvironment(parent: [String: String], home: URL, candidates: [URL]) -> [String: String] {
        var env = ["HOME": home.path, "NODE_ENV": "production"]
        for key in ["USER", "TMPDIR", "LANG"] {
            env[key] = parent[key]
        }
        var path = ["/opt/homebrew/opt/node/bin"]
        for dir in candidates.map({ $0.deletingLastPathComponent().path }) + ["/usr/bin", "/bin"] where !path.contains(dir) {
            path.append(dir)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Replies exactly once: `(stdout, nil)` on success, otherwise `(nil, code)` with
    /// code in `not-installed | busy | timeout | failed`. Never blocks the caller, so
    /// other XPC messages on the same connection (brightness) are not held up.
    func run(period: String, reply: @escaping (Data?, String?) -> Void) {
        guard Self.allowedPeriods.contains(period) else { return reply(nil, "failed") }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return reply(nil, "not-installed")
        }
        guard claim() else { return reply(nil, "busy") }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = Self.childEnvironment(parent: ProcessInfo.processInfo.environment, home: home, candidates: candidates)
        let arguments = [binary.path, "status", "--format", "menubar-json", "--period", period, "--no-optimize"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        guard let pid = Self.spawn(arguments: arguments, environment: environment,
                                   stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
                                   stderr: stderrPipe.fileHandleForWriting.fileDescriptor) else {
            release()
            return reply(nil, "failed")
        }
        // Keep only the read ends so EOF arrives once the child group is gone.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let job = Job()
        let done = DispatchGroup()
        for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
            done.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    done.leave()
                } else if !job.append(chunk, toStdout: isStdout) {
                    kill(-pid, SIGKILL)
                }
            }
        }
        done.enter()
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            job.setStatus(status)
            done.leave()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard job.markTimedOut() else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !job.isFinished { kill(-pid, SIGKILL) }
            }
        }
        done.notify(queue: .global()) { [self] in
            // The pipes must outlive run(): dropping them closes the read ends and the
            // child dies of SIGPIPE on its first write.
            withExtendedLifetime((stdoutPipe, stderrPipe)) {}
            let result = job.finish()
            release()
            let exitedCleanly = result.status & 0x7f == 0 && (result.status >> 8) & 0xff == 0
            if result.timedOut {
                Self.log.error("codeburn timed out after \(self.timeout)s")
                reply(nil, "timeout")
            } else if result.overflowed {
                Self.log.error("codeburn stdout exceeded \(Self.maxOutputBytes) bytes")
                reply(nil, "failed")
            } else if exitedCleanly {
                reply(result.stdout, nil)
            } else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                Self.log.error("codeburn failed (status \(result.status)): \(stderr, privacy: .private)")
                reply(nil, "failed")
            }
        }
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return false }
        isRunning = true
        return true
    }

    private func release() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    /// posix_spawn rather than Process: the child leads its own process group, so a
    /// timeout can kill node together with anything it started.
    private static func spawn(arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32) -> pid_t? {
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        return posix_spawn(&pid, arguments[0], &actions, &attr, argv, envp) == 0 ? pid : nil
    }

    /// State shared by the pipe readers, the reaper and the timeout, behind one lock.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var status: Int32 = 0
        private var timedOut = false
        private var overflowed = false
        private var finished = false

        /// Returns false once stdout is over the cap.
        func append(_ chunk: Data, toStdout: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return false }
            if toStdout {
                stdout.append(chunk)
                overflowed = stdout.count > CodeBurnRunner.maxOutputBytes
            } else if stderr.count < 64 * 1024 {
                stderr.append(chunk)
            }
            return !overflowed
        }

        func setStatus(_ value: Int32) {
            lock.lock()
            status = value
            lock.unlock()
        }

        /// False when the run already finished, so a late timer does nothing.
        func markTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            timedOut = true
            return true
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func finish() -> (stdout: Data, stderr: Data, status: Int32, timedOut: Bool, overflowed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return (stdout, stderr, status, timedOut, overflowed)
        }
    }
}
```

- [ ] **Step 5: Run the checks to verify they pass**

Run: `scripts/codeburn-check.sh`
Expected: `PayloadCheck OK` then `RunnerCheck OK`, exit 0. (The timeout section takes ~5s.)

- [ ] **Step 6: Build gate**

Run the build gate command. The helper folder is synchronized, so no pbxproj edit is needed.
Expected: `** BUILD SUCCEEDED **`; `grep CodeBurnRunner` in the build log shows it compiled for the `BoringNotchXPCHelper` target.

- [ ] **Step 7: Commit**

```bash
git add BoringNotchXPCHelper/CodeBurnRunner.swift scripts/codeburn-checks/RunnerCheck.swift scripts/codeburn-check.sh
git commit -m "feat(codeburn): run codeburn CLI from the XPC helper

Non-blocking posix_spawn in its own process group, period allowlist,
env allowlist, 60s timeout, 5 MB stdout cap, one run at a time.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: XPC method and client wrapper

**Files:**
- Modify: `BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift` (end of protocol)
- Modify: `boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift` (end of protocol)
- Modify: `BoringNotchXPCHelper/BoringNotchXPCHelper.swift` (after `setScreenBrightness`)
- Modify: `boringNotch/XPCHelperClient/XPCHelperClient.swift` (end of class)

**Interfaces:**
- Consumes: `CodeBurnRunner.run(period:reply:)` (Task 2), `CodeBurnFetchError(helperCode:)` (Task 1).
- Produces: `nonisolated func codeBurnStatus(period: String) async -> Result<Data, CodeBurnFetchError>` on `XPCHelperClient`.

- [ ] **Step 1: Add the protocol method to BOTH protocol files**

In each of the two files, replace:
```swift
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
}
```
with:
```swift
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // CodeBurn CLI (spawned by the unsandboxed helper; the app sandbox can't read ~/.claude)
    func fetchCodeBurnStatus(period: String, with reply: @escaping (Data?, String?) -> Void)
}
```
Verify: `diff <(grep -v '^//' BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift | grep func) <(grep -v '^//' boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift | grep func)` prints nothing.

- [ ] **Step 2: Implement it in the helper**

In `BoringNotchXPCHelper/BoringNotchXPCHelper.swift`, replace:
```swift
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }
```
with:
```swift
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - CodeBurn

    private static let codeBurn = CodeBurnRunner()

    /// Returns immediately; CodeBurnRunner replies when the CLI finishes.
    @objc func fetchCodeBurnStatus(period: String, with reply: @escaping (Data?, String?) -> Void) {
        Self.codeBurn.run(period: period, reply: reply)
    }
```

- [ ] **Step 3: Add the client wrapper**

In `boringNotch/XPCHelperClient/XPCHelperClient.swift`, replace:
```swift
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
}
```
with:
```swift
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - CodeBurn

    nonisolated func codeBurnStatus(period: String) async -> Result<Data, CodeBurnFetchError> {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let (data, code): (Data?, String?) = try await service.withContinuation { service, continuation in
                service.fetchCodeBurnStatus(period: period) { data, code in
                    continuation.resume(returning: (data, code))
                }
            }
            if let data {
                return .success(data)
            }
            return .failure(CodeBurnFetchError(helperCode: code))
        } catch {
            return .failure(.failed)
        }
    }
}
```

- [ ] **Step 4: Build gate**

Run the build gate command.
Expected: `** BUILD SUCCEEDED **`. Only new warnings: the two Sendable warnings on the `codeBurnStatus` wrapper (same as every existing wrapper; see Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift BoringNotchXPCHelper/BoringNotchXPCHelper.swift boringNotch/XPCHelperClient/XPCHelperClient.swift
git commit -m "feat(codeburn): expose CodeBurn fetch over XPC

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: CodeBurn manager

**Files:**
- Create: `boringNotch/managers/CodeBurnManager.swift`
- Create: `scripts/codeburn-checks/ManagerCheck.swift`
- Modify: `scripts/codeburn-check.sh`
- Modify: `boringNotch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CodeBurnPeriod`, `CodeBurnPayload`, `CodeBurnFetchError` (Task 1); `XPCHelperClient.shared.codeBurnStatus(period:)` (Task 3).
- Produces:
  - `@MainActor final class CodeBurnManager: ObservableObject` with `static let shared`
  - `enum Status: Equatable { case idle, loading, failed(CodeBurnFetchError) }`
  - `struct Entry { var payload: CodeBurnPayload?; var fetchedAt: Date?; var status: Status }`
  - `@Published var period: CodeBurnPeriod`, `@Published private(set) var entries: [CodeBurnPeriod: Entry]`, `var current: Entry`
  - `func refreshIfStale()`, `func refresh()`, `static let maxAge: TimeInterval`

- [ ] **Step 1: Write the failing check program**

`scripts/codeburn-checks/ManagerCheck.swift` (includes a stub with the exact signature of the real `XPCHelperClient.codeBurnStatus`):
```swift
import Foundation

/// Stands in for the app's XPCHelperClient; same call signature as the real wrapper.
final class XPCHelperClient {
    static let shared = XPCHelperClient()
    var calls: [String] = []
    var handler: (String) async -> Result<Data, CodeBurnFetchError> = { _ in .failure(.failed) }

    func codeBurnStatus(period: String) async -> Result<Data, CodeBurnFetchError> {
        calls.append(period)
        return await handler(period)
    }
}

@main
enum ManagerCheck {
    @MainActor
    static func main() async throws {
        func payload(_ label: String) -> Data {
            Data("""
            {"generated":"2026-09-29T09:09:22.900Z","current":{"label":"\(label)","cost":1,"calls":1,"sessions":1,
             "cacheHitPercent":0,"topModels":[],"topProjects":[]}}
            """.utf8)
        }
        func sleep(_ ms: UInt64) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }

        let client = XPCHelperClient.shared
        client.handler = { period in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .success(payload(period))
        }
        let m = CodeBurnManager()

        // Switching period mid-fetch: the result lands on the period it was requested for.
        m.refresh()
        m.period = .week
        try await sleep(100)
        check(client.calls == ["today"], "one fetch in flight: \(client.calls)")
        check(m.entries[.today]?.status == .loading, "today loading")
        try await sleep(350)
        check(m.entries[.today]?.payload?.current.label == "today", "today result lands on today")
        check(m.entries[.week]?.payload == nil, "week not filled by today's result")
        check(client.calls == ["today", "week"], "week fetched after today finished: \(client.calls)")
        try await sleep(350)
        check(m.current.payload?.current.label == "week", "week shows week data")
        check(m.current.status == .idle, "week idle after success")

        // Fresh cache: no refetch.
        m.refreshIfStale()
        try await sleep(50)
        check(client.calls.count == 2, "fresh cache must not refetch: \(client.calls)")

        // Errors land on their own period only.
        client.handler = { _ in .failure(.notInstalled) }
        m.period = .month
        try await sleep(100)
        check(m.current.status == .failed(.notInstalled), "month failed: \(m.current.status)")
        check(m.entries[.week]?.status == .idle, "week untouched")

        // Undecodable output.
        client.handler = { _ in .success(Data("not json".utf8)) }
        m.refresh()
        try await sleep(100)
        check(m.current.status == .failed(.decode), "decode failure: \(m.current.status)")

        print("ManagerCheck OK")
    }
}
```

- [ ] **Step 2: Add the manager check to the script**

Append to `scripts/codeburn-check.sh`:
```sh

swiftc -parse-as-library -o "$OUT/manager" \
  "$C/Check.swift" "$C/ManagerCheck.swift" \
  "$ROOT/boringNotch/models/CodeBurnPayload.swift" "$ROOT/boringNotch/managers/CodeBurnManager.swift"
"$OUT/manager"
```

- [ ] **Step 3: Run to verify it fails**

Run: `scripts/codeburn-check.sh`
Expected: `PayloadCheck OK`, `RunnerCheck OK`, then compile error `no such file or directory: '.../boringNotch/managers/CodeBurnManager.swift'`.

- [ ] **Step 4: Write the manager**

`boringNotch/managers/CodeBurnManager.swift`:
```swift
//
//  CodeBurnManager.swift
//  boringNotch
//
//  Fetches CodeBurn spend per period through the XPC helper and caches it.
//

import Combine
import Foundation

@MainActor
final class CodeBurnManager: ObservableObject {
    static let shared = CodeBurnManager()

    enum Status: Equatable {
        case idle
        case loading
        case failed(CodeBurnFetchError)
    }

    struct Entry {
        var payload: CodeBurnPayload?
        var fetchedAt: Date?
        var status: Status = .idle
    }

    static let maxAge: TimeInterval = 5 * 60

    @Published var period: CodeBurnPeriod = .today {
        didSet { refreshIfStale() }
    }
    @Published private(set) var entries: [CodeBurnPeriod: Entry] = [:]
    private var inFlight = false

    var current: Entry { entries[period] ?? Entry() }

    /// Called on tab appear and period change.
    func refreshIfStale() {
        if let fetchedAt = current.fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.maxAge { return }
        refresh()
    }

    /// One fetch at a time. The result lands on the period it was requested for, so
    /// switching periods mid-fetch never shows another period's numbers.
    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let requested = period
        entries[requested, default: Entry()].status = .loading
        Task {
            let result = await XPCHelperClient.shared.codeBurnStatus(period: requested.cliArg)
            apply(result, to: requested)
            inFlight = false
            if period != requested { refreshIfStale() }
        }
    }

    private func apply(_ result: Result<Data, CodeBurnFetchError>, to period: CodeBurnPeriod) {
        var entry = entries[period] ?? Entry()
        switch result {
        case .success(let data):
            if let payload = try? JSONDecoder().decode(CodeBurnPayload.self, from: data) {
                entry.payload = payload
                entry.fetchedAt = Date()
                entry.status = .idle
            } else {
                entry.status = .failed(.decode)
            }
        case .failure(let error):
            entry.status = .failed(error)
        }
        entries[period] = entry
    }
}
```

- [ ] **Step 5: Run the checks to verify they pass**

Run: `scripts/codeburn-check.sh`
Expected: `PayloadCheck OK`, `RunnerCheck OK`, `ManagerCheck OK`, exit 0.

- [ ] **Step 6: Register the file in the Xcode project**

```bash
python3 - <<'EOF'
p = "boringNotch.xcodeproj/project.pbxproj"
s = open(p).read()
def after(anchor, line):
    global s
    assert s.count(anchor) == 1, "anchor not unique: " + anchor
    s = s.replace(anchor, anchor + "\n" + line, 1)
after('14C08BB62C8DE42D000F8AA0 /* CalendarManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = 14C08BB52C8DE42D000F8AA0 /* CalendarManager.swift */; };',
      '\t\tCB0000000000000000000004 /* CodeBurnManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = CB0000000000000000000003 /* CodeBurnManager.swift */; };')
after('14C08BB52C8DE42D000F8AA0 /* CalendarManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CalendarManager.swift; sourceTree = "<group>"; };',
      '\t\tCB0000000000000000000003 /* CodeBurnManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CodeBurnManager.swift; sourceTree = "<group>"; };')
after('14C08BB52C8DE42D000F8AA0 /* CalendarManager.swift */,',
      '\t\t\t\tCB0000000000000000000003 /* CodeBurnManager.swift */,')
after('14C08BB62C8DE42D000F8AA0 /* CalendarManager.swift in Sources */,',
      '\t\t\t\tCB0000000000000000000004 /* CodeBurnManager.swift in Sources */,')
open(p, "w").write(s)
EOF
plutil -lint boringNotch.xcodeproj/project.pbxproj
```
Expected: `OK`.

- [ ] **Step 7: Build gate**

Run the build gate command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add boringNotch/managers/CodeBurnManager.swift scripts/codeburn-checks/ManagerCheck.swift scripts/codeburn-check.sh boringNotch.xcodeproj/project.pbxproj
git commit -m "feat(codeburn): add per-period CodeBurn manager

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: CodeBurn view and routing

**Files:**
- Create: `boringNotch/components/CodeBurn/CodeBurnView.swift`
- Modify: `boringNotch/enums/generic.swift` (`NotchViews`)
- Modify: `boringNotch/ContentView.swift:347-352` (view switch)
- Modify: `boringNotch/models/Constants.swift` (after the Shelf keys)
- Modify: `boringNotch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CodeBurnManager.shared`, `.current`, `.period`, `.refresh()`, `.refreshIfStale()` (Task 4); `CodeBurnPayload` display helpers (Task 1).
- Produces: `struct CodeBurnView: View`; `NotchViews.codeburn`; `Defaults.Keys.showCodeBurnTab: Key<Bool>` (default `false`).

- [ ] **Step 1: Add the enum case, key and route**

`boringNotch/enums/generic.swift` — replace:
```swift
public enum NotchViews {
    case home
    case shelf
}
```
with:
```swift
public enum NotchViews {
    case home
    case shelf
    case codeburn
}
```

`boringNotch/models/Constants.swift` — replace:
```swift
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
```
with:
```swift
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)

    // MARK: CodeBurn
    static let showCodeBurnTab = Key<Bool>("showCodeBurnTab", default: false)
```

`boringNotch/ContentView.swift` — replace:
```swift
                    case .shelf:
                        ShelfView()
                    }
```
with:
```swift
                    case .shelf:
                        ShelfView()
                    case .codeburn:
                        CodeBurnView()
                    }
```

- [ ] **Step 2: Write the view**

`boringNotch/components/CodeBurn/CodeBurnView.swift`:
```swift
//
//  CodeBurnView.swift
//  boringNotch
//
//  CodeBurn tab: AI coding spend from the locally installed `codeburn` CLI.
//

import SwiftUI

struct CodeBurnView: View {
    @ObservedObject var manager = CodeBurnManager.shared

    private struct Row: Identifiable {
        let id: String
        let name: String
        let cost: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .onAppear { manager.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(CodeBurnPeriod.allCases) { period in
                Button {
                    manager.period = period
                } label: {
                    Text(period.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(manager.period == period ? .white : .gray)
                }
                .buttonStyle(.plain)
            }
            if let label = manager.current.payload?.current.label {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let date = manager.current.payload?.generatedDate {
                Text(verbatim: CodeBurnPayload.ageText(since: date))
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            if manager.current.status == .loading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    manager.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let entry = manager.current
        if let payload = entry.payload {
            VStack(alignment: .leading, spacing: 4) {
                if payload.current.calls == 0 {
                    message("No usage in this period")
                } else {
                    columns(payload)
                        .opacity(payload.stale == true ? 0.5 : 1)
                }
                if case .failed(let error) = entry.status {
                    Text(refreshFailureText(error))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        } else {
            switch entry.status {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(.notInstalled):
                VStack(alignment: .leading, spacing: 4) {
                    message("CodeBurn CLI not found")
                    Text(verbatim: "brew install codeburn  ·  npm i -g codeburn")
                        .font(.caption.monospaced())
                        .foregroundStyle(.gray)
                }
            case .failed(.decode):
                message("Unexpected CodeBurn output (CLI version?)")
            case .failed:
                message("Couldn't load CodeBurn data")
            }
        }
    }

    private func columns(_ payload: CodeBurnPayload) -> some View {
        let current = payload.current
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: payload.formatCost(current.cost))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                stat("\(current.calls) calls")
                stat("\(payload.sessionsText) sessions")
                stat("\(Int(current.cacheHitPercent.rounded()))% cache")
                if let live = payload.liveSessions {
                    stat("● \(live.count) active ≤10m")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            list("MODELS",
                 rows: payload.pricedModels.prefix(4).map { Row(id: $0.name, name: $0.name, cost: payload.formatCost($0.cost)) },
                 footer: current.unpricedModelCount > 0 ? "+\(current.unpricedModelCount) unpriced" : nil)
            list("PROJECTS",
                 rows: current.topProjects.prefix(4).map { Row(id: $0.rowID, name: $0.name, cost: payload.formatCost($0.cost)) },
                 footer: nil)
        }
    }

    private func list(_ title: LocalizedStringKey, rows: [Row], footer: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.gray)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: row.cost)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.white)
            }
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.gray)
            .lineLimit(1)
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.gray)
    }

    private func refreshFailureText(_ error: CodeBurnFetchError) -> LocalizedStringKey {
        switch error {
        case .decode: return "Unexpected CodeBurn output (CLI version?)"
        case .notInstalled: return "CodeBurn CLI not found"
        default: return "Couldn't refresh CodeBurn"
        }
    }
}
```

- [ ] **Step 3: Register the file and a `CodeBurn` group in the Xcode project**

```bash
python3 - <<'EOF'
p = "boringNotch.xcodeproj/project.pbxproj"
s = open(p).read()
def after(anchor, line):
    global s
    assert s.count(anchor) == 1, "anchor not unique: " + anchor
    s = s.replace(anchor, anchor + "\n" + line, 1)
after('9A0887322C7A693000C160EA /* TabButton.swift in Sources */ = {isa = PBXBuildFile; fileRef = 9A0887312C7A693000C160EA /* TabButton.swift */; };',
      '\t\tCB0000000000000000000006 /* CodeBurnView.swift in Sources */ = {isa = PBXBuildFile; fileRef = CB0000000000000000000005 /* CodeBurnView.swift */; };')
after('9A0887312C7A693000C160EA /* TabButton.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TabButton.swift; sourceTree = "<group>"; };',
      '\t\tCB0000000000000000000005 /* CodeBurnView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CodeBurnView.swift; sourceTree = "<group>"; };')
# New group under components
after('9A0887332C7AFF7E00C160EA /* Tabs */,',
      '\t\t\t\tCB0000000000000000000007 /* CodeBurn */,')
# CodeBurn group definition, placed just before the Tabs group definition
group = ('\t\tCB0000000000000000000007 /* CodeBurn */ = {\n'
         '\t\t\tisa = PBXGroup;\n'
         '\t\t\tchildren = (\n'
         '\t\t\t\tCB0000000000000000000005 /* CodeBurnView.swift */,\n'
         '\t\t\t);\n'
         '\t\t\tpath = CodeBurn;\n'
         '\t\t\tsourceTree = "<group>";\n'
         '\t\t};')
anchor = '\t\t9A0887332C7AFF7E00C160EA /* Tabs */ = {'
assert s.count(anchor) == 1
s = s.replace(anchor, group + '\n' + anchor, 1)
after('9A0887322C7A693000C160EA /* TabButton.swift in Sources */,',
      '\t\t\t\tCB0000000000000000000006 /* CodeBurnView.swift in Sources */,')
open(p, "w").write(s)
EOF
plutil -lint boringNotch.xcodeproj/project.pbxproj
grep -n 'CB000000000000000000000[5-7]' boringNotch.xcodeproj/project.pbxproj
```
Expected: `OK`; grep shows 6 lines: build file, file ref, group definition header, group child of `components`, file child in the CodeBurn group, Sources entry.

- [ ] **Step 4: Build gate**

Run the build gate command.
Expected: `** BUILD SUCCEEDED **`. A diff in `boringNotch/Localizable.xcstrings` from string extraction is expected; include it in the commit if the build produced it.

- [ ] **Step 5: Re-run standalone checks**

Run: `scripts/codeburn-check.sh`
Expected: all three `OK` lines.

- [ ] **Step 6: Commit**

```bash
git add boringNotch/components/CodeBurn/CodeBurnView.swift boringNotch/enums/generic.swift boringNotch/ContentView.swift boringNotch/models/Constants.swift boringNotch.xcodeproj/project.pbxproj
git add boringNotch/Localizable.xcstrings 2>/dev/null || true
git commit -m "feat(codeburn): add CodeBurn tab view

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Tab gating, header and settings toggle

**Files:**
- Modify: `boringNotch/components/Tabs/TabSelectionView.swift` (whole file)
- Modify: `boringNotch/components/Notch/BoringHeader.swift:11-20`
- Modify: `boringNotch/components/Settings/SettingsView.swift` (`Appearance`, around line 1160-1178)

**Interfaces:**
- Consumes: `NotchViews.codeburn`, `Defaults.Keys.showCodeBurnTab` (Task 5).
- Produces: `static func TabModel.visible(shelfEnabled: Bool, shelfEmpty: Bool, alwaysShowTabs: Bool, codeBurnEnabled: Bool) -> [TabModel]`.

- [ ] **Step 1: Rewrite TabSelectionView with per-tab gating and stable ids**

Replace the whole content of `boringNotch/components/Tabs/TabSelectionView.swift` with:
```swift
//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let label: String
    let icon: String
    let view: NotchViews

    // Stable across renders so ForEach and matchedGeometryEffect keep identity.
    var id: NotchViews { view }

    /// One gate per tab. The bar shows only when more than one tab is visible, which
    /// keeps the pre-CodeBurn behaviour when the CodeBurn tab is off.
    static func visible(shelfEnabled: Bool, shelfEmpty: Bool, alwaysShowTabs: Bool, codeBurnEnabled: Bool) -> [TabModel] {
        var tabs = [TabModel(label: "Home", icon: "house.fill", view: .home)]
        if shelfEnabled && (!shelfEmpty || alwaysShowTabs) {
            tabs.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }
        if codeBurnEnabled {
            tabs.append(TabModel(label: "CodeBurn", icon: "flame.fill", view: .codeburn))
        }
        return tabs
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.showCodeBurnTab) var showCodeBurnTab
    @Namespace var animation

    private var tabs: [TabModel] {
        TabModel.visible(shelfEnabled: boringShelf, shelfEmpty: tvm.isEmpty,
                         alwaysShowTabs: coordinator.alwaysShowTabs, codeBurnEnabled: showCodeBurnTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
```

- [ ] **Step 2: Gate the header on the visible tab count**

In `boringNotch/components/Notch/BoringHeader.swift`, replace:
```swift
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
```
with:
```swift
    @StateObject var tvm = ShelfStateViewModel.shared
    @Default(.boringShelf) var boringShelf
    @Default(.showCodeBurnTab) var showCodeBurnTab
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if TabModel.visible(shelfEnabled: boringShelf, shelfEmpty: tvm.isEmpty,
                                    alwaysShowTabs: coordinator.alwaysShowTabs,
                                    codeBurnEnabled: showCodeBurnTab).count > 1 {
```

- [ ] **Step 3: Add the settings toggle with Home fallback**

In `boringNotch/components/Settings/SettingsView.swift`, replace:
```swift
struct Appearance: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
```
with:
```swift
struct Appearance: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.showCodeBurnTab) var showCodeBurnTab
```
Then replace:
```swift
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
```
with:
```swift
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle(key: .showCodeBurnTab) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show CodeBurn tab")
                        Text("Runs your locally installed codeburn CLI to show AI coding spend. macOS may ask Boring Notch for access to other apps' data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: showCodeBurnTab) {
                    if !showCodeBurnTab && coordinator.currentView == .codeburn {
                        coordinator.currentView = .home
                    }
                }
```
Both anchors occur exactly once in the file (`let icons: [String] = ["logo2"]` occurs twice, so it is not used as an anchor).

- [ ] **Step 4: Build gate**

Run the build gate command.
Expected: `** BUILD SUCCEEDED **`, no new warnings in the three touched files.

- [ ] **Step 5: Commit**

```bash
git add boringNotch/components/Tabs/TabSelectionView.swift boringNotch/components/Notch/BoringHeader.swift boringNotch/components/Settings/SettingsView.swift
git add boringNotch/Localizable.xcstrings 2>/dev/null || true
git commit -m "feat(codeburn): gate tabs per tab and add CodeBurn setting

Header shows the tab bar when more than one tab is visible; with the
CodeBurn tab off the behaviour matches main.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Signed build and manual verification

**Files:** none changed (evidence only).

`CODE_SIGNING_ALLOWED=NO` skips codesign, so entitlements (the sandbox the design rests on) are not applied. This task builds signed.

- [ ] **Step 1: Run all standalone checks**

Run: `scripts/codeburn-check.sh; echo "exit=$?"`
Expected: `PayloadCheck OK`, `RunnerCheck OK`, `ManagerCheck OK`, `exit=0`. Save the output for the PR body.

- [ ] **Step 2: Signed build**

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd-signed" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build 2>&1 | tail -3
APP="$TMPDIR/boringnotch-dd-signed/Build/Products/Debug/Boring Notch.app"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A1 app-sandbox
codesign -d --entitlements - "$APP/Contents/XPCServices/BoringNotchXPCHelper.xpc" 2>/dev/null | grep -A1 app-sandbox
```
Expected: `** BUILD SUCCEEDED **`; app shows sandbox `true`, helper shows sandbox `false`. The product is `Boring Notch.app` (with a space), as in the baseline build.

- [ ] **Step 3: Launch**

Quit any running Boring Notch first (`osascript -e 'quit app "Boring Notch"'` and check `pgrep -fl "Boring Notch"` is empty), then `open "$APP"`.

- [ ] **Step 4: Manual matrix (human or computer-use), screenshot each**

| # | Action | Expected |
|---|---|---|
| 1 | Toggle off (default), open notch | Header/tab behaviour identical to `main` (Home + Shelf per the shelf settings) |
| 2 | Settings → Appearance → enable "Show CodeBurn tab"; open notch | Flame tab visible; select it; Today loads; hero cost equals `codeburn status --period today` in Terminal (`codeburn status --format menubar-json --period today --no-optimize \| python3 -c 'import json,sys;print(json.load(sys.stdin)["current"]["cost"])'`) |
| 3 | Click 7d, 30d, Month | Each loads; labels match `current.label`; switching during a load never shows another period's numbers |
| 4 | Click Month (cold) and press brightness keys while it loads | Brightness HUD responds immediately |
| 5 | Close and reopen notch within 5 min, CodeBurn tab | Cached data shows instantly; no spinner |
| 6 | Disable the toggle while CodeBurn tab is selected | Tab disappears, view returns to Home |
| 7 | Shelf disabled + CodeBurn enabled | Bar shows Home + CodeBurn only (no Shelf) |
| 8 | Not-installed state: temporarily `mv /opt/homebrew/bin/codeburn /opt/homebrew/bin/codeburn.bak`, press ↻, then restore with `mv /opt/homebrew/bin/codeburn.bak /opt/homebrew/bin/codeburn` | "CodeBurn CLI not found" + install hint (cached data, if any, keeps showing with the red line) |

Check helper logs during the run: `log show --last 5m --predicate 'subsystem == "theboringteam.boringnotch.BoringNotchXPCHelper"'`.

- [ ] **Step 5: Report**

Record results of Steps 1–4 (command output, screenshots, any failures). Do not claim a row passed without its evidence. Then hand off to superpowers:finishing-a-development-branch.

---

## Self-Review Notes

- Dry run (2026-09-29): every code block and edit in this plan was applied to a throwaway worktree of `aa858eb`. `scripts/codeburn-check.sh` printed `PayloadCheck OK`, `RunnerCheck OK`, `ManagerCheck OK`; the unsigned Debug build succeeded (57 → 60 warnings: +2 wrapper Sendable warnings, +1 build noise in an untouched file). Two plan bugs found and fixed by that run: pipes released before the child wrote (SIGPIPE), and a fake CLI named `env` that recursed through PATH.

- Spec coverage: data source + fixed command (Tasks 2–3); sandbox/XPC (Tasks 2–3); security allowlists, TCC note in settings text, stderr to os_log (Tasks 2, 6); non-blocking helper, exactly-once reply, process group, busy, cap (Task 2); model fields incl. stale, sessionCountBasis, unpriced, id, liveSessions-absent (Task 1); per-period state and race (Task 4); view states table and layout (Task 5); wiring, default OFF, fallback to Home, pbxproj, localization (Tasks 5–6); testing and success criteria (Tasks 1, 2, 4, 7).
- Deliberate refinements of the spec: "exactly one reply" is enforced by a single reply site in the `DispatchGroup.notify` rather than a flag; the timeout reply is sent after the process group has exited (at most ~2s after the timeout), which also guarantees the busy flag is released before the reply.
- Known limitations carried from the spec: nvm/bun/pnpm installs are not discovered; shell-only env vars (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) are not seen; the "Xm ago" label updates when the view re-renders, not on a timer.
