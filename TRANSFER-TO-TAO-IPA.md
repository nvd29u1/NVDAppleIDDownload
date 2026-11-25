# Chuyển giao bản gộp NVDsign + NVDAppleIDDownload — sang chat phụ "tạo ipa"

Ngày chuyển: 25/11/2026 (theo lệnh của anh Dũng: "chuyển hết thông tin và kết quả sang đây").
Chat gốc: "ipatool từ GitHub" (fa427480-314b-48d5-8f60-f3cf50a19289). Từ giờ bản gộp làm ở chat "tạo ipa" này.

## 1. NVDAppleIDDownload — trạng thái đã chuyển sang

- Gốc: Lakr233/Asspp 4.2.2 (MIT), upstream đã archive 18/11/2026. Fork: https://github.com/nvd29u1/NVDAppleIDDownload, nhánh `main`.
- Remote head `dbb5e45` = local `c6e5eed` (cùng nội dung, khác SHA do push-tree) = **NVD 2.0 build 9**. Working copy `~/workspace/nvd-appleid-download/` sạch (tree clean).
- Bundle `com.NVD.appleiddownload`, version 2.0, min iOS 17.0, iPhone/iPad/Mac native (không Catalyst). Tiếng Việt chính + en + zh-Hans.
- Quy tắc version: MARKETING_VERSION bị ghim cả trong `Asspp.xcodeproj/project.pbxproj` (ghi đè xcconfig) — bump version phải sửa CẢ pbxproj lẫn `Configuration/Version.xcconfig`; build number chỉ ở Version.xcconfig.
- CI: `./Resources/Scripts/compile.release.mobile.ci.sh` (IPA unsigned iOS). Cài qua OTA bằng manifest worker `nvd-manifest` (mặc định) hoặc local HTTPS server + CA tự ký "NVD Local Installation CA" (hạn 21/11/2036).
- Tài khoản đúng: kithuatscn@gmail.com (từng gõ nhầm kithuatscn@gamil.com trong app). Tài khoản đã đăng nhập test: kumit.95bt@gmail.com (vùng IN).
- Tài liệu: `docs/IPADN-SO-SANH.md` (so sánh iPadn), `docs/ANISETTE-RESEARCH.md`. Ghi chú làm việc: `AGENTS.md` (symlink CLAUDE.md).

### Các bản đã có
- **2.0 build 5 — ĐÃ GIAO cho anh** (24/11): fix picker lệch vùng (tự chọn tài khoản, khác vùng vẫn chọn được + cảnh báo cam); giữ đủ tính năng build 4 (Tải IPA về máy, Nhập vào Đã mua, tìm kiếm theo tên/bundle ID, BorderBeam, 214 chuỗi tiếng Việt, icon lợn xanh). Đăng nhập ĐÃ ĐƯỢC 24/11 (tải Telegram 13.3 lúc 22:41, đăng nhập lại không cần 2FA).
- **Build 6–9 — đã commit (local + remote) nhưng CHƯA giao cho anh** (giữ lại để gộp vào "1 bản lớn"):
  - Build 6: chẩn đoán lệch vùng + tự refresh lịch sử + fix lỗi redirect khi mua.
  - Build 7: màn Đã mua DMAP + tìm kiếm 177 vùng; fix CI (import ButtonKit, EditButton chỉ iOS).
  - Build 8: lịch sử phiên bản giàu hơn + theo dõi/so giá + Wi-Fi transfer + xem IPA + khóa app.
  - Build 9: tải nền thật + Đã mua buộc Commerce + icon đúng từng phiên bản + tải xong tự cài đặt.
- File IPA mới nhất trong `deliver/`: `NVDAppleIDDownload.ipa` (10:09 25/11) = **version 2.0 build 8** — build 9 mới có code commit, chưa có IPA build xong/giao. Các file `NVDAppleIDDownload-1.1..1.7.ipa` là số thứ tự giao, không phải version app.

