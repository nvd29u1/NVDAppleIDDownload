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
- Deliberate exception: the built-in local install server still uses the
  hostname `app.localhost.qaq.wiki` and its bundled TLS certificates. That
  hostname is a functional DNS identity (it resolves via the author's DNS);
  renaming it would break the local installer, and the default install path
  (NVD manifest worker) does not use it at all.
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
