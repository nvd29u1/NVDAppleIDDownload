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

xcconfig hierarchy: `Debug.xcconfig`/`Release.xcconfig` → `Base.xcconfig` → `Version.xcconfig`, plus `Developer.xcconfig` for signing. Version numbers live in `Configuration/Version.xcconfig` — BUT `MARKETING_VERSION` is also pinned in `Asspp.xcodeproj/project.pbxproj` (target Debug + Release build settings), and the pbxproj value overrides the xcconfig, so a version bump must change BOTH places or the built app keeps the old version. `CURRENT_PROJECT_VERSION` (build number) lives only in `Version.xcconfig`. From build 5 the app uses its own version **2.0** (build stays 5, no reset — the CI scripts never touch version numbers) instead of upstream Asspp 4.2.2; the About section in Settings shows "`<MARKETING_VERSION> <build>`" (e.g. "2.0 5") from `Bundle.main` info dictionary (`main.swift`, `SettingView`). **Quy tắc version (anh chốt 25/11): dòng gộp 2.0 dừng ở build 19, xong đến 2.1 (MARKETING_VERSION 2.0 → 2.1, đổi ở cả `Version.xcconfig` và pbxproj như mọi lần đổi MARKETING_VERSION).**

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

SwiftUI views organized by feature: Account, Search, Download, Installed (macOS only), Setting, Sign (iOS only, merged from NVDsign in build 10). `MainView` uses `NavigationSplitView` sidebar on macOS and `TabView` on iOS.

NVD theme: plum accent color (`AccentColor`), plum gradient welcome screen with the green NVD pig logo (`PigLogo` image set). Forms keep the system background for readability.

### Key Patterns

- **Observation**: từ build 17, các class dùng `ObservableObject` + `@Published` (đã bỏ `@Observable` để chạy được iOS 16.0 — xem notes build 17). Ngoại lệ duy nhất: `DeviceManager` (chỉ macOS, min 15.0) vẫn giữ `@Observable`.
- **Persistence**: Custom `@PublishedPersist` / `@Persist` property wrappers (in `Extension/PublishedPersist.swift`) back properties to file storage (`Documents/Config/`) or Keychain. Accounts stored in Keychain; downloads and settings use file storage.
- **Platform branching**: Heavy use of `#if os(macOS)` / `#if os(iOS)` / `#if canImport(UIKit)` for platform-specific code paths.
- **Singletons**: `AppStore.this`, `Downloads.this` are `@MainActor` singletons.
- **Localization**: Vietnamese (vi) is the primary UI language, plus English and Simplified Chinese (zh-Hans) via `.xcstrings` format in `NVDAppleIDDownload/App/` .

## Dependencies (SPM via Xcode)

- **ApplePackage** (remote) — App Store protocol, IPA handling
- **Vapor** — HTTPS server for iOS OTA installation
- **Digger** — Download manager with progress/speed tracking
- **Kingfisher** — Async image loading
- **ColorfulX** — Gradient animations (welcome screen). ĐÃ GỠ ở build 17 (dead dep, 0 usage từ khi tab Welcome bị xoá ở build 10).
- **LookInsideServer** — ĐÃ GỠ ở build 17 (dead dep, 0 usage; binary target, min OS chưa xác minh).
- **KeychainAccess** — Keychain storage for accounts
- **AnyCodable** — Type-erased Codable values
- **ButtonKit** — Async button actions
- **swift-log** — Structured logging (`logger` global)

## Swift Code Style

- **Indentation**: 4 spaces. Opening brace on same line.
- **Naming**: PascalCase for types, camelCase for properties/methods. PascalCase filenames for types, `+` prefix for extension files.
- **Structure**: Early returns, guard statements for unwrapping, single responsibility per extension.
- **Modern Swift**: `ObservableObject` + `@Published` (từ build 17; trước đó dùng `@Observable` macro), `async/await`, `@MainActor`, opaque `some` types.
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
- Region fallback (25 Nov 2026, 2.0 build 5): the detail screen
  (`ProductView`) used to list only accounts whose store region matched
  the package region (`eligibleAccounts`), so with a VN package and only
  an IN account signed in the Account picker was empty and "Request
  Download" / "Nhập vào Đã mua" were disabled — confirmed on a real
  iPhone 24 Nov 2026 (Facebook, VN region, only kumit.95bt@gmail.com /
  IN signed in). Fix: the picker now lists every signed-in account
  (matching region first, others after, each labelled with its region
  code, other-region rows marked "khác vùng"); with no matching-region
  account it auto-selects the first signed-in account and shows an
  orange Vietnamese warning "Tài khoản này vùng %@, gói đang xem vùng
  %@ — có thể tải không được, hãy thêm tài khoản vùng %@ hoặc đổi vùng
  tìm kiếm."; the two buttons are disabled only when no account at all
  is signed in (the red "no account" error now shows only then, in
  Vietnamese). `AppPackageArchive.resolvedAccountID()` falls back the
  same way (matching region first, then any signed-in account) so
  Version History also opens instead of erroring. 5 new Vietnamese
  strings (213 total in `Localizable.xcstrings`). The download itself
  may still fail server-side for a cross-region account — the warning
  says so; the fix only stops the dead picker/buttons.
