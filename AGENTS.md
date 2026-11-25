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

xcconfig hierarchy: `Debug.xcconfig`/`Release.xcconfig` → `Base.xcconfig` → `Version.xcconfig`, plus `Developer.xcconfig` for signing. Version numbers live in `Configuration/Version.xcconfig` — BUT `MARKETING_VERSION` is also pinned in `Asspp.xcodeproj/project.pbxproj` (target Debug + Release build settings), and the pbxproj value overrides the xcconfig, so a version bump must change BOTH places or the built app keeps the old version. `CURRENT_PROJECT_VERSION` (build number) lives only in `Version.xcconfig`. From build 5 the app uses its own version **2.0** (build stays 5, no reset — the CI scripts never touch version numbers) instead of upstream Asspp 4.2.2; the About section in Settings shows "`<MARKETING_VERSION> <build>`" (e.g. "2.0 5") from `Bundle.main` info dictionary (`main.swift`, `SettingView`).

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