### Hạn chế đã biết (đã kiểm chứng trên máy anh)
- **Nhập app free khác vùng vào Đã mua vẫn KHÔNG được**: Apple chặn từ cửa xác thực, lỗi 'failed to retrieve redirect location' — app chưa có Anisette trên máy (khác iPadn làm SAP signing + Anisette on-device). Cảnh báo vùng ở build 5 chạy đúng.
- Máy chủ Anisette v1.0.0 đã giao 24/11 nhưng cài trên PC và Oracle VPS đều ĐÃ BỎ tối 24/11 — KHÔNG nhắc lại. Tài khoản Oracle Cloud chưa được tạo (Oracle từ chối đăng ký 24/11; thẻ Visa 5823 xác minh 2 lần mất phí không hoàn, 1 lần đã về +27.691 VND, 1 lần đang chờ tra soát MB Bank — việc này có cron riêng ở chat gốc, KHÔNG thuộc bản gộp).
- Port Anisette sang app KHÔNG khả thi; fallback là ipatool 2.8.1 trên PC.

### Tối ưu theo iPadn (anh chốt 25/11, 10 mục, làm theo đợt)
Nguồn: iPadn mengangs/ipadn v2.3.5, GPL-2.0 — CHỈ học ý tưởng, KHÔNG copy code. Các mục: (1) chẩn đoán lệch vùng + nút đổi tài khoản rồi thử lại; (2) license tự refresh; (3) màn Đã mua đầy đủ; (4) 177 vùng; (5) lịch sử phiên bản; (6) tải nền; (7) theo dõi + so giá; (8) Wi-Fi transfer; (9) cài native; (10) Anisette trên máy (cuối cùng). Builds 6–9 đã làm xong các mục 1–8 một phần (xem list build trên).
- Lưu ý: lần tối ưu đầu (25/11 rạng sáng) từng bị hệ thống chặn vì nội dung mới lấy từ repo có thể chạy mã trong lúc xử lý — đã báo anh, anh chốt tiếp tục.

## 2. NVDsign — trạng thái đã chuyển sang (làm ở chat này)

- Gốc: murk-sus/SayoSign V1.2.0 (GPL-3.0 — giữ ghi công murk-sus). Fork: https://github.com/nvd29u1/SayoSign, nhánh `nvd`, head `451036d4` = **v1.4 build 1, ĐÃ GIAO 11:08 24/11**.
- Bundle `com.NVD.sign`, chỉ tiếng Việt, logo lợn xanh, BorderBeam tất cả nút, máy chủ cài app mặc định là worker `nvd-manifest` của anh.
- Working copy `~/workspace/sayosign-check/nvd/`; file giao `~/workspace/sayosign-check/deliver/NVDsign.ipa` (9.859.617 byte, SHA256 `ebf48575…9843c`); hồ sơ đầy đủ ở `~/workspace/sayosign-check/NOTES.md`.
- Tính năng: ký bằng .p12 hoặc Apple ID, chèn tweak (SayoHook), cài offline, nhập IPA từ Tệp / từ file vừa tải, thư viện app đã ký, chạy app trong SayoSign.
- **Bài học bắt buộc:** NVDsign PHẢI cài trực tiếp qua SideStore — chạy trong LiveContainer thì iOS không coi là app thật, không nhận file qua Chia sẻ/Mở/Nhập từ Tệp (đã chứng minh 24/11 với file 3012-Unsigned.ipa; cài lại qua SideStore thì nhập được ngay).

## 3. Bản gộp — quyết định của anh (sáng 25/11, chat gốc)