- Cross-region "Add to Purchased" (25 Nov 2026, still 2.0 build 5):
  checked ApplePackage `Purchase.purchase(account:app:)` (fork pin
  9dc423a) — it takes NO region parameter; the buyProduct request sends
  `X-Apple-Store-Front: <account.store>-1`, i.e. the account's own
  registered country from login, and Apple's server validates the
  account against that storefront (failureType 2059 "unavailable in
  this storefront" / 1010 "invalid store"). So one account CANNOT buy a
  license in another region — an Apple-side limit, not an app bug — and
  the app does NOT spoof the storefront (mutating the saved account's
  `store` would also corrupt it, since `withAccount` persists changes).
  What build 5 does instead: the button stays enabled when mismatched
  (it can still succeed when the app exists in both stores, e.g.
  Facebook in the IN store for an IN account), a Vietnamese note under
  the button explains Apple only allows Purchased in the account's own
  region and to add an account for the app's region in the Accounts
  tab, and a region refusal from Apple (failureType 2059/1010) is
  translated to a Vietnamese error telling the user to add an account
  for that region. 2 more Vietnamese strings (215 total).
- Own version 2.0 (25 Nov 2026, 2.0 build 5): `MARKETING_VERSION`
  4.2.2 → 2.0, build stays 5 (no reset — nothing in the repo's build
  process forces a reset; `compile.release.mobile.ci.sh` never touches
  version numbers). Changed in both `Configuration/Version.xcconfig`
  AND `Asspp.xcodeproj/project.pbxproj` (target Debug + Release): the
  pbxproj pins `MARKETING_VERSION` and overrides the xcconfig, so
  changing the xcconfig alone would have shipped 4.2.2 again. Welcome
  screen / startup log show the version automatically from the bundle
  (`main.swift` `version` = short version + build, e.g. "2.0 5").
- Đợt 1 build 6 (25 Nov 2026, 2.0 build 6): 2 mục dễ nhất từ
  `docs/IPADN-SO-SANH.md` (mục 2 + 5) + fix lỗi mua thật gặp sáng
  25/11. Học ý tưởng iPadn rồi viết lại sạch, KHÔNG copy code iPadn
  (GPL-2.0), giữ MIT.
  - Chẩn đoán lệch vùng + nút "Đổi tài khoản rồi thử lại" (mục 2):
    `ProductView` chỉ chẩn đoán SAU khi lỗi thật — tải hoặc nhập vào Đã
    mua thất bại với failureType 2059/1010/-128 thì hiện popup tiếng
    Việt nêu đúng vùng tài khoản / vùng gói + 2 nút: [Đổi sang tài khoản
    vùng Y và thử lại] (có tài khoản đúng vùng đã đăng nhập thì tự đổi
    picker sang nó rồi chạy lại đúng thao tác 1 lần, không mở popup nữa;
    chưa có thì hiện hướng dẫn thêm tài khoản vùng Y ở tab Tài khoản —
    màn này không có đường chuyển tab bằng code nên nút "mở màn chọn tài
    khoản" thực chất là quay lại picker ngay trên màn chi tiết) và [Đổi
    tài khoản] (đóng popup, tự chọn bằng picker). Không chặn trước khi
    tải — cảnh báo cam build 5 vẫn hiện trước, popup chỉ sau lỗi thật.
    Lỗi -128 (`StoreDownloadService`, có `region` của gói luồn từ
    `ProductView`/`AppPackageArchive`/`Downloads.startDownload` xuống):
    tự chỉnh `store` sang vùng của gói trong BẢN SAO của tài khoản rồi
    retry 1 lần, KHÔNG ghi về tài khoản đã lưu (`withAccount` sẽ ghi đè
    lại tài khoản sau khi body trả về nên chỉnh thẳng là hỏng tài khoản).
    Lần thử lại thất bại thì báo lỗi -128 gốc để UI chẩn đoán. Mua
    license thì KHÔNG tự chỉnh store (purchase chạy trong `withAccount`
    nên bản sao không tách được) — -128 khi mua đi qua popup đổi tài
    khoản như 2059/1010. `StoreDownloadError.rejected` mã 2059/1010/-128
    cũng dịch sang tiếng Việt (màn Lịch sử phiên bản hiện qua alert
    "Oops"). 8 chuỗi mới (223 tổng).
  - Lấy license xong tự refresh + retry lịch sử phiên bản (mục 5):
    sau "Nhập vào Đã mua" thành công, `ProductView` xoá cache phiên bản
    của gói (`AppPackageArchive.clearVersionItems`, chung kho Persist
    theo gói + vùng) rồi tự gọi lại `versions()` 1 lần sau ~1,5 giây —
    mở Lịch sử phiên bản là thấy danh sách mới, không phải tự mở lại /
    bấm Refresh. Lỗi khi làm mới thì lặng lẽ bỏ qua.
  - Fix lỗi redirect khi mua (sáng 25/11: tài khoản kumit.95bt@gmail.com
    vùng IN, gói Muse from Meta vùng US, bấm "Nhập vào Đã mua" thất bại
    "authentication failed: failed to retrieve redirect location"):
    nguyên nhân là `Purchase.purchase` và `Authenticator.rotatePasswordToken`
    trong fork KHÔNG hề gắn Anisette headers — request mua + rotate token
    đều gọi Apple thiếu header, trong khi đăng nhập thì có. Fork
    `nvd29u1/ApplePackage` commit `541c43a` (từ pin `9dc423a`) thêm tham
    số tuỳ chọn `anisetteHeaders: [String: String] = [:]` cho
    `Purchase.purchase` / `purchaseWithParams` / `makeRequest` (gắn vào
    header buyProduct) và `rotatePasswordToken(for:anisetteHeaders:)`
    (chuyền vào `authenticate`); mặc định rỗng nên hành vi cũ không đổi.
    App: `AppStore.anisetteHeadersForStoreCall()` lấy header mới từ máy
    chủ Anisette trong Cài đặt trước khi mua (lấy không được thì dừng,
    không mua thiếu header — cùng chính sách như đăng nhập);
    `acquireLicense` thử lại lỗi tạm thời (204/403/404/5xx, redirect
    không địa chỉ, body trống) tối đa 3 lần, lỗi vùng 2059/1010/-128
    thì KHÔNG retry mà dịch sang tiếng Việt + mở popup; lỗi cửa Apple
    cuối cùng dịch sang tiếng Việt rõ ràng (`PurchaseGateError`).
    Chưa kiểm chứng trên iPhone thật — cần test với tài khoản phụ + máy
    chủ Anisette (xem báo cáo giao bản).
  - Version: 2.0 build 6 (`CURRENT_PROJECT_VERSION` 5 → 6, chỉ trong
    `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0).
- Đợt 2 build 7 (25 Nov 2026, 2.0 build 7): màn Đã mua qua DMAP + tải
  hàng loạt + xuất CSV + 177 vùng tìm kiếm (mục 3 + 4
  `docs/IPADN-SO-SANH.md`). Học ý tưởng iPadn rồi viết lại sạch, KHÔNG
  copy code iPadn (GPL-2.0), giữ MIT. Chưa kiểm chứng trên iPhone thật.
  - Màn Đã mua (`PurchasedView`, tab "Đã mua" sau Search ở cả
    `LegacyTabMainView` / `NewMainView` / sidebar macOS):
    `PurchasedDMAPService` đọc danh sách app đã mua qua DMAP
    (endpoint `pd.itunes.apple.com/.../MZPurchaseDaap.woa/purchase`,
    POST /login body rỗng `Content-Length: 0` → mlid, POST /update ký
    SAP → musr, POST /databases/{rev}/items body DMAP "adsr" ký SAP →
    các mục mlit; 2 lượt cửa hàng "34" iPhone/iPad + "13" Mac, gộp +
    khử trùng theo App ID, mới nhất lên đầu). Parser tag DMAP tự viết
    (`DMAP`: 4 ký tự + 4 byte độ dài big-endian, ghép tay từng byte,
    không `load(as:)`). Tag: aeSI App ID, aeBI Bundle ID, aeLN tên,
    minm tên dự phòng, aePd phiên bản lúc mua, asdp ngày mua (Unix),
    aeMk loại media, aeSS mặt nạ nền tảng. App đã gỡ khỏi App Store vẫn
    hiện (tìm được bằng App ID) và tải được nếu Apple còn phục vụ.
    `PurchasedStore` cache theo tài khoản
    (`Persist<[String: [PurchasedApp]]>`, key `PurchasedAppsByAccount`),
    đồng bộ lại qua `withAccount` (dùng chung phiên đã đăng nhập, retry
    lỗi tạm thời tối đa 3 lần, phiên hết hạn 401/403 thì báo đăng nhập
    lại), tra thêm icon/gói qua `Lookup` ở vùng tìm kiếm đang chọn
    (thử `.iPhone` rồi `.iPad`; Lookup thường vẫn trả về app đã gỡ).
    Bấm vào mục thì mở màn chi tiết `ProductView` với region = vùng
    tìm kiếm; tra không ra thì báo đổi vùng tìm kiếm. Chọn nhiều app
    (nút Chọn/Xong, không dùng `EditButton` vì xung đột editMode) rồi
    "Tải các app đã chọn" đưa vào hàng đợi qua `Downloads.startDownload`
    (báo số thành công/thất bại); xuất CSV (Tên, Bundle ID, Ngày mua)
    qua Share Sheet (`AirDrop`, file tạm `Da-mua-<email>.csv`).
    CHƯA làm bước `/commerce/account/purchases` — ghi rõ trong màn Đã
    mua; một số app mua gần đây có thể chưa hiện, làm sau.
  - Rủi ro chưa xác minh (xem ghi chú SAP trong
    `PurchasedDMAPService.swift`): `SAPSigner.connect()` + `sign(_:)`
    chưa xác minh là API public của fork ApplePackage (tài liệu
    `SAPIntegration.md` của fork ghi "SAPSigner.connect() also exposes
    fresh setup for clients needing only signing" nhưng không đọc được
    source fork để chắc chắn). Nếu CI báo lỗi ở đây thì sửa fork thêm
    ~10 dòng để public `SAPSigner` (cùng kiểu 2 lần thêm
    `anisetteHeaders` trước đây) rồi nâng pin.
  - 177 vùng (`StoreRegion` + `StoreRegionCatalog`, bảng tự viết):
    175 storefront đã kiểm chứng theo dữ liệu công khai (Apple vận hành
    175, khớp storeboard/countrymanager 11–12/11/2026) + AD (Andorra) +
    MC (Monaco) chưa xác minh có cửa hàng riêng không — tìm ở 2 vùng
    đó không có kết quả thì chỉ là không có app, không lỗi. Màn chọn
    vùng trong Cài đặt (`SearchRegionSettingsView`): tìm theo tên Việt /
    Anh / mã ISO-2 (không dấu), tick sao chọn vùng ưa thích, kéo sắp
    xếp + swipe xoá (`onMove`/`onDelete`), nút "Khôi phục mặc định"
    (ưa thích về mặc định VN/US/GB/JP/KR/CN/SG/HK/TW/IN + vùng tìm kiếm
    về US), liệt kê vùng của tài khoản đã đăng nhập. Vùng ưa thích lưu
    `Persist<[String]>` key `SearchFavoriteRegions` trong `AppStore`
    (`searchFavoriteRegions` + `toggle/reset`, lọc mã lạ khi đọc); vùng
    đang tìm vẫn ở `AppStorage("searchRegion")`. `SearchView` dùng
    catalog: menu vùng có "Vùng ưa thích" inline trước rồi "Tất cả vùng"
    (177), nhãn `VN — Việt Nam`. `ProductView` footer ghi rõ vùng đang
    tìm + "tải và nhập vào Đã mua vẫn theo vùng tài khoản".
    `AddDownloadView` tìm tên / Lookup / Request Download dùng vùng
    tìm kiếm thay vì `countryCode` của tài khoản. Vùng tài khoản (mua/
    tải) vẫn giữ theo tài khoản — không đổi.
  - Chuỗi mới dùng `String(localized:)` với literal tiếng Việt nên
    runtime hiển thị đúng, nhưng CHƯA thêm vào `Localizable.xcstrings`
    (cần chạy String Catalog update ở Xcode sau để có bản dịch en/
    zh-Hans).
  - Version: 2.0 build 7 (`CURRENT_PROJECT_VERSION` 6 → 7, chỉ trong
    `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0 ở cả xcconfig và
    pbxproj).
- Đợt 3 build 8 (25 Nov 2026, 2.0 build 8): lịch sử phiên bản giàu hơn
  + theo dõi/so giá + nhắc bản mới + Wi-Fi transfer + xem nội dung IPA
  + khoá app + altstore-source.json (mục 6, 9, 10 + "Đáng nhắc thêm"
  `docs/IPADN-SO-SANH.md`). Học ý tưởng iPadn rồi viết lại sạch, KHÔNG
  copy code iPadn (GPL-2.0), giữ MIT. Chưa kiểm chứng trên iPhone thật.
  - Lịch sử phiên bản giàu hơn (`VersionExtra`,
    `StoreDownloadService.versionMetadata` trả thêm extra,
    `AppPackageArchive` lưu `versionExtras` theo version ID +
    `enrichLatestExtraIfNeeded`): mỗi dòng hiện dung lượng IPA + ngày +
    ghi chú cập nhật (đọc từ metadata tải của Apple — có thì hiện,
    không có thì UI hiện "—", KHÔNG bịa số; riêng bản mới nhất tra thêm
    qua iTunes Lookup công khai). Bấm giữ 1 dòng (contextMenu) để copy
    số version / version ID. Icon đúng từng phiên bản (đọc PNG trong
    IPA) CHƯA làm — tốn lượt tải range đầu IPA cho từng bản, để đợt sau.
  - "Giữ phiên bản này": cờ `pinned` trong `PackageManifest`
    (decodeIfPresent, manifest cũ mặc định false), bật/tắt ở màn chi
    tiết gói đã tải + từng dòng tab Lượt tải (`Downloads.setPinned`,
    lưu manifest ngay). Đã giữ thì `UpdateCheckStore.hasUpdate` không
    nhắc bản mới nữa.
  - Theo dõi app + so giá (`FollowStore`, `WatchlistView` tab "Đang
    theo dõi" ở cả 3 main view, `PriceComparisonService`,
    `PriceComparisonView` trong `ProductView`): bấm "Theo dõi app này"
    ở màn chi tiết; màn Đang theo dõi hiện giá + phiên bản hiện tại +
    lịch sử giá (ghi điểm khi giá đổi hoặc điểm cuối hơn 24 giờ, tối đa
    60 điểm/app). So giá: tra `ApplePackage.Lookup` ở từng vùng ưa
    thích (đợt 2), xếp rẻ → đắt, mỗi vùng hiện theo tiền tệ của vùng đó
    (formattedPrice của Apple), KHÔNG quy đổi sang VNĐ (app không có tỉ
    giá). Giá chỉ tra khi người dùng bấm / mở màn, không chạy nền.
  - Nhắc bản mới (`UpdateCheckStore`): tab Lượt tải `onAppear` tra
    phiên bản mới nhất qua Lookup cho app đã tải xong (bỏ qua nếu lần
    tra trước chưa quá 10 phút), có bản mới thì dòng hiện nhãn cam "Có
    bản mới: vX.Y". So sánh version theo từng đoạn số.
  - Wi-Fi transfer (`WiFiTransferServer` tái dùng Vapor đã có,
    `WiFiTransferView`, công tắc `AppStore.wifiTransferEnabled` trong
    Cài đặt): trang "/" liệt kê IPA đã tải xong, "/ipa/<uuid>" cho PC
    tải về; chỉ chạy khi đã bật trong Cài đặt VÀ đang ở màn chia sẻ,
    rời màn là tắt ngay. Chỉ đọc file IPA đã tải xong, không có đường
    ghi/xoá. Địa chỉ IP lấy qua getifaddrs (ưu tiên en0), cổng ngẫu
    nhiên 4000–8000.
  - Xem nội dung IPA: nút "Content Viewer" ở màn chi tiết gói đã tải
    đổi tên thành "Xem nội dung IPA" (dùng sẵn `FileListView` liệt kê
    ZIP + `FileAnalysisView`); `FileAnalysisView` giờ xem trước thật:
    ảnh hiện 120px (trước đây `thumbnail` khai báo mà không bao giờ
    gán nên ảnh không hiện), file text ≤ 64 KB hiện nội dung, vẫn trích
    1 file ra Share Sheet.
  - Khoá app (`AppLockService`, `AppLockGate` bọc gốc WindowGroup trong
    `main.swift`, công tắc `AppStore.appLockEnabled` trong Cài đặt):
    LocalAuthentication `.deviceOwnerAuthentication` (Face ID / Touch
    ID / mật khẩu thiết bị, không lưu mật khẩu nào). Mở app lên là
    khoá; `scenePhase != .active` thì khoá lại ngay nên ảnh đa nhiệm
    cũng chỉ thấy màn khoá.
  - `altstore-source.json` ở root repo (cài/cập nhật qua SideStore /
    AltStore / Feather): `downloadURL` trỏ asset release
    `v2.0.8/NVDAppleIDDownload.ipa`, icon lợn lấy từ
    `PigLogo.imageset/PigLogo.png` trên raw.githubusercontent. CHƯA có
    tag v2.0.8 nên link chưa tải được — mỗi lần tag release mới phải
    cập nhật `version`/`versionDate`/`versionDescription`/`downloadURL`
    trong file này theo đúng tag/asset.
  - Mac PKG CHƯA làm được: fork ApplePackage chỉ có EntityType
    iPhone/iPad/AppleTV, không có endpoint tải PKG Mac App Store — muốn
    làm phải thêm giao thức mới vào fork rồi kiểm chứng, để đợt sau.
    Không thêm nút giả.
  - Version: 2.0 build 8 (`CURRENT_PROJECT_VERSION` 7 → 8, chỉ trong
    `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0 ở cả xcconfig và
    pbxproj).
- Đợt 4 build 9 (25 Nov 2026, 2.0 build 9): tải nền thật + Đã mua bước
  Commerce + icon đúng từng phiên bản + "Tải xong tự cài đặt" (mục 8,
  3, 6 `docs/IPADN-SO-SANH.md`). Học ý tưởng iPadn rồi viết lại sạch,
  KHÔNG copy code iPadn (GPL-2.0), giữ MIT. Chưa kiểm chứng trên
  iPhone thật.
  - Tải nền thật (`BackgroundDownloadService`, URLSession background
    `com.NVD.appleiddownload.downloads` + URLSessionDownloadTask):
    tạm dừng bằng cancel(byProducingResumeData:) → resumeData lưu vào
    `PackageManifest.resumeData` (decodeIfPresent, manifest cũ vẫn đọc
    được); tiếp tục bằng downloadTask(withResumeData:), resumeData hỏng
    thì tải mới; app bị tắt / sang nền thì hệ thống vẫn tải tiếp, mở
    lại app reattach() qua getAllTasks (taskDescription = UUID
    manifest); số byte đã tải / tổng số ghi vào `PackageState`
    (downloadedBytes/totalBytes) nên mở lại app vẫn hiện đúng;
    AppDelegate nối handleEventsForBackgroundURLSession; finalize()
    khi app ở nền chạy trong beginBackgroundTask. Link CDN hết hạn
    (403/410) thì Downloads gọi lại StoreDownloadService.download()
    lấy URL mới rồi tải lại — resumeData gắn chặt với URL cũ nên
    KHÔNG nối tiếp được, đây là giới hạn của URLSession (ghi rõ trong
    code). Digger KHÔNG xoá, chỉ còn là đường dự phòng khi không tạo
    được background task (đường Digger tạm dừng vẫn mất tiến độ).
  - "Tải xong tự cài đặt" (`AppStore.autoInstallAfterDownload`,
    Persist Bool mặc định TẮT, Toggle trong Cài đặt, chỉ iOS): tải
    xong + bật + app đang mở thì tạo Installer như cũ rồi mở
    itms-services; Installer được giữ lại trong Downloads để máy chủ
    Vapor còn phục vụ file; tắt thì tải xong vẫn bấm Cài đặt tay.
    KHÔNG làm Live Activity (cần extension + 1 App ID mới).
  - Đã mua bước Commerce (`PurchasedCommerceService`,
    `/commerce/account/purchases` JSON:API, xác thực bằng phiên đã đăng
    nhập — X-Token, X-DSID, X-Apple-Store-Front, ký SAP như DMAP):
    ⚠️ dạng request/response chính xác CHƯA xác minh bằng tài khoản
    thật — code đọc JSON:API linh hoạt (data/results/purchases/items,
    attributes nhiều tên trường, included, links.next tối đa 10 trang,
    gọi tuần tự) nhưng nếu Apple trả dạng khác thì ném unknownShape,
    PurchasedStore giữ nguyên danh sách DMAP + ghi chú cam, không
    crash, không bịa app. Nút "Đồng bộ toàn bộ lịch sử mua" trong
    PurchasedView; gộp Commerce + DMAP, khử trùng theo App ID; năm
    đồng bộ đầy đủ gần nhất lưu theo tài khoản
    (Persist `PurchasedFullSyncYearByAccount`). Không quét theo từng
    năm (chưa biết endpoint có tham số lọc năm không) — ghi rõ trong
    code + báo cáo; cần thử thật rồi sửa parser theo response thật.
  - Icon đúng từng phiên bản (`VersionIconService` + icon 44x44 trong
    `ProductHistoryView`): lấy URL tải có chữ ký qua
    StoreDownloadService.download() rồi 2–4 Range-request (đuôi file
    IPA → EOCD + Central Directory của ZIP → entry icon → dữ liệu
    nén); parse ZIP tay, ưu tiên AppIcon60x60@2x.png ngay dưới *.app/,
    không thì AppIcon*.png lớn nhất; giải nén deflate bằng inflate
    thuần Swift trong cùng file (~200 dòng, RFC 1951 — Swift trên
    Apple không có module `zlib`, Compression chỉ giải zlib có header);
    cache PNG theo version ID xuống đĩa
    (Documents/NVDAppleIDDownload/VersionIcons/); chỉ tải lười khi
    dòng hiện ra, 1 lần/version ID/phiên; Apple không phục vụ Range /
    không đọc được thì hiện icon giữ chỗ, không crash, không bịa.
  - Mac PKG vẫn CHƯA làm được (lý do như đợt 3: fork ApplePackage
    không có endpoint tải PKG Mac App Store; muốn làm phải thêm giao
    thức mới vào fork nvd29u1/ApplePackage rồi nâng pin + kiểm chứng
    qua CI — tách thành việc riêng). Không thêm nút giả.
  - Version: 2.0 build 9 (`CURRENT_PROJECT_VERSION` 8 → 9, chỉ trong
    `Version.xcconfig`; pbxproj không pin CURRENT_PROJECT_VERSION,
    chỉ pin MARKETING_VERSION 2.0 nên không cần sửa pbxproj).
- Đợt 5 build 10 (25 Nov 2026, 2.0 build 10): GỘP NVDsign vào
  NVDAppleIDDownload thành 1 app duy nhất (quyết định của anh sáng
  25/11). Nguồn: fork nvd29u1/SayoSign nhánh nvd, v1.4 build 1
  (head 451036d4). Học ý tưởng rồi port code GPL-3.0 của murk-sus,
  giữ LICENSE (`LICENSE-SayoSign-GPL-3.0` ở root) + dòng ghi công
  trong Giới thiệu (Cài đặt) và trong About của tab Ký; KHÔNG copy
  code iPadn (GPL-2.0). Chưa kiểm chứng trên iPhone thật.
  - Tính năng ký đã gộp đủ (tab "Ký IPA", `Interface/Sign/`, chỉ
    iOS — file bọc `#if os(iOS)`): ký bằng .p12, ký bằng Apple ID
    (+2FA), chèn tweak (SayoHook qua framework CydiaSubstrate),
    cài offline (máy chủ cài đặt local + manifest), nhập IPA từ
    Tệp, nhập IPA từ file vừa tải (nút "Ký IPA này" ở màn chi tiết
    gói đã tải trong tab Lượt tải), thư viện app đã ký, chạy app
    trong NVDAppleIDDownload (Container.swift port nguyên; sửa 1
    lỗi thật: đường request file cũ `.../SayoSign/SayoSign/...`
    có thư mục cha không bao giờ được tạo nên ghi file có thể
    fail — bản gộp dùng đường phẳng
    `.../Application Support/NVDAppleIDDownload/container-launch.plist`
    và tạo thư mục cha trong `run()` trước khi ghi; điểm vào ở
    `main.swift`: `_ = Container.launchIfRequested()`).
  - Đổi tên: bundle `com.NVD.appleiddownload`; URL scheme UDID
    `nvdappleiddownload` (link `://udid` do Installer sinh khớp
    scheme này, không còn `nvdsign://`); Keychain service ký
    `com.NVD.appleiddownload.sign`; Application Support ký
    `.../NVDAppleIDDownload`; CA local của tính năng ký đổi tên
    sang NVDAppleIDDownload; CA local "NVD Local Installation CA"
    của app giữ nguyên. App mới là app khác nên dữ liệu
    Keychain/cert của NVDsign 1.4 KHÔNG mang sang — người dùng
    phải nhập lại .p12 / đăng nhập lại Apple ID. Chuỗi
    "SayoSign Desktop" giữ nguyên (tên sản phẩm thật của tác giả).
  - Máy chủ manifest thống nhất MỘT setting: dùng setting sẵn
    của NVDAppleIDDownload (`AppStore.manifestServerURL`, mặc
    định worker nvd-manifest); `SignInstaller.manifestService()`
    đọc setting đó; ô nhập trong Cài đặt ký bind vào
    `$store.manifestServerURL`. Không còn 2 setting manifest.
  - Bỏ hẳn tab Trang chủ: xoá `Interface/Welcome/` (MainView,
    WelcomeView, SimpleInstruction); nội dung gộp vào mục "Giới
    thiệu" cuối Cài đặt (logo PigLogo, tên app, phiên bản, 4 bước
    hướng dẫn theo luồng mới + dòng ghi công Asspp/Lakr233 MIT +
    SayoSign/murk-sus GPL-3.0 + BorderBeam/ismnoiet MIT). Tab bar
    sau gộp chỉ còn đúng 4 tab: Tài khoản, Lượt tải, Ký IPA, Cài
    đặt — cập nhật cả 3 biến thể (LegacyTabMainView, NewMainView
    iOS 26+, sidebar macOS; macOS hiện SignUnavailableView vì ký
    chỉ có trên iPhone). ⚠️ THEO QUYẾT ĐỊNH 4 TAB NÀY, CÁC TAB
    TÌM KIẾM / ĐÃ MUA / ĐANG THEO DÕI / INSTALLED BỊ GỠ KHỎI
    ĐIỀU HƯỚNG (build 4–8 chưa từng giao cho anh nên anh chưa
    biết các tab đó tồn tại) — file view vẫn còn trong repo, khôi
    phục được bằng 1 commit; luồng tải còn lại là nhập tên app /
    Bundle ID trong tab Lượt tải (AddDownloadView, build 4). Cần
    anh xác nhận lại trước khi giao.
  - Strings: 352 key vi.lproj của NVDsign gộp vào
    `Localizable.xcstrings` (336 key mới + "Install options" đổi
    từ key "Installing" trùng khác nghĩa — NVD vi "Đang cài",
    Sayo vi "Cài đặt app"; 16 key trùng giá trị bỏ qua); tổng
    559 key, 0 literal L()/LF() thiếu. Key mới chỉ có en + vi
    (zh-Hans bỏ — fallback về en).
  - Project: script sửa `Asspp.xcodeproj/project.pbxproj`
    (không sửa tay) — thêm 17 file C `core/src/*.c` vào Compile
    Sources của app target; `SWIFT_OBJC_BRIDGING_HEADER`
    `NVDAppleIDDownload/App/SignBridgingHeader.h` (`#include
    "sayo.h"` + `#include "sayoidev.h"`); `HEADER_SEARCH_PATHS`
    `$(SRCROOT)/core/include` + `$(SRCROOT)/core/src`;
    `OTHER_LDFLAGS` `-lz -lcompression -framework Security` và
    `OTHER_LDFLAGS[sdk=iphoneos*]` `-lsayoidev`,
    `LIBRARY_SEARCH_PATHS[sdk=iphoneos*]` tới
    `rust/sayoidev/target/aarch64-apple-ios/release` (chỉ iOS,
    build macOS không cần .a); target framework mới
    `CydiaSubstrate` (hook/SayoHook.c, bundle
    `com.NVD.appleiddownload.hook`, hỗ trợ cả iphoneos + macosx)
    + TargetDependency + phase "Embed Frameworks" ở app target
    (embed-only, không link — signer tìm framework qua
    `Bundle.main.privateFrameworksURL`). Vendor `core/` +
    `rust/sayoidev/` + `hook/` từ fork NVDsign (header GPL giữ
    nguyên; "SayoSign" còn sót trong comment code vendored
    core/rust — không phải chỗ người dùng nhìn thấy).
  - CI: KHÔNG sửa `.github/workflows/*` (token chỉ scope repo).
    Bước build Rust thêm vào
    `Resources/Scripts/compile.release.mobile.ci.sh` (sau git
    clean, trước xcodebuild): kiểm tra `cargo`, `rustup target
    add aarch64-apple-ios`, `IPHONEOS_DEPLOYMENT_TARGET=17.0
    cargo build --release --target aarch64-apple-ios`,
    kiểm chứng `libsayoidev.a` tồn tại, lỗi thì fail rõ ràng.
    `compile.release.osx.sh` không đổi.
  - Lưu ý: IPA tải từ App Store vẫn mã hoá FairPlay nên đưa vào
    tab Ký sẽ báo encrypted ở SignView — không phải lỗi gộp.
  - Rủi ro chưa xác minh: Commerce/DMAP của build 9 (dạng
    request/response `/commerce/account/purchases` chưa xác minh
    bằng tài khoản thật); Rust bridge trong CI (lần đầu build
    .a trên runner); framework hook (lần đầu embed); toàn bộ
    tính năng ký chưa kiểm chứng trên iPhone thật (lần đầu dùng
    Apple ID phụ); app ký PHẢI cài trực tiếp qua SideStore,
    không chạy trong LiveContainer (đã chứng minh 24/11).
  - Sửa lỗi job macOS `LSSupportsOpeningDocumentsInPlace = NO
    is not supported on macOS`: key này do đợt gộp thêm từ
    project.yml của NVDsign (chỉ iOS) vào Info.plist dùng chung
    2 target — đã xoá hẳn (trên iOS thiếu key mặc định đã là
    NO nên không đổi hành vi).
  - Sửa lỗi link "no rule to process file ... of type
    'sourcecode.c'" (18 file C không biên dịch, symbol sayo_*
    thiếu): `lastKnownFileType` của file `.c` phải là
    `sourcecode.c.c` (type cụ thể có rule CompileC), không phải
    `sourcecode.c` (type cha trừu tượng, không có rule) — lỗi do
    script sửa pbxproj ghi sai type; đã sửa 18 entry (17 file
    core + SayoHook.c), header vẫn `sourcecode.c.h`.
  - Sửa lỗi CI của build 9 (runner giờ dùng Xcode 26.6 — code
    biên dịch được ngày 24/11 giờ lỗi): 7 chỗ
    `UIApplication.shared.open(...)` thiếu `await` (SDK mới chỉ
    còn overload async `open(_:)`) — InstallerView (2 chỗ, Button
    + onAppear), Downloads auto-install, SignInstaller
    openTrollStore, SignAppleID detectUDID, SignSettingsView,
    SignPairing (bọc `Task { @MainActor in _ = await ... }`, riêng
    Downloads đã trong Task nên thêm `await` thẳng); 1 chỗ
    `Color(.systemBackground)` ở AppLockService làm job macOS lỗi
    — đổi sang `Color.background` (dùng chung iOS/macOS).
  - Version: 2.0 build 10 (`CURRENT_PROJECT_VERSION` 9 → 10,
    chỉ trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0
    ở cả xcconfig và pbxproj).
