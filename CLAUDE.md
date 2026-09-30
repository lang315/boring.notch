# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Boring Notch is a macOS 14+ SwiftUI/AppKit app that turns the MacBook notch into an expandable panel: music controls and visualizer, calendar, file shelf with AirDrop, HUD replacements, webcam mirror, and an opt-in CodeBurn (AI spend) tab. Building needs Xcode 26+ (README).

## Commands

There is no XCTest target and no linter config. Use a full build as the compile check.

```sh
# Resolve Swift packages. A fresh derived-data dir can hang here; copying SourcePackages from an existing one works around it.
xcodebuild -resolvePackageDependencies -project boringNotch.xcodeproj

# Unsigned Debug build: compile check only
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd" \
  CODE_SIGNING_ALLOWED=NO build

# Ad-hoc signed Debug build: needed to actually run it (applies entitlements: sandboxed app + unsandboxed XPC helper)
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd-signed" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open "$TMPDIR/boringnotch-dd-signed/Build/Products/Debug/Boring Notch.app"   # product name has a space

# Ad-hoc signed Release build to install locally. Release enables the hardened runtime, and with an
# ad-hoc signature library validation then refuses the embedded MediaRemoteAdapter.framework
# ("different Team IDs" at launch), so turn it off for local installs only.
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/boringnotch-dd-signed" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build
ditto "$TMPDIR/boringnotch-dd-signed/Build/Products/Release/Boring Notch.app" "/Applications/Boring Notch.app"

# Verify the privilege split: app-sandbox should be true for the app and false for the helper
codesign -d --entitlements - "<app>"
codesign -d --entitlements - "<app>/Contents/XPCServices/BoringNotchXPCHelper.xpc"

# CodeBurn standalone checks (swiftc programs, not XCTest)
scripts/codeburn-check.sh

# CI release-script tests (Python unittest)
python3 -m unittest discover -s .github/scripts/tests
```

To run a single CodeBurn check, compile one pair the same way `scripts/codeburn-check.sh` does, e.g. `swiftc -parse-as-library -o /tmp/p scripts/codeburn-checks/Check.swift scripts/codeburn-checks/PayloadCheck.swift boringNotch/models/CodeBurnPayload.swift && /tmp/p scripts/codeburn-checks`. Each check program is compiled together with the production source files it tests, so those files must not depend on app-only types.

## Architecture

**Windows and view models.** `boringNotchApp.swift` (`AppDelegate`) creates the notch window as a borderless `BoringNotchSkyLightWindow` panel. SkyLight is only enabled while the screen is locked. With `Defaults[.showOnAllDisplays]` it creates one window and one `BoringViewModel` per display, keyed by display UUID (`NSScreen+UUID.swift`), and rebuilds them when the screen configuration changes. Otherwise it creates a single window on the selected screen.
- `BoringViewModel` holds per-window state: open/closed, notch size, drop targeting.
- `BoringViewCoordinator.shared` (`@MainActor`) holds global UI state: `currentView: NotchViews`, sneak-peek/HUD presentation, first-launch flags.

**Views.** `ContentView.swift` draws the notch shape and routes the open notch body on `coordinator.currentView`: `.home` → `NotchHomeView`, `.shelf` → `ShelfView`, `.codeburn` → `CodeBurnView`. Tab visibility is decided in one place, `TabModel.visible(...)` in `components/Tabs/TabSelectionView.swift`, which is shared by the tab bar and by `BoringHeader`. Adding a tab means adding a `NotchViews` case, a `ContentView` route, and a `visible(...)` rule. Open-notch geometry (640×190) and closed-notch sizing live in `sizing/matters.swift`.

**Settings.** All preferences are `Defaults` keys in `models/Constants.swift`. Views read them with `@Default(.key)` so they re-render on change; reading `Defaults[.key]` inside a view body does not observe changes. The Settings UI is `components/Settings/SettingsView.swift`, one struct per pane.

**Managers.** Managers are `.shared` singletons in `managers/`: music, volume, brightness, battery, calendar, webcam, CodeBurn.
- `MusicManager` picks a `MediaControllerProtocol` implementation from `Defaults[.mediaController]`. The implementations are in `MediaControllers/`: NowPlaying, Apple Music, Spotify, YouTube Music.
- NowPlaying runs the bundled `mediaremote-adapter/` Perl script and private framework, because MediaRemote is private API.

**Sandbox / XPC split.** The main app is sandboxed (`boringNotch/boringNotch.entitlements`). Anything needing privileges goes through the unsandboxed XPC service `BoringNotchXPCHelper/`:
- accessibility authorization;
- keyboard and screen brightness (CoreBrightness);
- spawning the `codeburn` CLI (`CodeBurnRunner`: `posix_spawn` in its own process group, env allowlist, timeout, output cap, one run at a time).

The app calls it via `XPCHelperClient.shared`, which wraps `AsyncXPCConnection`. `BoringNotchXPCHelperProtocol.swift` exists twice, in `BoringNotchXPCHelper/` and in `boringNotch/XPCHelperClient/`, and the two copies must stay identical. A new helper call needs:
1. the method in both protocol copies;
2. the `@objc` implementation in `BoringNotchXPCHelper.swift`;
3. a `nonisolated async` wrapper in `XPCHelperClient.swift`.

Helper methods must not block, because brightness calls share the connection.

**Key packages:** Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, Sparkle (updates, `updater/appcast.xml`), SkyLightWindow, Lottie, Pow, MacroVisionKit, swiftui-introspect, AsyncXPCConnection.

## Project file gotchas

- The app target uses classic Xcode groups. A new file under `boringNotch/` must be added to `boringNotch.xcodeproj/project.pbxproj` by hand: PBXFileReference, PBXBuildFile, group membership and Sources phase. Only `BoringNotchXPCHelper/` and `boringNotch/private/` are synchronized folders, where files are picked up automatically.
- Version and build number are stamped by CI (`.github/scripts/stamp_version.py`). Don't hand-edit them for releases.

## Localization

Strings live in `boringNotch/Localizable.xcstrings`.
- New `LocalizedStringKey` strings are added to the catalog only by an Xcode IDE build, not by command-line `xcodebuild`.
- Translations come from Crowdin. Upstream PRs must not change translations, only add source strings.

## Contributing / remotes

- `origin` is the fork `lang315/boring.notch`; `upstream` is `TheBoredTeam/boring.notch`.
- Upstream rules (CONTRIBUTING.md, `.github/PULL_REQUEST.md`):
  - code PRs target the `dev` branch, not `main`; documentation PRs target `main`;
  - UI changes need screenshots or recordings.
- Don't open PRs against upstream without asking.
- Never commit `example/`, `.memsearch/` or `.superpowers/`. These are local scratch folders.
- Design specs and plans for features built with the superpowers workflow are in `docs/superpowers/`.
