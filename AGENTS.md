# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Note**: `CLAUDE.md` is a symlink to `AGENTS.md`. Edit `AGENTS.md` directly.

## Project Overview

NVDAppleIDDownload (nvd29u1, based on Asspp 4.2.2 by Lakr233, MIT) is a multi-account App Store management app (iOS + macOS) for searching, downloading, and installing IPA files. It uses an Xcode workspace (`Asspp.xcworkspace`) with SPM dependencies including [ApplePackage](https://github.com/Lakr233/ApplePackage), the core library for App Store API communication, IPA handling, and signature injection.

Bundle ID: `com.NVD.appleiddownload` (upstream Asspp used `wiki.qaq.Asspp`). Deployment targets: iOS 17.0, macOS 15.0. Supports iPhone, iPad, and Mac (native, not Catalyst). No test targets exist.

## Build Commands

```bash
# Build for iOS (device)
xcodebuild -workspace Asspp.xcworkspace -scheme NVDAppleIDDownload -configuration Debug -destination 'generic/platform=iOS' build | xcbeautify

# Build for macOS
xcodebuild -workspace Asspp.xcworkspace -scheme NVDAppleIDDownload -configuration Debug -destination 'platform=macOS' build | xcbeautify

# Build for iOS simulator
xcodebuild -workspace Asspp.xcworkspace -scheme NVDAppleIDDownload -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build | xcbeautify

# CI release build (iOS IPA, unsigned)
./Resources/Scripts/compile.release.mobile.ci.sh "$(pwd)" "$(pwd)/NVDAppleIDDownload.ipa"

# CI release build (macOS zip)
./Resources/Scripts/compile.release.osx.sh "$(pwd)" "$(pwd)/NVDAppleIDDownload.zip"
```

**Important**: Always use `Asspp.xcworkspace` (not `.xcodeproj`) because the workspace manages SPM package resolution. Always pipe xcodebuild output through `xcbeautify` to reduce output verbosity and save tokens.

## Code Signing Setup

`Configuration/Developer.xcconfig` is gitignored and must exist for builds. It provides code signing settings:

```
DEVELOPMENT_TEAM = <your team ID>
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

A build phase script errors if this file is missing. The CI scripts generate a no-signing version automatically.

## Build Configuration

xcconfig hierarchy: `Debug.xcconfig`/`Release.xcconfig` → `Base.xcconfig` → `Version.xcconfig`, plus `Developer.xcconfig` for signing. Version numbers are in `Configuration/Version.xcconfig` (single source of truth).

## Architecture

### App Entry Point

`NVDAppleIDDownload/App/main.swift` — initializes logging (`LogManagerHandler`), configures `ApplePackage` device identifier, sets up `Digger` download manager (max 3 concurrent), and starts the OTA installer on iOS. On iOS 26+, the main view switches to `NewMainView` (new `Tab` API); otherwise `MainView` is used.

### Backend Layer (`NVDAppleIDDownload/Backend/`)

- **AppStore/**: `AppStore` singleton manages accounts and device identifier. `AuthenticationService` handles auth using ApplePackage's SAP-signed authenticator; `AddAccountView` retains the authenticator across verification-code attempts. `AppPackage`/`AppPackageArchive`/`UserAccount` are model wrappers around ApplePackage types.
- **Downloader/**: `Downloads` singleton manages download queue via `Digger`. `PackageManifest` tracks per-download state and IPA signature injection. Downloads persist to `Documents/NVDAppleIDDownload/Packages/`.
- **Installer/**: iOS-only Vapor server serving IPA files for OTA installation via `itms-services://` protocol. Default install path uses the NVD manifest worker (see `AppStore.manifestServerURL`) for the manifest plist while the IPA is served locally over HTTP on 127.0.0.1; with an empty manifest server URL it falls back to the built-in HTTPS server using TLS certs from `Certificates/localhost.qaq.wiki/` bundle.
- **DeviceCTL/**: macOS-only device management via `devicectl` CLI. `DeviceManager` handles app installation to connected iOS devices.
- **LogManager.swift**: Thread-safe log singleton feeding `Settings/LogView`.

### Interface Layer (`NVDAppleIDDownload/Interface/`)

SwiftUI views organized by feature: Account, Search, Download, Installed (macOS only), Setting, Welcome. `MainView` uses `NavigationSplitView` sidebar on macOS and `TabView` on iOS.

NVD theme: plum accent color (`AccentColor`), plum gradient welcome screen with the green NVD pig logo (`PigLogo` image set). Forms keep the system background for readability.

### Key Patterns

- **Observation**: `AppStore`, `Downloads`, `Installer`, `DeviceManager`, `PackageManifest` all use `@Observable` (not legacy `ObservableObject`).
- **Persistence**: Custom `@PublishedPersist` / `@Persist` property wrappers (in `Extension/PublishedPersist.swift`) back properties to file storage (`Documents/Config/`) or Keychain. Accounts stored in Keychain; downloads and settings use file storage.
- **Platform branching**: Heavy use of `#if os(macOS)` / `#if os(iOS)` / `#if canImport(UIKit)` for platform-specific code paths.
- **Singletons**: `AppStore.this`, `Downloads.this` are `@MainActor` singletons.
- **Localization**: Vietnamese (vi) is the primary UI language, plus English and Simplified Chinese (zh-Hans) via `.xcstrings` format in `NVDAppleIDDownload/App/` .

## Dependencies (SPM via Xcode)

- **ApplePackage** (remote) — App Store protocol, IPA handling
- **Vapor** — HTTPS server for iOS OTA installation
- **Digger** — Download manager with progress/speed tracking
- **Kingfisher** — Async image loading
- **ColorfulX** — Gradient animations (welcome screen)
- **KeychainAccess** — Keychain storage for accounts
- **AnyCodable** — Type-erased Codable values
- **ButtonKit** — Async button actions
- **swift-log** — Structured logging (`logger` global)

## Swift Code Style

- **Indentation**: 4 spaces. Opening brace on same line.
- **Naming**: PascalCase for types, camelCase for properties/methods. PascalCase filenames for types, `+` prefix for extension files.
- **Structure**: Early returns, guard statements for unwrapping, single responsibility per extension.
- **Modern Swift**: `@Observable` macro, `async/await`, `@MainActor`, opaque `some` types.
- **Memory**: `weak`/`unowned` references to break cycles, capture lists in closures.

## NVD personalization notes (Nov 2026)

- Full rename from upstream Asspp: target/product/executable are
  `NVDAppleIDDownload`, source folder `NVDAppleIDDownload/`, bundle ID
  `com.NVD.appleiddownload`, logger labels `com.NVD.appleiddownload*`,
  keychain service `com.NVD.appleiddownload.*`, entitlements keychain group
  `com.NVD.appleiddownload`. App icons (AppIcon.appiconset + the Xcode 26
  `AppIcon.icon` layered icon) and the Avatar asset are the green pig logo.
- Local install certificates (1.2, Nov 2026): the bundled TLS
  certificates were regenerated under NVD — CA subject
  "O = NVD, CN = NVD Local Installation CA" (SHA256 fingerprint
  37:BD:D2:D8:03:2E:84:F0:15:A6:0D:F3:51:D6:86:81:A4:AA:2A:8D:9B:00:BB:63:69:99:3C:05:0F:C3:65:A0,
  valid to 21 Nov 2036), leaf re-issued for `localhost.qaq.wiki` (1 year).
  The hostname `app.localhost.qaq.wiki` itself is unchanged — it is a
  functional DNS identity (it resolves via the author's DNS); renaming it
  would break the local installer. The CA private key is NOT in the repo
  (only rootCA.pem + leaf cert/key are bundled, same as upstream). The
  default install path (NVD manifest worker) does not use these
  certificates at all — they are only needed when the manifest server URL
  is left empty (local install).
- The Digger download library (SPM) still contains its own internal queue
  labels `wiki.qaq.diggerThread.*` inside the binary; they are not app
  branding and cannot be changed without forking Digger.
- Login `HTTP 204`: Apple returns an empty response from the MZFinance
  authenticate endpoint before judging credentials (ApplePackage
  `Authenticate.swift:276`, `guard response.status == .ok`). Since 6 Nov
  2026 Apple gates sign-in on Anisette/ADI device verification, which
  ApplePackage 2.0.3 does not do; there is no newer ApplePackage and
  upstream Asspp was archived 18 Nov 2026. `AuthenticationService`
  retries transient HTTP 204/403/404/5xx up to 3 times with a fresh
  Authenticator and otherwise shows a plain Vietnamese explanation instead
  of the bare error. Implementing Anisette provisioning would be a large
  lift with licence problems (GPL Unicorn + Apple binaries) and is not done.
- Login "failed to retrieve redirect location" (24 Nov 2026): same family
  as the 204 — ApplePackage `Authenticate.swift` `parseResponse` returns
  this when Apple answers the authenticate endpoint with a redirect status
  (301/302/303/307/308) but no usable `Location` header (or the resolve
  step cannot resolve it). The legacy endpoint is supposed to 302 to a pod
  URL (ipatool #513); a destination-less redirect means Apple refused the
  request before judging the account. Not a wrong-password verdict: a bad
  password or unknown account comes back as HTTP 200 + plist. The app now
  retries this like the 204 and shows a Vietnamese explanation. Separate
  from the server refusal, always check the typed email first — the
  account that worked on PC is kithuatscn@gmail.com, not "gamil.com".
- Anisette research (24 Nov 2026, full write-up in
  `docs/ANISETTE-RESEARCH.md`): porting ipatool 2.8.0's
  local Anisette to this iOS app is NOT feasible in scope — ipatool
  downloads an 11 GB macOS 27 IPSW, extracts 7 pinned Apple binaries, and
  runs 4 emulated machines (Unicorn) to do ADI provisioning + OTP; iOS has
  no JIT, ApplePackage 2.0.3 has no header-injection point, and the Apple
  binaries can't be redistributed in the IPA. AnisetteKit (Swift, AGPLv3,
  7 stars, no releases) needs Apple .so files the user must supply and is
  unproven against Apple's Nov 2026 otp/1.5 gate. Working alternative
  today: ipatool 2.8.1 on PC.
- Anisette, app side (24 Nov 2026, 4.2.2 build 3): fork
  `nvd29u1/ApplePackage` (tag `nvd-anisette-1`, commit `3d320cf`) adds
  public `Authenticator.anisetteHeaders: [String: String]` (empty by
  default, old behaviour unchanged); `makeRequest()` attaches them before
  the SAP signature, so authenticate + 2FA requests carry them. Fork
  commit `2e0bb95` (24 Nov 2026) fixes two compile errors in that change
  (`[:]` dictionary default, `await` on the actor property assignment);
  app SPM pin updated to `2e0bb95`. Fork commit `9dc423a` (24 Nov 2026)
  fixes the remaining Swift 6 error — actor-isolated state cannot be
  mutated from a nonisolated context even with `await`, so the fork adds
  `setAnisetteHeaders(_:)` (called from the fork's static `authenticate`
  and from the app's `AuthenticationService`, which had the same two
  assignments); app SPM pin updated to `9dc423a`. CI build-ios then
  succeeded (run 45370647254, 4.2.2 build 3). App SPM
  pin moved to the fork (revision pin). Settings → "Máy chủ Anisette":
  user-typed server URL (default empty = off, stored in
  `AppStore.anisetteServerURL`), "Kiểm tra" button GETs the server and
  reports OK/error in Vietnamese. Before sign-in
  (`AuthenticationService.authenticate`, retry 3 kept), the app GETs
  header JSON from the server (10 s timeout, any header keys accepted)
  and sets `authenticator.anisetteHeaders`; a failed fetch stops sign-in
  with a Vietnamese explanation instead of signing in header-less.
  `NSAppTransportSecurity_NSAllowsLocalNetworking = YES` (iOS configs)
  so cleartext HTTP to the LAN server is allowed; the Apple ID password
  is never sent to the Anisette server. Real sign-in through a server is
  NOT yet verified on a real iPhone — needs the user's own test with a
  secondary Apple ID.
- IPA export (24 Nov 2026, 4.2.2 build 4): downloaded IPAs live at
  `Documents/NVDAppleIDDownload/Packages/<bundleID>/<version>/<uuid>.ipa`
  (`PackageManifest.targetLocation`). New "Tải IPA về máy" button
  (`ExportIPAButton` + `IPAExport` in `Extension/IPAExport.swift`): copies
  the file untouched to the temp dir as `<bundleID>-<version>.ipa` and opens
  the iOS/macOS Share Sheet via the existing `AirDrop()` helper (Save to
  Files / AirDrop / other apps). Shown on each completed row in the
  Downloads tab and on the package detail view (iOS Control section,
  macOS Control section), plus as a context-menu action for completed
  downloads. Disabled/hidden when the download is not completed or the
  file is gone; a failed Share Sheet shows a Vietnamese alert instead of
  crashing. No decryption, no bundle rename, no new download source.
- Version-history auth fix (24 Nov 2026, 4.2.2 build 4): choosing an old
  version in Version History showed "AuthenticationError 0" — that is the
  app's own `AppStore.AuthenticationError.accountNotFound` (a 1-case enum
  with no message, so NSError printed "error 0"), thrown by `withAccount`
  when the selected account id no longer exists in the app (e.g. signed
  out and back in with a different Apple ID while the detail screen kept
  the old id). Fix: `AppStore.AuthenticationError` now has a Vietnamese
  `LocalizedError` description; `AppPackageArchive.resolvedAccountID()`
  prefers the selected id but falls back to the first still-signed-in
  account for the region (same logged-in session: saved cookies +
  passwordToken, no new authenticator); `ProductView` re-syncs its
  account picker when the accounts list changes; `StoreDownloadService`
  retries transient store errors (empty 204/403/404/5xx, invalid
  redirect, catalog unavailable) up to 3 times with 2 s pauses, like
  `AuthenticationService` does for sign-in. Real verdicts (invalid
  package, license required, rejected by code) are not retried.
- Add to Purchased (24 Nov 2026, 4.2.2 build 4): free apps now have a
  "Nhập vào Đã mua" button on the app detail screen (Download section),
  using the existing `ApplePackage.Purchase.purchase` (free-only, same as
  ipatool's purchase / Asspp "Free App Purchase"): obtains the license so
  the app lands in that Apple ID's Purchased list, downloads no IPA.
  Success/failure is reported in Vietnamese. Paid apps cannot use it
  (ApplePackage refuses paid apps). There is no in-app Purchased list
  view — the list lives in Apple's own Purchased list. The older
  "Acquire License" button in Pricing still exists and now reports the
  same Vietnamese success message.
- Direct Download name search (24 Nov 2026, 4.2.2 build 4): `AddDownloadView`
  has a "Tìm theo tên app" section above the Bundle ID field — type an app
  name (or Bundle ID), tap "Tìm" to search via `ApplePackage.Searcher.search`
  (+ `Lookup` fallback, exact Bundle ID first, limit 20) using the selected
  account's store countryCode; tap a result (icon, name, version, developer,
  bundle ID) to auto-fill the Bundle ID below. Search runs only on tap/submit,
  never per keystroke. Manual Bundle ID entry is unchanged for apps that left
  the App Store. 4 new Vietnamese strings (208 total in `Localizable.xcstrings`).
- BorderBeam glow (24 Nov 2026, 4.2.2 build 4): BorderBeam (ismnoiet,
  MIT, iOS 17+/macOS 14+) is VENDORED into the app target — same 4 files as
  NVDsign (`Extension/BorderBeam/`: `BorderBeam.swift`, `BorderBeamModifier.swift`,
  `BeamConfiguration.swift`, `BorderBeam.metal`, MIT headers kept, `Bundle.main`
  for the Metal library) — NOT an SPM dependency, so no package resolution in
  CI. `nvdBorderBeam(shape:)` (plum palette #7A2048 + pale highlight) wraps
  `.borderBeam` inside `#available(iOS 17, *)` / `#available(macOS 14, *)`
  per platform; deployment target is iOS 17.0 / macOS 15.0 so the guard is
  belt-and-braces. Applied (overlay only, no layout change, one cheap GPU pass
  per beam, timeline pauses when idle / under Reduce Motion) to: the "Tải IPA
  về máy" button (shared `ExportIPAButton` — Downloads rows + package detail),
  the "Request Download" and "Nhập vào Đã mua" buttons on the app detail
  screen, the "Tìm" and "Request Download" buttons on Direct Download, and
  the pig logo card on the Home tab. The Home tab has no other main button.