- Đợt 5 build 11 (25 Nov 2026, 2.0 build 11): TRẢ LẠI 3 tab
  Tìm kiếm / Đã mua / Đang theo dõi theo quyết định của anh
  (12:38 25/11 — "trả lại 3 tab rồi mới giao"; build 10 chưa
  giao). Tab bar thành 7 tab theo đúng thứ tự build 9, chỉ bỏ
  Trang chủ và thêm Ký IPA: Tài khoản, Tìm kiếm, Đã mua, Đang
  theo dõi, Lượt tải, Ký IPA, Cài đặt. Khôi phục ở cả 3 biến
  thể: LegacyTabMainView (.tabItem + .tag), NewMainView iOS 26+
  (Tab value-based — KHÔNG dùng `Tab(role: .search)` như build
  9 vì bản gộp dùng shared `MainTabSelection` binding; SearchView
  đã có `.searchable` riêng nên ô tìm kiếm vẫn chạy), sidebar
  macOS (`SidebarSection` + `detailView` + title/icon y hệt
  build 9: magnifyingglass / bag / eye) + phím tắt ⌘F nhảy tới
  tab Tìm kiếm (SearchFieldFocus). `MainTab` enum thêm lại 3
  case search/purchased/watchlist. Tab Installed (chỉ macOS)
  KHÔNG trả lại — anh chỉ chốt 3 tab trên. Trang chủ vẫn bỏ.
  - Sửa chuỗi sót build 10: `rust/sayoidev/src/lib.rs:223`
    "pair again in SayoSign" → "pair again in
    NVDAppleIDDownload". Giữ nguyên tên client "SayoSign" ở
    `lib.rs:218` (`RemotePairingClient::new(..., "SayoSign")`) —
    đó là identifier trong handshake pairing, cùng loại với các
    identifier hệ thống đã giữ có chủ ý ở NVDsign; đổi thì cần
    quyết riêng. Chuỗi "SayoSign Desktop" giữ nguyên (tên sản
    phẩm thật của tác giả); "SayoSign" trong comment code
    vendored core/rust giữ nguyên (không phải chỗ người dùng
    nhìn thấy).
  - CI: run 45555338668 (commit `a7fe7d27`, workflow "Build App")
    `success` cả build-ios + build-osx; IPA kiểm chứng độc lập
    từ artifact (2.0 build 11, bundle đúng, đủ 7 tab ở source,
    chuỗi pairing mới có trong binary, chuỗi cũ 0 hit).
  - Version: 2.0 build 11 (`CURRENT_PROJECT_VERSION` 10 → 11,
    chỉ trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0
    ở cả xcconfig và pbxproj).
