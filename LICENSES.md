# Giấy phép (Licenses)

App này trộn code từ 3 nguồn, mỗi phần giữ giấy phép gốc của nó (anh Dũng chốt
trộn giấy phép 23:24 25/11/2026 — "giờ cho lẫn lộn luôn đi").

## 1. MIT — Asspp gốc (Lakr233 / Lakr Aream)
- **Phần code:** toàn bộ app gốc Asspp (giao diện, tải/tìm kiếm/cài đặt IPA,
  backend App Store qua ApplePackage) trừ 2 phần dưới.
- **Nguồn:** https://github.com/Lakr233/Asspp (Asspp 4.2.2, đã archive 18/11/2026)
- **File giấy phép:** [`LICENSE`](./LICENSE)

## 2. GPL-3.0 — SayoSign (murk-sus), phần Ký IPA
- **Phần code:** tab "Ký IPA" và toàn bộ tính năng ký/cài IPA —
  `NVDAppleIDDownload/Interface/Sign/`, `core/`, `rust/sayoidev/`, `hook/`
  (port từ fork nvd29u1/SayoSign nhánh nvd, v1.4).
- **Nguồn:** https://github.com/murk-sus/SayoSign
- **File giấy phép:** [`LICENSE-SayoSign-GPL-3.0`](./LICENSE-SayoSign-GPL-3.0)

## 3. GPL-2.0-or-later — iPadn (mengangs), phần Đăng nhập
- **Phần code:** hệ đăng nhập port trực tiếp từ iPadn v2.3.5 (commit c7be403) —
  `NVDAppleIDDownload/Backend/IPadnLogin/` (HTTPClient URLSession, AppleAuthentication,
  SAPSigner + LoopbackServer chạy runtime SAP bằng WASM, ApplePropertyList, LoginService)
  và `NVDAppleIDDownload/SAPRuntime/` (runtime SAP: sap.wasm, sap-signer.js,
  wasm_exec.js, unicorn_x86.js, libCoreADI.so, libstoreservicescore.so, index.html).
  Lưu ý: `sap.wasm` (~50 MB) quá lớn cho một blob Git Data API nên repo chỉ
  lưu dạng chia nhỏ `sap.wasm.part00..05` (8 MB/mảnh); script CI
  (`Resources/Scripts/compile.release.mobile.ci.sh`) ghép lại thành
  `sap.wasm` trước khi build và kiểm tra SHA-256
  `b7150bb4d31a03c1a813d310c0b5d7211be2510f7ee970b273f4fce7ea134015`
  (khớp manifest.json của iPadn).
- **Nguồn:** https://github.com/mengangs/ipadn — README của iPadn ghi rõ
  "GPL-2.0-or-later" (không phải v2-only); các file Swift gốc không mang header
  giấy phép riêng, giấy phép áp dụng là LICENSE của repo iPadn.
- **File giấy phép:** [`LICENSE-iPadn-GPL-2.0`](./LICENSE-iPadn-GPL-2.0)
  (bản text GPL-2.0 từ repo iPadn; "or later" theo tuyên bố trong README iPadn).

### Lưu ý về SAPRuntime
- Theo `NVDAppleIDDownload/SAPRuntime/PROVENANCE.json` (gốc iPadn):
  `sap.wasm`, `unicorn_x86.js`, `wasm_exec.js`, `libCoreADI.so`,
  `libstoreservicescore.so` lấy nguyên từ bản phát hành `IPA-Tool-3.0.scripting`
  (tác giả 小白脸, https://github.com/ScriptingApp/Community-Scripts,
  commit f9509c530b730d8be36639db5b7825cadb431898);
  `libCoreADI.so` + `libstoreservicescore.so` lấy từ gói Apple Music for
  Android x86_64 chính thức (đã xác minh SHA-256);
  `sap-signer.js` do iPadn viết lại, `index.html` do iPadn viết.
  Văn bản giấy phép kèm theo: `Go-BSD-3-Clause.txt`, `LGPL-2.0.txt`.
  iPadn tự ghi: "complete license grant for all components not established"
  (chưa xác lập đầy đủ quyền cấp phép cho mọi thành phần) — ghi lại đúng
  như vậy, không khẳng định thêm.
- Các file này chỉ phục vụ chữ ký SAP trên máy (xác minh thiết bị của Apple);
  không gửi mật khẩu Apple ID hay token đi đâu ngoài máy chủ Apple.

## Tóm tắt
| Phần | Nguồn | Giấy phép |
|---|---|---|
| App gốc (tìm/tải/cài IPA, backend store) | Asspp — Lakr233 | MIT |
| Ký IPA | SayoSign — murk-sus | GPL-3.0 |
| Đăng nhập (SAP + request authenticate) | iPadn — mengangs | GPL-2.0-or-later |
