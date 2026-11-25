# NVDAppleIDDownload

> **NVDAppleIDDownload của nvd29u1, dựa trên Asspp của Lakr233 (MIT).**
> Tải file IPA từ App Store ngay trên iPhone, không cần máy tính. Đăng nhập bằng
> Apple ID sở hữu app, chọn app, tải về rồi cài trực tiếp trên máy.
>
> Gốc: https://github.com/Lakr233/Asspp — bản 4.2.2, giấy phép MIT,
> Copyright (c) 2025 Lakr Aream. Mọi quyền và ghi công của tác giả gốc được giữ
> nguyên trong file `LICENSE`.
>
> **Phiên bản riêng 2.0 (từ build 5):** từ build 5 trở đi app dùng version
> riêng **2.0** thay vì version gốc Asspp 4.2.2; số build giữ nguyên, không
> reset về 1 — script CI không đụng tới version, `MARKETING_VERSION` nằm ở
> `Configuration/Version.xcconfig` và cả 2 cấu hình Debug/Release của target
> trong `Asspp.xcodeproj/project.pbxproj`.
>
> **Giao diện NVD:** nền mận đậm, logo lợn xanh, tiếng Việt.
>
> **Máy chủ manifest mặc định:** https://nvd-manifest.nguyenvietdung156195.workers.dev
> (worker Cloudflare riêng của nvd29u1 — chỉ tạo file manifest, file IPA không
> đi qua máy chủ này). Xoá trắng ô "Cài đặt app" trong Cài đặt để về lại máy chủ
> local trên máy (cần cài đặt và tin cậy chứng chỉ "NVD Local Installation CA").

## Giới hạn cần biết

- Tải IPA từ App Store bắt buộc phải đăng nhập Apple ID sở hữu app đó.
  Không tải được IPA "sạch" đã giải mã mà không cần đăng nhập.
- File IPA tải về vẫn mã hoá FairPlay, chưa giải mã để cài qua SideStore.
  Muốn có IPA đã giải mã phải giải mã trên thiết bị đã jailbreak hoặc bằng
  cách khác ngoài phạm vi app này.
- Nên dùng Apple ID phụ lần đầu.
- **Xuất file IPA:** app đã tải xong thì ở tab Lượt tải và màn hình chi tiết
  app có nút "Tải IPA về máy" — bấm để mở Share Sheet, lưu file `.ipa` vào
  Tệp hoặc chia sẻ qua AirDrop / app khác. Chỉ xuất đúng file đã tải
  (FairPlay, gắn với Apple ID đã mua), không giải mã, không đổi tên bundle.
- **Nhập vào Đã mua:** ở màn chi tiết app miễn phí có nút "Nhập vào Đã mua" —
  chỉ mua license để app vào danh sách Đã mua của Apple ID đó, không tải file
  IPA. App trả phí không dùng được nút này. Một tài khoản không mua được
  license ở vùng khác — Apple chỉ cho nhập vào Đã mua ở đúng vùng của tài
  khoản; nút vẫn bấm được khi lệch vùng (app có ở cả hai vùng thì vẫn nhập
  được), nếu Apple từ chối thì app báo rõ bằng tiếng Việt và gợi ý thêm tài
  khoản đúng vùng ở tab Tài khoản.
- **Lịch sử phiên bản:** chọn phiên bản cũ không còn báo "AuthenticationError 0"
  — app tự dùng tài khoản đang đăng nhập cho region đó, thử lại tối đa 3 lần
  khi Apple trả lỗi tạm thời, và báo lỗi tiếng Việt rõ ràng nếu vẫn lỗi. Mỗi
  dòng hiện dung lượng IPA + ghi chú cập nhật (khi Apple trả trong metadata),
  bấm giữ 1 dòng để copy số version / version ID; app đã tải xong có nút
  "Giữ phiên bản này" (đã giữ thì tab Lượt tải không nhắc bản mới nữa).
- **Vùng tài khoản:** màn chi tiết app liệt kê mọi tài khoản đã đăng nhập
  (đúng vùng trước, khác vùng sau, có ghi mã vùng và chữ "khác vùng"); không
  có tài khoản đúng vùng thì tự chọn tài khoản đang đăng nhập và hiện cảnh báo
  vùng màu cam. Nút "Yêu cầu tải" và "Nhập vào Đã mua" chỉ mờ khi chưa đăng
  nhập tài khoản nào.
- **Theo dõi / so giá:** theo dõi app ở màn chi tiết, xem giá hiện tại + lịch
  sử giá ở màn "Đang theo dõi" (tra qua iTunes Lookup công khai khi mở màn,
  không chạy nền). Mục "So giá các vùng" ở màn chi tiết so giá app ở các vùng
  ưa thích đã chọn, xếp từ rẻ đến đắt, mỗi vùng hiện theo tiền tệ của vùng đó
  (chưa quy đổi sang VNĐ). Tab Lượt tải hiện nhãn "Có bản mới" khi app đã tải
  có bản mới trên Store (chỉ tra khi mở tab).
- **Chia sẻ IPA qua Wi-Fi:** bật trong Cài đặt rồi mở màn chia sẻ, máy tính
  cùng Wi-Fi gõ địa chỉ IP:cổng để tải IPA đã tải xong; rời màn là máy chủ tắt.