- Đợt 5 build 12 (25 Nov 2026, 2.0 build 12): xếp lại tab + chặn
  crash tab Đã mua (2 lỗi anh báo trên iPhone thật 13:45 25/11,
  sau khi cài build 11).
  - Xếp lại tab: iPhone chỉ hiện 4 tab + menu Thêm nên thứ tự
    build 11 chôn Lượt tải + Ký IPA trong Thêm. Thứ tự mới ở cả
    3 biến thể (LegacyTabMainView, NewMainView iOS 26+, sidebar
    macOS): Tài khoản, Tìm kiếm, Lượt tải, Ký IPA hiện trực
    tiếp; Đã mua, Đang theo dõi, Cài đặt vào menu Thêm. Không
    bỏ tab nào — chỉ đổi thứ tự (`MainTab` /
    `SidebarSection.allCases` + `detailView`, thứ tự case trong
    enum đổi theo). Tab mặc định vẫn Lượt tải.
  - Chặn crash tab Đã mua: triệu chứng — ấn tab, màn mở được,
    hiện "Đang đồng bộ danh sách Đã mua..." rồi văng app trong
    lúc đồng bộ (auto-sync DMAP). Rà soát toàn bộ đường đồng bộ
    (`PurchasedView` + `PurchasedStore` + `PurchasedDMAPService`
    + `PurchasedCommerceService` + fork ApplePackage pin
    541c43a): code app KHÔNG có force unwrap / force cast /
    force try nào trên đường này; `Persist` decode hỏng thì về
    mặc định, `Lookup` đã có `ensure` chặn trước `.first!`,
    `SAPSigner.connect()` cũng là đường đăng nhập đã chạy được
    trên máy thật 24/11. Nghi phạm rõ ràng nhất là 3 chỗ ép
    kiểu số nguyên trong parser DMAP tự viết — ép trực tiếp sẽ
    trap (văng app, không throw được) nếu Apple trả tag 8 byte
    vượt giới hạn: `UInt32(mlid)` / `UInt32(musr)` ở
    `fetchStorefront` và `Int64(aeSI)` ở `parseItem`. Đã sửa:
    mlid/musr kiểm tra `<= UInt32.max` rồi mới ép, vượt thì ném
    `badResponse` (màn hiện lỗi tiếng Việt, giữ danh sách cũ);
    aeSI dùng `Int64(exactly:)`, không vừa thì bỏ mục đó;
    `mstc` dùng `truncatingIfNeeded`. Thêm 1 chốt phòng thủ:
    `fetchPurchasedApps` chạm `AppStore.this` trước khi
    `SAPSigner.connect()` mở HTTP client — fork có
    `precondition(!deviceIdentifier.isEmpty)` ở cấu hình TLS,
    trap nếu chưa cài device identifier (AppStore.init cài sẵn
    identifier đã lưu / tạo ngẫu nhiên). Đường Commerce
    (`syncFullHistory`, chỉ chạy khi bấm nút) không có trap
    nào tương tự. ⚠️ Chưa chắc chắn 100%: không có iPhone thật
    + không có crash log nên không khẳng định trap nào trên đây
    là đúng thủ phạm — chỉ biết chắc là sau bản này không còn
    đường trap nào rõ ràng trên đường đồng bộ; nếu anh vẫn thấy
    văng thì cần gửi crash log (Cài đặt → Quyền riêng tư →
    Phân tích) để đối chiếu đúng dòng.
  - Version: 2.0 build 12 (`CURRENT_PROJECT_VERSION` 11 → 12,
    chỉ trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0
    ở cả xcconfig và pbxproj).
  - CI + IPA: lần đẩy đầu (remote `333db971`) CI "Build App"
    run 45563851543 `failure` cả build-ios + build-osx ở bước
    Build — lỗi do chính dòng `mstc` mới thêm:
    `UInt32(truncatingIfNeeded: Double)` không có overload
    (annotation: "cannot convert value of type 'TimeInterval'
    to expected argument type 'BitArray'",
    PurchasedDMAPService.swift:281); sửa bằng trung gian
    `UInt64(...)` rồi đẩy lại (remote `c1254f82`), run
    45567881357 `success` cả 2 job. IPA
    `deliver/NVDAppleIDDownload.ipa` (25.354.068 byte, SHA256
    `f18f0f58969a6f27d1da9500637b2797e0e75390662aa4e7cfd6e0b09cb07097`):
    kiểm chứng 2.0 build 12, bundle
    `com.NVD.appleiddownload`, min iOS 17.0, đủ nhãn 7 tab +
    chuỗi Đã mua trong binary, framework CydiaSubstrate đã
    embed, chuỗi pairing mới 1 hit. Build 11 giữ lại ở
    `deliver/NVDAppleIDDownload-2.0-build11-backup.ipa`
    (SHA256 `1514fe66…` khớp bản đã giao). Thứ tự tab mới chỉ
    kiểm chứng ở source + biên dịch CI, chưa kiểm chứng hiển
    thị trên iPhone thật (cần anh mở tab bar xem 4 tab đầu).
    Quy tắc version dòng 2.0 (dừng ở build 19, xong đến 2.1)
    đã ghi ở mục Build Configuration, giữ nguyên khi ghi chú
    bản này.
