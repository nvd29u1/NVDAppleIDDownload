# NVDAppleIDDownload

> Tải file IPA từ App Store ngay trên iPhone, không cần máy tính. Đăng nhập bằng Apple ID sở hữu app, chọn app, tải về rồi cài trực tiếp trên máy.
>
> **Bản 3.0:** lõi đăng nhập, Đã mua và tải dùng lõi iPadn; giao diện NVD giữ nguyên — nền mận đậm, logo lợn xanh, tiếng Việt.

[🇻🇳 Tiếng Việt](#tiếng-việt) · [🇬🇧 English](#english) · [Hỗ trợ / Support](#hỗ-trợ--support)

---

## Tiếng Việt

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2016.0%E2%80%9327.2-blue?style=flat-square&logo=apple" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-6.2-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Rust-FFI%20Core-red?style=flat-square&logo=rust" alt="Rust" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License" />
</p>

### Tính năng

- **Tìm kiếm:** tìm app trên App Store, xem giá, dung lượng, lịch sử phiên bản; chọn phiên bản cũ để tải khi Apple còn cho.
- **Đã mua:** đồng bộ danh sách app đã mua của tài khoản, gồm cả lịch sử mua đầy đủ; nhập app miễn phí vào Đã mua (chỉ đúng vùng của tài khoản).
- **Lượt tải:** hàng đợi tải tối đa 3 file cùng lúc, tải nền, tải xong tự cài đặt (tuỳ chọn); xuất file IPA đã tải qua Share Sheet để lưu vào Tệp hoặc gửi qua AirDrop; xem nội dung file IPA; chia sẻ IPA qua Wi-Fi cho máy tính cùng mạng.
- **Ký IPA:** ký file IPA bằng chứng chỉ `.p12` + `.mobileprovision`, hoặc đăng nhập Apple ID để ký; cài trực tiếp trên máy.
- **Đang theo dõi:** theo dõi app, xem giá hiện tại và lịch sử giá; so giá app ở các vùng đã chọn.
- **Tài khoản:** đăng nhập nhiều Apple ID, mỗi tài khoản giữ đúng vùng của nó; màn chi tiết app tự chọn tài khoản đúng vùng.
- **Cài đặt:** khoá app bằng Face ID / Touch ID / mật khẩu; chọn máy chủ Anisette; chọn máy chủ manifest để cài app (mặc định `nvd-manifest`); xem nhật ký app.
- **Hỗ trợ:** iOS 16.0–27.2 (đã kiểm chứng thật tới iOS 27.0) và macOS 15.0 trở lên; cài qua chứng chỉ cá nhân, SideStore, AltStore, LiveContainer hoặc TrollStore.

### Cài đặt

Cài bằng chứng chỉ cá nhân của bạn qua một trong các công cụ sau:

- **SideStore** — cài file IPA bằng chứng chỉ cá nhân (Apple ID miễn phí), tự gia hạn trên máy.
- **AltStore** — cài file IPA bằng chứng chỉ cá nhân, gia hạn qua AltServer.
- **LiveContainer** — chạy app ngay trong LiveContainer mà không cần cài thật (chỉ chạy và xem; tính năng ký IPA không dùng được trong LiveContainer).
- **TrollStore** — cài trực tiếp trên máy (chỉ các phiên bản iOS được TrollStore hỗ trợ).

Tải file IPA ở mục [Releases](../../releases) rồi cài bằng công cụ bạn đang dùng. Lần đầu mở app, cấp quyền cần thiết khi hệ thống hỏi.

### Cách dùng

1. **Đăng nhập Apple ID:** mở tab Tài khoản, thêm Apple ID sở hữu app bạn muốn tải. Có thể đăng nhập nhiều tài khoản, mỗi tài khoản giữ đúng vùng của nó.
2. **Tìm kiếm:** mở tab Tìm kiếm, gõ tên app, xem giá, dung lượng và lịch sử phiên bản; chọn phiên bản muốn tải.
3. **Tải IPA:** bấm tải ở màn chi tiết app; file IPA tải về nằm trong tab Lượt tải (tối đa 3 file cùng lúc, hỗ trợ tải nền).
4. **Nhập vào Đã mua:** với app miễn phí, bấm "Nhập vào Đã mua" ở màn chi tiết app để app có trong danh sách Đã mua của tài khoản (chỉ đúng vùng của tài khoản; app chỉ có ở vùng khác thì Apple không cho nhập).
5. **Ký IPA:** mở tab Ký IPA, chọn file IPA rồi ký bằng chứng chỉ `.p12` + `.mobileprovision` của bạn, hoặc đăng nhập Apple ID để ký; ký xong cài trực tiếp trên máy.

### Giấy phép

App trộn code từ nhiều nguồn mở, mỗi phần giữ giấy phép gốc của nó (xem chi tiết trong [`LICENSES.md`](./LICENSES.md); văn bản đầy đủ của từng giấy phép nằm trong các file LICENSE ở gốc repo):

- **App gốc Asspp** — MIT — [`LICENSE`](./LICENSE)
- **Tính năng ký IPA** — GPL-3.0 — [`LICENSE-SayoSign-GPL-3.0`](./LICENSE-SayoSign-GPL-3.0)
- **Đăng nhập + lõi cửa hàng (iPadn)** — GPL-2.0-or-later — [`LICENSE-iPadn-GPL-2.0`](./LICENSE-iPadn-GPL-2.0)
- **Hiệu ứng viền sáng BorderBeam** — MIT — [github.com/ismnoiet/border-beam-ios](https://github.com/ismnoiet/border-beam-ios)

---

## English

> Download IPA files from the App Store right on your iPhone, no computer needed. Sign in with the Apple ID that owns the app, pick the app, download it, then install it directly on the device.
>
> **Version 3.0:** sign-in, Purchased and download use the iPadn core; the NVD interface stays the same — dark plum background, green pig logo, Vietnamese UI.

### Features

- **Search:** search the App Store, see price, size and version history; download an older version when Apple still serves it.
- **Purchased:** sync the account's purchased apps, including full purchase history; add a free app to Purchased (only in the account's own region).
- **Downloads:** queue of up to 3 simultaneous downloads, background downloads, optional auto-install when a download finishes; export a downloaded IPA via Share Sheet to save to Files or send via AirDrop; browse IPA contents; share IPAs over Wi-Fi to a computer on the same network.
- **Sign IPA:** sign an IPA with your `.p12` certificate + `.mobileprovision`, or sign in with an Apple ID to sign; install directly on the device.
- **Watchlist:** follow apps, see the current price and price history; compare an app's price across selected regions.
- **Accounts:** sign in with multiple Apple IDs, each keeping its own region; the app detail screen auto-selects the account matching the app's region.
- **Settings:** lock the app with Face ID / Touch ID / passcode; choose an Anisette server; choose a manifest server for installing apps (default `nvd-manifest`); view the app log.

### Installation

Install with your personal certificate using one of these tools:

- **SideStore** — install the IPA with a personal certificate (free Apple ID), self-renewing on-device.
- **AltStore** — install the IPA with a personal certificate, renewed via AltServer.
- **LiveContainer** — run the app inside LiveContainer without installing it for real (run and browse only; IPA signing does not work inside LiveContainer).
- **TrollStore** — install directly on-device (only on iOS versions supported by TrollStore).

Download the IPA from [Releases](../../releases) and install it with the tool you use. On first launch, grant the permissions the system asks for.

### Usage

1. **Sign in with an Apple ID:** open the Accounts tab and add the Apple ID that owns the apps you want to download. You can sign in with multiple accounts, each keeping its own region.
2. **Search:** open the Search tab, type an app name, see its price, size and version history; pick the version to download.
3. **Download an IPA:** tap download on the app detail screen; the IPA lands in the Downloads tab (up to 3 files at once, background downloads supported).
4. **Add to Purchased:** for a free app, tap "Add to Purchased" on the app detail screen so it appears in the account's Purchased list (only in the account's own region; Apple does not allow adding an app that exists only in another region).
5. **Sign an IPA:** open the Sign IPA tab, pick an IPA file and sign it with your `.p12` certificate + `.mobileprovision`, or sign in with an Apple ID to sign; install directly on the device after signing.

### License

The app mixes code from several open-source projects, each keeping its original license (see [`LICENSES.md`](./LICENSES.md) for details; the full text of each license is in the LICENSE files at the repo root):

- **Original Asspp app** — MIT — [`LICENSE`](./LICENSE)
- **IPA signing feature** — GPL-3.0 — [`LICENSE-SayoSign-GPL-3.0`](./LICENSE-SayoSign-GPL-3.0)
- **Sign-in + store core (iPadn)** — GPL-2.0-or-later — [`LICENSE-iPadn-GPL-2.0`](./LICENSE-iPadn-GPL-2.0)
- **BorderBeam glow effect** — MIT — [github.com/ismnoiet/border-beam-ios](https://github.com/ismnoiet/border-beam-ios)

---

## Hỗ trợ / Support

- **iOS 16.0–27.2** (đã kiểm chứng thật tới iOS 27.0 / verified on a real device up to iOS 27.0).
- **macOS 15.0** trở lên / and later.
- Cài qua chứng chỉ cá nhân, SideStore, AltStore, LiveContainer hoặc TrollStore / Install with a personal certificate via SideStore, AltStore, LiveContainer or TrollStore.