- **Gộp toàn bộ chức năng NVDsign vào NVDAppleIDDownload, thành 1 app duy nhất.** Tải IPA xong bấm một cái là sang ký luôn trong đó (ký .p12 / Apple ID, chèn tweak, cài offline, nhập IPA từ Tệp và từ file vừa tải, thư viện app đã ký — đủ hết, không bớt cái nào).
- **Bỏ hẳn tab Trang chủ** (trang chủ cũ chỉ có logo + lời chào, trống trơn). Tổng hợp hết logo, lời chào, version, ghi chú vào mục Giới thiệu trong Cài đặt.
- Tab bar sau gộp còn 4 tab: **Tài khoản, Lượt tải, Ký IPA, Cài đặt**.
- **Giao 1 bản lớn duy nhất** (anh dặn ~10:26 25/11: không giao lẻ từng đợt nữa) — gồm toàn bộ tối ưu iPadn (build 6–9) + gộp NVDsign + bỏ tab Trang chủ.
- **Nguyên tắc gộp (anh dặn 12:38 25/11): gộp là thêm tab chứ không xoá bớt.** Build 10 gộp xong chỉ còn 4 tab (mất Tìm kiếm + Đã mua + Đang theo dõi) nên chưa giao; anh chốt trả lại 3 tab rồi mới giao — làm build 11 với đủ 7 tab: Tài khoản, Tìm kiếm, Đã mua, Đang theo dõi, Lượt tải, Ký IPA, Cài đặt.
- Trạng thái lúc chuyển (10:35 25/11): **code gộp CHƯA bắt đầu** — trong working copy chưa có code NVDsign nào; bản chạy trong chat gốc (coordinator bắt đầu ~07:20 25/11) đã làm xong build 6–9 và đang tiếp tục phần gộp. File IPA mới nhất đã build là 2.0 build 8.

## 4. Việc còn lại

1. Quyết: bản gộp tiếp tục chạy ở chat gốc cho tới khi xong, hay dừng bên đó để chat "tạo ipa" này tiếp quản (tránh 2 bên cùng sửa 1 repo/nhánh).
2. Làm phần gộp NVDsign + bỏ tab Trang chủ, build CI, kiểm chứng, giao 1 bản lớn duy nhất cho anh (cài qua SideStore).
3. Mục Anisette trên máy (mục 10) vẫn là việc lớn riêng, chưa làm.

## Bản gộp 2.0 build 11 — ĐÃ GIAO 13:00 25/11
- File: `deliver/NVDAppleIDDownload.ipa` (25.354.783 byte, SHA256 `1514fe660237a86d8f299701b15b2f3aa59fcd5c6f6d9031db8668b4a25868e7`); remote head `194e01e4` (commit code `a7fe7d27`, CI run 45555338668 success cả build-ios + build-osx). Backup build 10: `deliver/NVDAppleIDDownload-2.0-build10-backup.ipa`.
- Đủ 7 tab ở cả 3 biến thể (Legacy TabView, New iOS 26+, sidebar macOS), đúng thứ tự: Tài khoản, Tìm kiếm, Đã mua, Đang theo dõi, Lượt tải, Ký IPA, Cài đặt. Trang chủ vẫn bỏ (gộp vào Giới thiệu trong Cài đặt).
- Sửa chuỗi sót `"pair again in SayoSign"` → `"pair again in NVDAppleIDDownload"` (binary: chuỗi cũ 0 hit, chuỗi mới 1 hit). Còn sót có chủ ý: tên client `"SayoSign"` ở `lib.rs:218` (identifier trong handshake pairing) + `"SayoSign Desktop"` + comment code.
- Kiểm chứng độc lập trước khi giao: version 2.0 build 11, bundle đúng, binary có SearchView/PurchasedView/WatchlistView/SignRootView, framework CydiaSubstrate đã embed, symbol sayo_idev có mặt.
- Chưa kiểm chứng trên iPhone thật (ký + pairing + 7 tab cần test bằng Apple ID phụ). Keychain/cert của NVDsign 1.4 KHÔNG mang sang — phải nhập lại .p12 / đăng nhập lại Apple ID trong app mới. IPA tải từ App Store vẫn mã hoá FairPlay nên đưa vào tab Ký sẽ báo encrypted (không phải lỗi gộp).
- Gom xong: anh có thể xóa chat ipatool — mọi thông tin + kết quả đã sang chat "tạo ipa" này; luồng hoàn tiền Oracle đã chuyển sang đây (nhắn 11:43 25/11, đã ghi MEMORY.md); danh sách lịch hẹn hiện tại không còn job nào trỏ vào chat ipatool.