- **Xem nội dung IPA:** màn chi tiết gói đã tải có nút "Xem nội dung IPA"
  (liệt kê file trong ZIP, xem trước file text nhỏ / ảnh, trích 1 file ra
  Share Sheet). **Khoá app** bằng Face ID / Touch ID / mật khẩu trong Cài đặt
  (LocalAuthentication, không lưu mật khẩu; mở app lên là khoá, rời app thì
  khoá lại).
- **Cài qua AltStore source:** thêm URL
  `https://raw.githubusercontent.com/nvd29u1/NVDAppleIDDownload/main/altstore-source.json`
  vào SideStore / AltStore / Feather (Add Source), app sẽ hiện trong nguồn để
  cài và cập nhật. Mỗi lần phát hành bản mới (tag release) phải cập nhật
  `version`, `versionDate`, `versionDescription` và `downloadURL` trong
  `altstore-source.json` theo đúng tag/asset của release đó — hiện file đang
  trỏ tới asset `v2.0.8/NVDAppleIDDownload.ipa` (chưa có tag này thì link chưa
  tải được cho tới khi tag release).
- **Chưa làm được: tải PKG Mac** — thư viện ApplePackage (fork nvd29u1) chỉ có
  EntityType iPhone/iPad/AppleTV, không có endpoint tải PKG Mac App Store;
  muốn làm phải thêm giao thức mới vào fork rồi kiểm chứng, để đợt sau.

- Đăng nhập báo `authentication failed: HTTP 204`: máy chủ Apple trả về
  trống, chưa xét mật khẩu — không phải sai mật khẩu hay thiếu mã 2FA.
  Từ 06/11/2026 Apple yêu cầu xác minh thiết bị (Anisette/ADI) khi đăng
  nhập App Store, mà thư viện ApplePackage 2.0.3 chưa có; app sẽ tự thử
  lại 3 lần với phiên mới. Lỗi "failed to retrieve redirect location"
  cũng cùng họ này: Apple trả về chuyển hướng nhưng không có địa chỉ
  chuyển tiếp, tức là từ chối yêu cầu trước khi xét tài khoản — không
  phải sai mật khẩu. Kiểm tra lại email đã gõ đúng chưa (đúng là
  ...@gmail.com, không phải ...@gamil.com) rồi thử lại. Nếu vẫn lỗi: kiểm tra tài khoản trong App
  Store chính thức, thử mạng khác, hoặc dùng ipatool 2.8.1 trên máy tính.

## 📥 Cài đặt

### iOS

1. Tải file `.ipa` mới nhất ở [Releases](https://github.com/nvd29u1/NVDAppleIDDownload/releases).
2. Ký và cài bằng SideStore, AltStore hoặc công cụ ký khác.

### macOS

1. Tải file `.zip` mới nhất ở [Releases](https://github.com/nvd29u1/NVDAppleIDDownload/releases).
2. Giải nén rồi kéo `NVDAppleIDDownload.app` vào thư mục Applications. Lần đầu
   mở bị Gatekeeper chặn thì Control-click app rồi chọn Mở.

## 🛠 Requirements

- **iOS**: iOS 16.0 or later.
- **macOS**: macOS 15.0 or later.
- **Apple ID**: Required to communicate with App Store APIs.

## 🚨 Special Notice

NVDAppleIDDownload utilizes the same underlying communication protocol as `ipatool`. According to community speculation (unverified), previous outages of this protocol were likely caused by:
1. Widespread usage triggering Apple's risk control mechanisms.
2. Protocol modifications following the patching of an iCloud security vulnerability.
3. Adjustments to Apple's front-end gateways, which now enforce stricter traffic allocation and request validation.

Given the increasingly strict management of these APIs, **if the protocol becomes invalid again in the future, this project may not be able to provide further fixes.**

**⚠️ Important Security Warnings:**
1. **Protect your GUID:** Please treat your device GUID as a highly sensitive password. Never share or leak it to anyone.
2. **Do NOT use your primary Apple ID:** We strongly advise using a secondary or burner account with this tool. If your account is banned by Apple, it could potentially result in an unremovable Activation Lock on your device (while there are no confirmed cases of this happening yet, we cannot make any guarantees).

## ⚠️ Disclaimer

This project is for educational and research purposes only. It is not affiliated with Apple Inc. Use at your own risk.

## 🥰 Acknowledgments

- [ipatool](https://github.com/majd/ipatool)
- [ipatool-ios](https://github.com/dlevi309/ipatool-ios)
- [localhost.direct](https://get.localhost.direct/)

_`ipatool-ios` and `localhost.direct` are no longer used in the project._

## 📄 License

App này trộn 3 giấy phép — mỗi phần code giữ giấy phép gốc của nó
(xem chi tiết ở [LICENSES.md](./LICENSES.md)):

- **MIT** — app gốc Asspp (Lakr233). Xem [LICENSE](./LICENSE).
- **GPL-3.0** — phần Ký IPA, port từ SayoSign (murk-sus). Xem [LICENSE-SayoSign-GPL-3.0](./LICENSE-SayoSign-GPL-3.0).
- **GPL-2.0-or-later** — phần Đăng nhập, port từ iPadn (mengangs). Xem [LICENSE-iPadn-GPL-2.0](./LICENSE-iPadn-GPL-2.0).

---

Copyright © 2025 Lakr Aream. All Rights Reserved.