- Đợt 5 build 13 (25 Nov 2026, 2.0 build 13): sửa 3 lỗi anh báo
  trên iPhone thật 15:43–15:58 25/11 (bản 12) + 2 việc anh chốt
  thêm 16:01–16:03 cùng ngày. Chưa kiểm chứng trên iPhone thật.
  - LỖI 1 — Tìm kiếm mất ô nhập (ảnh 15:43): nguyên nhân đúng như
    đã chẩn đoán — `SearchView.modernContent` (iOS 26+) ẩn nav bar
    trên iPhone compact, `.searchable` placement automatic chỉ hiện
    trong nav bar nên không còn chỗ gõ; 2 pill "iPhone"/"IN" trong
    ảnh là `safeAreaBar`. Hướng đã chọn: (c) thêm TextField tìm kiếm
    THẬT trong `safeAreaBar` cho compact (bind `$searchKey`,
    Enter/bấm "Tìm" gọi `search()`, nút xoá khi có chữ) — hiển thị
    được bất kể nav bar / placement, giữ nguyên shared binding +
    thứ tự tab; KHÔNG đổi sang `Tab(role: .search)` (API đó bắt
    buộc bỏ shared binding / đổi cấu trúc tab, rủi ro hơn mà không
    chắc hơn). `.searchable` cũ vẫn giữ cho regular size class.
  - LỖI 2 — Lượt tải lỗi "Không có tệp hay thư mục nào như vậy"
    dù đúng vùng (Facebook 588.1, tài khoản IN, ảnh 15:40–15:47):
    nguyên nhân là file tạm của URLSession background — hệ thống
    được phép dọn file ở `location` ngay khi delegate
    `didFinishDownloadingTo` trả về, mà bản 12 chỉ chuyển tiếp
    location qua `Task @MainActor` + `Task.detached` rồi mới
    `finalize()` ở `Downloads`: tới lúc đó file đã bị dọn nên
    `moveItem` trong finalize ném đúng lỗi ENOENT anh thấy, gói
    rơi failed / "Gói chưa đầy đủ". Sửa:
    `BackgroundDownloadService.didFinishDownloadingTo` dời file về
    staging `Documents/NVDAppleIDDownload/Packages/.staging/<uuid>.ipa`
    ĐỒNG BỘ ngay trong delegate, rồi mới giao staging URL cho
    Downloads; `Downloads.finalize` chặn thêm: file nguồn không còn
    thì ném lỗi tiếng Việt rõ ("File tải về đã bị hệ thống dọn...
    Hãy bấm Tải lại") thay vì lỗi hệ thống thô, và dọn file staging
    còn sót khi finalize lỗi giữa chừng. KHÔNG đổi vùng tài khoản,
    KHÔNG động logic vùng. Nút "Tải lại" (restart) vẫn tải mới từ
    đầu như cũ.
  - LỖI 3 — Đã mua VẪN văng (build 12 chặn sai chỗ, đã chứng minh
    bằng CRASH LOG THẬT): file
    `~/workspace/user/files/NVDAppleIDDownload-2026-11-25-155927.ips`
    (app 2.0 build 12, iPhone16,1 iOS 27.0, crash 15:59:27 25/11,
    EXC_BREAKPOINT / SIGTRAP). Thread gây văng (id 17721883):
    `Data._Representation.subscript.getter` → `specialized static
    DMAP.children(of:)` → `static DMAP.first(_:code:)` ×2 (ngoài +
    đệ quy) → `PurchasedDMAPService.fetchStorefront` →
    `fetchPurchasedApps` → `AppStore.withAccount` →
    `PurchasedStore.sync()`. Nguyên nhân chính xác:
    `DMAP.children(of:)` subscript Data bằng chỉ số bắt đầu từ 0
    (`data[offset ..< offset+4]`, `data[offset+4]`...), nhưng
    payload mà `first()` truyền vào khi đệ quy là Data slice
    (`data[a..<b]`) — slice của Swift Data GIỮ NGUYÊN chỉ số gốc,
    `startIndex` = a ≠ 0 — nên `data[0..<4]` trên slice là vượt
    giới hạn → trap ngay tag container đầu tiên trong response,
    100% mỗi lần đồng bộ. Mấy chỗ chặn ép kiểu UInt32/Int64 ở
    build 12 KHÔNG phải thủ phạm (chúng nằm sau điểm văng, chưa bao
    giờ chạy tới). Sửa: `children(of:)` cộng thêm `data.startIndex`
    vào mọi lần truy cập (`base + offset`); các guard build 12 giữ
    nguyên. Đã rà các chỗ subscript Data bằng chỉ số nguyên khác
    trong PurchasedDMAPService + PurchasedCommerceService: không
    còn chỗ nào (chỉ còn `data[...]` kiểu dictionary key trong
    Commerce). Fork ApplePackage pin 541c43a đã đọc source để đối
    chiếu: `SAPSigner.connect()`/`sign()` là public thật,
    `Lookup.lookup` có 2 ensure trước `.first!`, `withAccount`
    của app không có force unwrap — đều không phải thủ phạm.
  - ĐỔI THỨ TỰ TAB (anh chốt 16:01–16:02 25/11): hiện trực tiếp
    thành Ký IPA, Tìm kiếm, Lượt tải, Tài khoản; Đã mua, Đang theo
    dõi, Cài đặt vẫn ở menu Thêm. Áp dụng cả 3 biến thể
    (LegacyTabMainView, NewMainView iOS 26+, sidebar macOS).
    Tab mặc định khi mở app vẫn là Lượt tải.
  - BỎ HEADER CARD Ở CÀI ĐẶT KÝ (anh chốt 16:03 25/11):
    xoá đúng card header (logo lợn + "NVDAppleIDDownload" +
    "Trình ký IPA trên thiết bị" + version) khỏi
    `SignSettingsView`, cùng thuộc tính `version` chỉ dùng cho card
    đó. Giữ nguyên tiêu đề "Cài đặt" + toàn bộ mục bên dưới.
    Header ở Cài đặt chính của app (mục Giới thiệu) KHÔNG động vào.
  - Version: 2.0 build 13 (`CURRENT_PROJECT_VERSION` 12 → 13,
    chỉ trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0
    ở cả xcconfig và pbxproj).
  - CI + IPA: remote `58d017a1` (commit code `d803c9d`), CI "Build
    App" run 45582242354 `success` cả build-ios + build-osx. IPA
    `deliver/NVDAppleIDDownload.ipa` (25.361.767 byte, SHA256
    `750ad4a3bf408c39771b9a953c1fbc17bd424a174265b06189baf205982c0b96`):
    kiểm chứng 2.0 build 13, bundle `com.NVD.appleiddownload`,
    min iOS 17.0, binary có chuỗi ô tìm kiếm mới ("Tìm tên app
    hoặc Bundle ID"), ".staging" (5 hit), lỗi finalize tiếng Việt,
    symbol PurchasedView/SearchView/SignRootView/WatchlistView,
    `sayo_idev` (35 hit), framework CydiaSubstrate đã embed; thứ
    tự tab mới kiểm chứng ở source cả 2 biến thể iOS (Ký IPA,
    Tìm kiếm, Lượt tải, Tài khoản rồi Đã mua, Đang theo dõi,
    Cài đặt). Build 12 giữ lại ở
    `deliver/NVDAppleIDDownload-2.0-build12-backup.ipa`
    (SHA256 `f18f0f58…` khớp bản đã giao). Chưa kiểm chứng trên
    iPhone thật — cần anh test: gõ tên app ở tab Tìm kiếm, tải
    Facebook lại, mở tab Đã mua xem còn văng không, xem thứ tự
    tab + màn Cài đặt của tab Ký IPA đã mất card header chưa.

- Đợt 5 build 14 (25 Nov 2026, 2.0 build 14): sửa lỗi Đã mua báo "Phiên
  đăng nhập đã hết hạn" sau khi bản 13 đã hết văng (anh báo 16:41
  25/11, có ảnh: tab mở được, lỗi đỏ "Phiên đăng nhập đã hết hạn. Hãy
  đăng nhập lại tài khoản rồi bấm Đồng bộ lại." + "Chưa có app nào
  trong mục Đã mua."). Chưa kiểm chứng trên iPhone thật.
  - CHẨN ĐOÁN (đọc code, không có log máy thật để đối chiếu bước nào):
    lỗi là `PurchasedDMAPError.sessionExpired`, ném ở `checkHTTP` khi
    login/update/items trả 401/403. "Phiên hết hạn" chưa chắc đúng:
    đường tải cùng tài khoản vẫn chạy được lúc 15:40 25/11 (~1 giờ
    trước) — nhưng đường tải xác thực bằng COOKIE
    (`StoreDownloadService.fetch`: `account.cookie.buildCookieHeader`),
    còn DMAP trước đây CHỈ gửi `X-Token: passwordToken` và không gửi
    cookie — nên tải chạy được chỉ chứng minh cookie còn sống, không
    chứng minh token còn sống. Token cấp lúc đăng nhập 24/11 ~22:41,
    mới ~18 giờ nên ít khả năng tự hết, nhưng DMAP là đường duy nhất
    dùng trực tiếp token đã lưu (đường mua thì rotate token trước mỗi
    lần mua, build 6) nên token cũ là nghi phạm số 1; thiếu cookie +
    thiếu header Anisette trên request DAAP là nghi phạm số 2 (iTunes
    thật gửi cả cookie + token; Apple chặn request thiếu xác minh thiết
    bị từ 11/2026 như đường đăng nhập / mua). X-GUID/storefront/UA đã
    rà: đúng (store IN 143467 + hậu tố "34"/"13", GUID đã cài,
    UA chung). Không thể kết luận bước nào trả 401/403 nếu không có
    log máy thật — log `Purchased DMAP: <label> HTTP=<status>` đã có
    sẵn trong LogManager (Cài đặt → Nhật ký).
  - FIX (theo thứ tự ưu tiên, đều trong `PurchasedDMAPService` +
    `PurchasedStore`, KHÔNG động đường tải):
    (a) Gửi kèm cookie phiên đã đăng nhập trên mọi request DMAP
    (`applyHeaders`: `account.cookie.buildCookieHeader(url)`, giống
    hệt đường tải) — giữ nguyên X-Token.
    (b) Gắn header Anisette khi đã cấu hình máy chủ
    (`fetchPurchasedApps` lấy qua `anisetteHeadersForStoreCall()` rồi
    chuyền vào `fetchStorefront` → `applyHeaders`; URL trống thì [:],
    hành vi cũ; lấy không được thì dừng với lỗi đó như đường mua).
    (c) Gặp 401/403 thì làm mới token lặng lẽ 1 lần rồi thử lại
    (`PurchasedStore.fetchDMAPWithTokenRefresh`, dùng chung cho sync
    thường + bước DMAP của đồng bộ toàn bộ): `rotatePasswordToken`
    với header Anisette (cùng mẫu `acquireLicense` build 6, fork
    541c43a — re-auth bằng email + mật khẩu + cookie đã lưu, ghi đè
    token mới qua `withAccount`); làm mới thất bại vì lỗi Anisette
    thì báo đúng lỗi đó; lỗi khác (kể cả Apple đòi mã 2FA) thì giữ
    lỗi hết hạn gốc. Chỉ khi làm mới cũng thất bại mới coi là phiên
    hết hạn thật và bắt đăng nhập lại.
    (d) Lỗi ghi rõ bước + mã HTTP: `sessionExpired(step:status:)`,
    màn hình hiện vd "Phiên đăng nhập đã hết hạn (bước login, HTTP
    401). Hãy đăng nhập lại..." để lần sau chẩn đoán chính xác.
    Bước Commerce không sửa (thất bại ở đó không chặn danh sách).
  - Version: 2.0 build 14 (`CURRENT_PROJECT_VERSION` 13 → 14, chỉ
    trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0 ở cả
    xcconfig và pbxproj).
  - CI + IPA: remote `358bad18` (commit code `386526f`), CI "Build App"
    run 45588810275 `success` cả build-ios + build-osx, không lỗi lần
    nào. Artifact `NVDAppleIDDownload.ipa` (25.191.314 byte, chưa ký)
    tải về qua redirect-capture, ký ad-hoc bằng zsign `-a -z 9`
    (lưu ý: không có `-z` thì zsign xuất IPA không nén ~67 MB;
    có `-z 9` thì ~25,7 MB như các bản trước). IPA
    `deliver/NVDAppleIDDownload.ipa` (25.729.281 byte, SHA256
    `daac44d5500deb742737c7a9cea95d89b905b1b2e1e26a87c904c9d6298b4d06`):
    kiểm chứng 2.0 build 14, bundle `com.NVD.appleiddownload`, min
    iOS 17.0, binary có chuỗi mới ("Phiên đăng nhập đã hết hạn" 2 hit,
    "session expired, rotating token" 1 hit, ô tìm kiếm "Tìm tên app
    hoặc Bundle ID"), symbol PurchasedView/SearchView/SignRootView/
    WatchlistView, framework CydiaSubstrate đã embed, superblob hợp
    lệ (magic 0xfade0cc0, slot 0+2); thứ tự tab không đổi so với
    build 13 (diff bản này chỉ 2 file Swift + xcconfig, MainView
    không động). Build 13 giữ lại ở
    `deliver/NVDAppleIDDownload-2.0-build13-backup.ipa` (SHA256
    `750ad4a3…` khớp bản đã giao). Chưa kiểm chứng trên iPhone thật —
    cần anh test: mở tab Đã mua xem danh sách có hiện không (đừng
    đăng nhập lại vội — app sẽ tự làm mới token rồi mới báo), bấm
    "Đồng bộ lại" nếu cần; nếu vẫn báo hết hạn thì chụp lại câu lỗi
    (giờ có ghi bước + mã HTTP) và xem Cài đặt → Nhật ký dòng
    "Purchased DMAP: <bước> HTTP=<mã>".

- Đợt 5 build 15 (25 Nov 2026, 2.0 build 15): 2 lỗi anh chốt gộp
  chung 1 bản (Commerce HTTP 500 lúc 17:56 + nhập app khác vùng
  vào Đã mua lúc 17:55, đều sau khi bản 14 đã chạy được DMAP 368
  app). Chưa kiểm chứng trên iPhone thật.
  - LỖI 1 — Commerce HTTP 500: bấm "Đồng bộ toàn bộ lịch sử mua"
    thì Apple trả 500, banner cam (danh sách DMAP vẫn hiện). CHẨN
    ĐOÁN (đọc code + đối chiếu đường đang chạy): request Commerce
    là lệnh store DUY NHẤT trong app không gửi cả cookie phiên lẫn
    header Anisette — DMAP (đã chạy sau build 14), tải, đăng nhập,
    mua đều gửi cookie; DMAP/mua/đăng nhập đều gắn Anisette khi có
    máy chủ. Apple trả 500 chứ không phải 401/403, tức đã qua cửa
    xác thực rồi lỗi ở bước tra cứu phía máy chủ — khớp với thiếu
    cookie phiên (máy chủ cần cookie để tra đơn mua). FIX
    (`PurchasedCommerceService` + `PurchasedStore.syncFullHistory`):
    (a) `applyHeaders` gửi kèm cookie (`account.cookie.
    buildCookieHeader(url)`, đúng mẫu DMAP) + header Anisette;
    (b) `syncFullHistory` lấy header Anisette chung 1 lần trước
    bước Commerce (lấy không được thì bước này lỗi với đúng lỗi
    đó, như DMAP); (c) bước Commerce thử lại lỗi tạm thời tối đa
    3 lần, nghỉ 2 giây (dùng chung `isTransientSyncError` — lỗi
    500 khớp qua chuỗi "HTTP 500" trong thông báo). KHÔNG đổi
    method GET, SAP signature body rỗng, parser JSON:API, thứ tự
    Commerce-trước-DMAP. Giả thuyết mở (KHÔNG làm — chưa có bằng
    chứng): iPadn quét lịch sử theo từng năm (6 luồng song song
    theo năm), có thể endpoint cần tham số lọc năm; dạng
    request/response Commerce vẫn chưa xác minh bằng tài khoản thật
    — nếu sau bản này vẫn 500 thì cần log máy thật
    ("Purchased commerce: HTTP=<mã> bytes=<n>") rồi mới soi tiếp.
    Đường DMAP + tải không động (chỉ thêm header cho Commerce).
  - LỖI 2 — Nhập app khác vùng vào Đã mua vẫn lỗi redirect
    (tài khoản IN, app vùng US, 17:55 25/11): "Apple đã từ chối
    yêu cầu nhập vào Đã mua (máy chủ trả về chuyển hướng nhưng
    không có địa chỉ chuyển tiếp)". CHẨN ĐOÁN QUAN TRỌNG (đọc
    fork pin 541c43a): chuỗi "failed to retrieve redirect
    location" chỉ ném được ở `Authenticator.parseResponse` trong
    fork, tức là ở bước `rotatePasswordToken` (đăng nhập lại) —
    bước ĐẦU TIÊN của `acquireLicense`, TRƯỚC CẢ khi buyProduct
    chạy; và request authenticate không hề chứa vùng của app nên
    đây KHÔNG phải lỗi chặn theo vùng (vùng chỉ được xét ở
    buyProduct, chưa chạy tới). Nguyên nhân là cửa xác minh thiết
    bị của Apple: rotate gọi authenticate mà không có header
    Anisette (máy chủ Anisette chưa từng được triển khai — cài
    trên PC và Oracle VPS đều đã bỏ 24/11 — nên
    `anisetteHeadersForStoreCall()` trả về rỗng). Phiên đã lưu
    đã chứng minh còn sống (DMAP 368 app lúc 17:51 + tải chạy
    được cùng tài khoản) nên lỗi nằm ở bước làm mới, không phải
    ở phiên. FIX (`ProductView.acquireLicense`): (a) rotate chỉ
    còn là best-effort — lỗi cửa (redirect/204/lỗi tạm thời,
    đúng tập `isTransientPurchaseError`) thì giữ phiên đã lưu rồi
    thử mua tiếp bằng phiên đó; chỉ lỗi phán quyết thật (đòi mã
    2FA, sai mật khẩu, token hết hạn) mới dừng ngay. An toàn:
    `rotatePasswordToken` chỉ gán tài khoản mới khi authenticate
    thành công, và `withAccount` chỉ ghi lại tài khoản khi
    closure chạy xong không lỗi, nên rotate hỏng không làm bẩn
    tài khoản đã lưu; nếu token cũ thật sự chết thì buyProduct
    sẽ báo đúng lỗi hết hạn ("password token is expired") thay
    vì nhầm thành lỗi cửa. (b) buyProduct dùng
    `redirectConfiguration: .disallow` nên Apple chuyển hướng
    (vd sang pod vùng khác) sẽ trả về đúng mã 3xx — trước đây
    301/302/303/307/308 không có trong
    `isTransientPurchaseError` nên không retry và không dịch ra
    tiếng Việt; đã thêm vào cả hai chỗ, map về
    `PurchaseGateError.appleRedirectRefused`. (c) Lỗi cửa giờ
    nói rõ trạng thái máy chủ Anisette: 2 case mới
    `appleRedirectRefusedNoServer` /
    `appleEmptyResponseNoServer` ("Máy chưa cấu hình máy chủ
    Anisette (Cài đặt → Máy chủ Anisette) nên app không gửi được
    bằng chứng xác minh thiết bị mà Apple đòi...") khi chưa cấu
    hình máy chủ; đã cấu hình thì giữ câu cũ. Popup lệch vùng
    build 6 (2059/1010/-128) không động — lỗi này không phải lỗi
    vùng nên popup đó không kích hoạt. KHÔNG đụng Anisette
    on-device (đã kết luận không khả thi) và không đề xuất
    ipatool/PC làm giải pháp chính (câu lỗi cũ vẫn giữ
    ipatool 2.8.1 ở cuối như đường dự phòng, như trước).
  - Version: 2.0 build 15 (`CURRENT_PROJECT_VERSION` 14 → 15,
    chỉ trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0
    ở cả xcconfig và pbxproj).
  - CI + IPA: remote `e5fd260c` (commit code `23748c4`), CI "Build
    App" run 45600838987 `success` cả build-ios + build-osx (chạy
    ~21 phút: build-ios xong trước, build-osx xong sau; lưu ý lần
    này script poll đầu khớp nhầm run "Store download checks"
    45600839036 cùng head — phải lọc theo tên workflow "Build
    App", không chỉ head SHA). Artifact
    `NVDAppleIDDownload.ipa` (25.369.680 byte, chưa ký, SHA256
    `f121c8ba…`) tải về qua redirect-capture, ký ad-hoc bằng
    zsign `-a -z 9` (lưu ý như build 14: không có `-z` thì IPA
    không nén ~67 MB). IPA
    `deliver/NVDAppleIDDownload.ipa` (25.732.408 byte, SHA256
    `3f1bf7d72297bbf192761b4550556ca77b736ef5290dfc84ef4fb37d7b60cdf6`):
    kiểm chứng 2.0 build 15, bundle `com.NVD.appleiddownload`,
    min iOS 17.0, binary có chuỗi mới ("Máy chưa cấu hình máy chủ
    Anisette" 2 hit, "token rotation hit Apple gate" 1 hit),
    symbol PurchasedView/SearchView/SignRootView/WatchlistView,
    framework CydiaSubstrate đã embed, superblob hợp lệ (magic
    0xfade0cc0); thứ tự tab không đổi so với build 13/14 (diff
    bản này chỉ 3 file Swift + xcconfig, `MainView.swift` không
    động). Build 14 giữ lại ở
    `deliver/NVDAppleIDDownload-2.0-build14-backup.ipa` (SHA256
    `daac44d5…` khớp bản đã giao). Chưa kiểm chứng trên iPhone
    thật — cần anh test: (1) bấm "Đồng bộ toàn bộ lịch sử mua"
    xem còn banner HTTP 500 không, có gộp thêm app mua gần đây
    không; (2) mở app vùng US rồi bấm "Nhập vào Đã mua" bằng tài
    khoản IN xem còn lỗi redirect không, và app có vào được mục
    Đã mua không; nếu vẫn lỗi thì chụp lại câu lỗi mới (giờ có
    ghi rõ đã cấu hình máy chủ Anisette hay chưa).

## Đợt 5 build 16 — Commerce 500 (nguyên nhân thật theo iPadn) + dịch lỗi 2034 + bỏ mục Giới thiệu ở Cài đặt Ký IPA
  - Bằng chứng mới từ máy thật (18:43 + 18:54 + 18:57 25/11):
    (1) Commerce 500: log 18:30:43–18:30:49 "Purchased commerce: HTTP=500 bytes=38" 3 lần, xen retry 1/3 + 2/3, cuối "[error] Purchased full sync: commerce step failed" — 3/3 lần giống hệt nhau nên KHÔNG phải lỗi tạm thời; cookie + Anisette ở build 15 không sửa được.
    (2) Nhập vào Đã mua đổi dạng lỗi: không còn redirect, thành "password token is expired (failureType: 2034)" (app Muse from Meta vùng US, tài khoản IN, 18:43).
    (3) Máy chủ Anisette trong Cài đặt đã điền sẵn https://mac-ani.jkcoxson.com — máy chủ CÔNG CỘNG của bên thứ ba (jkcoxson), KHÔNG phải máy chủ riêng của anh; manifest vẫn là nvd-manifest của anh. Kết luận build 15 ("máy chủ Anisette chưa từng triển khai nên anisetteHeadersForStoreCall() trả rỗng") là SAI — đã bị bác bỏ bằng 3 bằng chứng: log 18:30 "Anisette headers from user server for store call" + 3 lần Commerce chạy sau đó, và nút "Kiểm tra" lúc 18:57 trả "Kết nối OK — máy chủ đã trả 10 header Anisette." (AnisetteService.check: fetchHeaders thành công, đếm được 10 header JSON). Mọi giả định "chưa có máy chủ / máy chủ chết" đều đã bị bác bỏ bằng bằng chứng máy thật.
  - Lỗi 1 — Commerce 500, nguyên nhân thật (đối chiếu code iPadn v2.3.5, commit 4357456, AppleService.swift + DMAP.swift — học ý tưởng, KHÔNG copy code, GPL-2.0): request của app (build 9–15) sai toàn bộ hình dạng — không có query nào (thiếu range + isDeepLink + isJsonApiFormat), gửi thừa Accept: application/vnd.api+json + X-Apple-I-* + X-GUID + chữ ký SAP trên GET rỗng (không lệnh store nào đang chạy ký GET rỗng), luôn dùng host thường thay vì host theo pod, không gộp Set-Cookie, parser tìm data dạng ARRAY + links.next trong khi response thật là data OBJECT với attributes.purchases (invoices → items) — nên kể cả trả 200 cũng lỗi unknownShape. Cookie + Anisette (build 15) không sửa được vì đó không phải chỗ hỏng. Bằng chứng tham số năm: iPadn gọi https://[p<pod>-]buy.itunes.apple.com/commerce/account/purchases?isDeepLink=false&isJsonApiFormat=true[&page=N]&range=<năm>-all (vd "2026-all"), quét từ năm hiện tại ngược về 2008; header đúng bộ: User-Agent, Accept-Language en-us, X-Dsid, X-Apple-Store-Front "<store>-1", Cookie, X-Token (không Accept, không X-Apple-I-*, không X-GUID, không chữ ký SAP); theo 302 tối đa 4 hop (mzcprh=1 + itspod), gộp Set-Cookie, bắt pod từ header pod/host URL; retry 429/5xx tối đa 3 lần (0.5s rồi 1.5s); 401/403 thì làm mới phiên.
    Sửa: viết lại PurchasedCommerceService.swift theo đúng hình dạng trên — quét từng năm (năm hiện tại → 2008, tuần tự; năm hiện tại lỗi thì throw nhanh, năm cũ lỗi thì bỏ qua + ghi log; chỉ throw khi không năm nào thành công), URL có isDeepLink=false&isJsonApiFormat=true&range=<năm>-all + page khi > 1, host theo pod (account.pod hoặc cookie itspod) + fallback host thường khi 404/5xx, header đúng bộ iPadn + vẫn gắn Anisette headers (cơ chế xác minh thiết bị của app; DMAP chạy được với cùng header), KHÔNG Accept/X-Apple-I-*/X-GUID/chữ ký SAP, theo 302 thủ công tối đa 4 hop (NoFollowRedirectDelegate), gộp Set-Cookie, bắt pod, retry 429/5xx + lỗi mạng tạm thời 3 lần (0.5s/1.5s), log body lỗi nguyên văn tối đa 500 ký tự (38 byte thì log hết), parser mới theo hình dạng invoices thật (data.attributes.purchases → invoices → items, is-complete, dedupe order-ID theo năm, kiểm tra kind là app, parse ngày có mili-giây) + giữ parser mảng cũ làm fallback một trang. Không đổi method GET, thứ tự Commerce-trước-DMAP. Nếu request đúng mà Apple vẫn 500 thì bước chẩn đoán tiếp (đã ghi, chưa làm): thử KHÔNG gắn Anisette headers (iPadn không gửi header xác minh thiết bị ở endpoint này) + đọc body lỗi đã log.
  - Lỗi 2 — rotate → 2034: đã kiểm chứng đường header KHÔNG bị rơi ở bước nào. Phía app: ProductView.acquireLicense:428 lấy header qua vm.anisetteHeadersForStoreCall() rồi truyền vào rotatePasswordToken:444 (PurchasedStore:141-143 tương tự); anisetteHeadersForStoreCall (AuthenticationService.swift:164-175) lấy header từ máy chủ khi URL đã đặt, lấy hỏng thì throw (không gọi thiếu header). Phía fork ApplePackage pin 541c43a: rotatePasswordToken → authenticate(email:password:cookies:anisetteHeaders:) → Authenticator mới → setAnisetteHeaders → authenticate() → makeRequest gắn header trước chữ ký SAP. Kết quả Kiểm tra 10 header + log 18:30 chứng minh header lấy về được và có đi vào request. Hướng còn lại: (a) header từ máy chủ của máy khác (jkcoxson) có thể bị Apple từ chối ở cửa authenticate vì Anisette gắn với thiết bị của máy chủ, không phải iPhone của anh — nếu đúng thì đường sửa là máy chủ Anisette gắn với thiết bị của anh, KHÔNG phải đổi code gọi (triển khai máy chủ riêng đã bỏ tối 24/11 — PC + Oracle VPS — không nhắc lại, chỉ làm khi anh chốt); (b) token cũ hết hạn thật, rotate không cứu được → 2034 ở buyProduct là hệ quả. Mật khẩu: đã xác minh Account lưu password (fork ApplePackage, Account.password) nên rotate có mật khẩu để tự xác thực lại — không phải do thiếu mật khẩu lưu.
    Sửa trong bản này: thêm PurchaseGateError.passwordTokenExpired + dịch 2034 ra tiếng Việt rõ ràng ("Phiên đăng nhập của tài khoản này đã hết hạn (mã 2034) — app đã thử làm mới lặng lẽ nhưng Apple không chấp nhận. Hãy đăng nhập lại tài khoản ở tab Tài khoản rồi bấm \"Nhập vào Đã mua\" lại."); acquireLicense ghi log chuỗi lỗi khi rotate hỏng trước rồi buyProduct sau đó báo 2034 (để lần sau soi được rotate lỗi gì — log 18:43 chỉ thấy câu 2034 cuối cùng).
  - Mục Giới thiệu ở Cài đặt Ký IPA: bỏ theo lệnh anh 18:56 25/11 (ảnh DAA7D340). Đã kiểm chứng TRƯỚC khi xoá: Cài đặt chính (SettingView About) đã có đủ bằng chữ: Asspp của Lakr233 (MIT), SayoSign của murk-sus (GPL-3.0), BorderBeam của ismnoiet (MIT); THIẾU 3 thứ nên đã CHUYỂN sang Cài đặt chính thay vì xoá mất: link GitHub, dòng Twemoji (CC-BY 4.0), link BorderBeam. Lưu ý: link GitHub trong Sign About trỏ về https://github.com/nvd29u1/NVDAppleIDDownload (repo app gộp) — giữ nguyên URL này khi chuyển, không dùng nvd29u1/SayoSign (URL đó là của thời NVDsign). Chỉ động đúng mục Giới thiệu đó: tiêu đề "Cài đặt" + mọi dòng cài đặt khác trong SignSettingsView giữ nguyên; Cài đặt chính chỉ thêm 3 dòng credit, không động gì khác.
  - Version: 2.0 build 16 (CURRENT_PROJECT_VERSION 15 → 16, chỉ trong Version.xcconfig; MARKETING_VERSION giữ 2.0 ở cả xcconfig và pbxproj).
  - CI + IPA: remote 3020d89c (commit code 2b185bc + d95fe97), CI "Build App" run 45609924263 success cả build-ios + build-osx (~20 phút). Artifact NVDAppleIDDownload.ipa (25.384.888 byte, chưa ký) tải về qua redirect-capture, ký ad-hoc bằng zsign -a -z 9. LƯU Ý: lần ký đầu THẤT BẠI vì /tmp đầy (tmpfs 512M, còn 70M — đọng /tmp/build13 112M + /tmp/nvdad12 + /tmp/entcheck + /tmp/b13check + /tmp/nvd14* từ các bản trước); đã xoá các thư mục check cũ trong /tmp (giữ /tmp/ipadn-fresh 100M làm bằng chứng iPadn + /tmp/applepackage-fork) rồi ký lại thành công — lần sau ký mà lỗi thì kiểm tra df /tmp trước. IPA deliver/NVDAppleIDDownload.ipa (25.746.919 byte, SHA256 edb02e4e39e30ff6a1fd97e064cf536344c8718cb201ea281a978d78b959874d): kiểm chứng 2.0 build 16, bundle com.NVD.appleiddownload, min iOS 17.0, framework CydiaSubstrate đã embed, superblob hợp lệ (magic 0xfade0cc0, slot 0 + 2), binary có chuỗi mới ("Phiên đăng nhập của tài khoản này đã hết hạn" 1 hit, "token rotation failed earlier" 1 hit, NoFollowRedirectDelegate 3 hit, "Purchased commerce:" 1 hit, "links.next" 0 hit — parser cũ đã hết; "isJsonApiFormat"/"isDeepLink" 0 hit là ĐÚNG — chuỗi ngắn ≤15 byte Swift lưu dạng immediate, không có trong binary dạng literal, như bài học ".staging" ở build 13), credit đã chuyển còn đủ (GitHub 1 hit, Twemoji 1 hit, BorderBeam 1 hit); diff từ build 15 chỉ 5 file (xcconfig + PurchasedCommerceService + ProductView + SettingView + SignSettingsView) — MainView.swift không động (thứ tự tab giữ nguyên), PurchasedDMAPService + BackgroundDownloadService không động (đường DMAP + tải giữ nguyên). Build 15 giữ lại ở deliver/NVDAppleIDDownload-2.0-build15-backup.ipa (SHA256 3f1bf7d7… khớp bản đã giao). Chưa kiểm chứng trên iPhone thật — cần anh test: (1) bấm "Đồng bộ toàn bộ lịch sử mua" xem còn banner HTTP 500 không, có gộp thêm app mua gần đây không; nếu vẫn 500 thì chụp màn Nhật ký quanh dòng "Purchased commerce: HTTP=..." (giờ đã log body nguyên văn) để biết Apple chê cái gì; (2) mở app vùng US rồi bấm "Nhập vào Đã mua" bằng tài khoản IN — nếu vẫn lỗi thì câu lỗi mới phải là tiếng Việt rõ ràng (không còn câu thô "password token is expired (failureType: 2034)"), chụp lại câu lỗi + dòng log "acquireLicense: token rotation..." quanh đó.

- Đợt 5 build 17 (25 Nov 2026, 2.0 build 17): hạ min iOS 17.0 → 16.0 +
  LiveContainer guest + nút TrollStore + khoảng iOS ở Giới thiệu.
  Làm song song với bản 16 trên worktree riêng `b17` (base d95fe97),
  rebase lên main sau khi bản 16 giao xong (remote 9d04416b).
  1. Hạ min iOS: `IPHONEOS_DEPLOYMENT_TARGET` 17.0 → 16.0 ở
     `Configuration/Base.xcconfig:13` và cầu Rust
     `Resources/Scripts/compile.release.mobile.ci.sh:41` (libsayoidev.a).
     macOS target 15.0 không đụng; hook CydiaSubstrate đã 12.0.
  2. `@Observable` (iOS 17+) → `ObservableObject` + `@Published` (hoặc
     `objectWillChange.send()` ở setter Persist): 13 khai báo trong 12
     file — AppStore (9 cặp access/withMutation), AppPackageArchive (3),
     FollowStore, Downloads, PurchasedStore (11 `@Published`),
     PackageManifest, AppLockService, PriceComparisonService
     (UpdateCheckStore), Installer (`@MainActor @Published status`),
     WiFiTransferServer, SearchView (SearchFieldFocus), MainView
     (MainTabSelection). 29 điểm access/withMutation (4 file) đã bỏ;
     view đổi `@State var vm = …` → `@StateObject` (singleton sở hữu)
     hoặc `@ObservedObject` (truyền vào) — 31 điểm, 18 file, kể cả
     ExportIPAButton/PackageManifestRow (đọc `manifest.completed` nên
     `let` thường sẽ stale). `PublishedPersist.swift` đã có sẵn
     subscript `EnclosingSelf: ObservableObject` gửi objectWillChange
     nên không sửa. `DeviceManager.swift` (chỉ macOS, min 15.0) CỐ
     TÌNH giữ `@Observable` (2 khai báo: class + nested InstalledApp).
     `withObservationTracking` ở AppDelegate iOS/macOS → giữ
     `AnyCancellable` trên `Downloads.this.objectWillChange`, sink
     đọc lại trong `Task { @MainActor in }` (objectWillChange bắn
     TRƯỚC khi giá trị đổi).
  3. `ContentUnavailableView` ×5 → helper chung
     `NVDContentUnavailableView` trong `Interface/Utils/ViewBackports.swift`
     (dùng system view trên iOS 17+/macOS 14+, VStack fallback dưới đó):
     AccountView ×2, DownloadView, PurchasedView, WatchlistView.
  4. onChange 2 tham số ×8 → 1 tham số (không chỗ nào dùng giá trị cũ):
     AppLockService:94, ProductHistoryView:206, ProductView:296,
     SearchView:73,111,165, PurchasedView:95,101.
  5. Symbol effect ×3: `PackageView.swift:176` → modifier
     `symbolEffectReplaceIfAvailable()` (ViewBackports, gate iOS 17+);
     2 chỗ trong `DeviceCTLInstallSection.swift` (chỉ macOS) giữ nguyên.
  6. Gỡ dependency chết khỏi pbxproj + Package.resolved: ColorfulX
     (0 usage từ khi tab Welcome bị xoá ở build 10) và LookInsideServer
     (0 usage; binary, min OS chưa xác minh). pbxproj: đúng 12 object
     bị gỡ (2 PBXBuildFile, 2 Frameworks refs, 2 product dep + 2 target
     refs, 2 remote package refs + 2 project refs); Package.resolved:
     43 → 41 pin, JSON hợp lệ, diff gọn 18 dòng. Bài học: script gỡ
     pin đầu tiên parse sai chỉ số — `' : "colorfulx",'.split('"')[2]`
     là `','`, phải lấy `[1]` (đã sửa sang regex
     `"identity"\s*:\s*"([^"]+)"`).
  7. Chứng chỉ cá nhân / SideStore / AltStore: KHÔNG đổi gì. IPA CI
     thực tế không mang entitlement nào (superblob chỉ slot 0+2; CI
     ghi đè CODE_SIGN_ENTITLEMENTS=""), keychain group mặc định và
     ngoại lệ /private/tmp/ đều không phải rào cản — app đã chạy qua
     SideStore tài khoản free (build 11–15). AltStore cùng cơ chế cert
     free (chưa test trực tiếp trên máy anh).
  8. LiveContainer: helper mới `Interface/Sign/LiveContainerGuest.swift`
     — phát hiện guest bằng `Bundle.main.bundleIdentifier !=
     "com.NVD.appleiddownload"` (guest dlopen trong process host nên
     Bundle.main là của LiveContainer). Khi guest: banner cam đầu tab
     Ký IPA (SignRootView) + mờ nút nhập file (SignLibraryView "Import
     from Files", SignCertificatesView "Import .p12" + 2 nút chọn
     .p12/.mobileprovision) và nút cài (SignView "Install now",
     SignedRow "Install", context menu "Install without re-signing");
     Tải từ URL không cần nhập file nên giữ nguyên. Dòng hướng dẫn
     tĩnh trong mục Giới thiệu (Cài đặt chính). Tìm kiếm/xem/tải IPA
     foreground vẫn chạy được ở guest. Chưa kiểm chứng phát hiện guest
     trên máy thật — cần anh cài bản 17 vào LiveContainer thử nhập file
     để xác nhận banner hiện.
  9. TrollStore: không cần .tipa, chỉ cần .ipa chuẩn + min 16.0.
     Nối nút "Cài bằng TrollStore" vào `SignInstaller.openTrollStore`
     (trước đây dead code, 0 caller) ở màn chi tiết sau khi ký xong
     (SignView, cạnh "Install now"); chỉ hiện khi
     `trollStoreAvailable` (canOpenURL apple-magnifier://, scheme đã
     có trong LSApplicationQueriesSchemes). Máy anh iOS 27.0 KHÔNG dùng
     được TrollStore (vá từ 17.0.1) — tính năng này cho máy khác ở
     iOS 14.0–16.6.1/17.0, chưa test được trên máy anh.
  10. Giới thiệu (Cài đặt chính): thêm hàng "Hỗ trợ iOS 16.0 – 27.2"
      + tích xanh `checkmark.circle.fill` màu xanh khi iOS máy trong
      [16.0, 27.2] (so major.minor, bỏ patch), không tích + màu
      secondary khi ngoài khoảng; macOS chỉ hiện chữ, không check.
      Đầu dưới đọc từ `Bundle.main["MinimumOSVersion"]` (đổi min thì
      About tự cập nhật); đầu trên là hằng số duy nhất
      `maxSupportedIOSVersion = "27.2"` cạnh `version` trong
      `App/main.swift` (mốc ổn định anh chốt 19/11 — KHÔNG phải 27.0
      như báo cáo rà soát đề xuất); dòng ghi chú nhỏ giữ trung thực
      "Đã kiểm chứng tới iOS 27.0" (`testedIOSVersion`). Bổ sung link
      SayoSign còn thiếu sau khi bản 16 chuyển credit (chỉ chuyển chữ,
      chưa chuyển link). Logic check dùng
      `ProcessInfo.processInfo.operatingSystemVersion` (không cần
      UIKit) trong `isCurrentIOSSupported`.
  11. Chuỗi mới thêm vào `App/Localizable.xcstrings` (en + vi, 559 →
      562 key): "Install with TrollStore" / "Cài bằng TrollStore",
      "TrollStore is not installed" / "Chưa cài TrollStore", banner
      LiveContainer (en + vi).
  - Version: 2.0 build 17 (`CURRENT_PROJECT_VERSION` 16 → 17, chỉ
    trong `Version.xcconfig`; `MARKETING_VERSION` vẫn 2.0 ở cả xcconfig
    và pbxproj).
  - Kiểm chứng code-level (chưa có CI): `swiftc -parse` pass trên các
    file Swift đã sửa (parse only, không type-check); grep sweep: không
    còn `@Observable`/`access(keyPath`/`withMutation(keyPath`/
    `withObservationTracking` ngoài `DeviceManager.swift` (macOS) và
    comment giải thích; không còn onChange 2 tham số hay
    `ContentUnavailableView(` trần ngoài helper; không còn
    `.symbolEffect` không gate ngoài file macOS-only. CI build với
    target 16.0 là cửa kiểm chứng cuối cho Digger source,
    KeychainAccess min, LookInside (đã gỡ), NIO.
  12. Bổ sung 19:34 25/11 (anh chốt sau khi test bản 16, commit tiếp
      theo trên main — CI chạy lại): xoá ĐÚNG 1 dòng credit ở mục Giới
      thiệu (Cài đặt chính): "Được làm với 🎀 bởi tác giả gốc. Giấy
      phép GPL-3.0. Icon dùng Twemoji (CC-BY 4.0)." — giữ nguyên mọi
      credit còn lại (dòng Asspp/SayoSign/BorderBeam, link GitHub,
      link SayoSign, link BorderBeam) và các file LICENSE trong repo.
  13. Bổ sung 19:34 25/11 — Commerce 403 (bước chẩn đoán đã ghi ở
      bản 16): test bản 16 lúc 19:31:14–19:31:24Z — DMAP login/update
      HTTP 200 (danh sách 368 app còn hiện), Commerce trả HTTP 403
      bytes=50 body={"status":-1,"errors":[{"code":"authentication"}]}
      thay vì 500 (hình dạng request đã đúng, Apple trả lời rõ ràng
      nhưng từ chối xác thực; năm 2026 fail và bị skip,
      PurchasedCommerceError code=2). Sửa: bước Commerce KHÔNG gửi
      Anisette headers nữa (iPadn không gửi header xác minh thiết bị
      ở endpoint này — điểm khác duy nhất còn lại); chỉ đổi đúng chỗ
      đó — PurchasedStore bỏ luôn lệnh fetch header ở bước Commerce
      (không còn phụ thuộc máy chủ Anisette), gọi
      fetchAllPurchasedApps(account:) với mặc định [:]; giữ nguyên
      cookie + X-Token + query range theo năm + host theo pod +
      parser invoices. Tham số anisetteHeaders trong
      PurchasedCommerceService giữ lại (mặc định rỗng) để dễ hoàn tác;
      DMAP (PurchasedDMAPService:212, PurchasedStore:138) và đường mua
      (ProductView:428) vẫn gửi Anisette headers như cũ. Nếu vẫn 403
      thì log body nguyên văn (đã có từ build 16) để soi tiếp — không
      đoán thêm, không đổi endpoint/method/parser. (Lỗi NSURLError
      -1005 lúc 12:31:20Z trong log chỉ là rớt mạng thoáng qua rồi
      thử lại, không phải lỗi cần sửa.)
  - CI lần 1 FAIL (run 45615578760, head 375815e6, cả build-ios +
    build-osx đều lỗi ở bước Build — log tải qua API
    `/actions/jobs/{id}/logs`, endpoint trả text thuần, không phải
    zip): 3 lỗi iOS / 1 lỗi macOS. (a) 2× `'onChange(of:initial:_:)'
    is only available in iOS 17.0 or newer` ở AddAccountView:124-125
    — closure 0 tham số `{ resetAuthentication() }` chỉ khớp overload
    iOS 17+; đã sửa thành `{ _ in resetAuthentication() }` (overload
    1 tham số có từ iOS 14). Bài học: sweep onChange phải gồm cả
    closure 0 tham số, không chỉ 2 tham số — rà lại toàn repo: mọi
    `.onChange(of:` còn lại đều dùng closure 1 tham số, sạch.
    (b) 1× `cannot assign value of type 'State<AppPackageArchive>' to
    type 'ObservedObject<AppPackageArchive>'` ở ProductView:22 — lỗi
    phân loại của đợt chuyển đổi: archive do view TỰ TẠO trong init
    (không phải truyền vào) nên phải là @StateObject (giữ ngữ nghĩa
    sở hữu như @State cũ), đã sửa khai báo + init sang
    `StateObject(wrappedValue:)`; đã kiểm tra lại các @ObservedObject
    khác (ProductHistoryView.vm, InstallerView.installer,
    PackageView.pkg, PackageManifestRow/ExportIPAButton.manifest)
    đều là truyền vào nên đúng. 2 warning còn lại không chặn build.
    Fix ở commit tiếp theo trên main, CI chạy lại.
  - CI + IPA: (bổ sung sau khi CI lần 2 pass).
  - Chưa kiểm chứng trên iPhone thật — cần anh test: (1) cài bản 17
    qua SideStore như mọi khi, mở app, kiểm tra tab Ký IPA/Tìm kiếm/
    Lượt tải/Tài khoản còn đúng thứ tự, Đã mua đồng bộ được (đường
    DMAP + Commerce của bản 16 không động); (2) mục Giới thiệu ở Cài
    đặt chính hiện "Hỗ trợ iOS 16.0 – 27.2" kèm tích xanh; (3) cài bản
    17 vào LiveContainer, mở tab Ký IPA xem banner cam có hiện và các
    nút nhập/cài có mờ đi không.
