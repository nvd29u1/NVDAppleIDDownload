# So sánh iPadn (mengangs/ipadn) với NVDAppleIDDownload

- Ngày so sánh: 25/11/2026
- iPadn: `mengangs/ipadn`, GPL-2.0, v2.3.5 (23/11/2026), 1.333 sao, 100 fork, tạo 12/10/2026, 295 commit, 27 release, Swift, repo ~40 MB
- NVDAppleIDDownload: `nvd29u1/NVDAppleIDDownload`, fork Lakr233/Asspp 4.2.2 (MIT), bản đang dùng 4.2.2 build 4, build 5 đang làm dở (đổi version riêng thành 2.0, fix lệch vùng, nhập app khác vùng vào Đã mua)
- Nguồn: README + RELEASE_NOTES của iPadn (bản tiếng Trung, đã đọc), source đã đọc trực tiếp: `Services/SAPSigner.swift` (965 dòng), `Services/AppleAuthentication.swift`, `Services/DMAP.swift` (552 dòng), cây thư mục `Services/` + `Views/` + `vendor/` + `FairPlayCore/`; phía NVD: `AGENTS.md`, `Backend/AppStore/AuthenticationService.swift`, `Backend/AppStore/StoreDownloadService.swift`, cây thư mục source.
- Lưu ý: 2 lần fetch `README_EN.md` và `RELEASE_NOTES.md` qua browser bị lỗi 503 nên không đọc được 2 file đó; các chi tiết release lấy từ README tiếng Trung (đã đọc đầy đủ trong transcript) và source. Không clone iPadn, không sửa gì ở repo NVD (chỉ đọc).

## Ảnh chụp nhanh

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Gốc | Viết mới từ đầu bởi mengangs (từ 12/10/2026) | Fork Asspp 4.2.2 của Lakr233 (MIT), upstream đã archive 18/11/2026 |
| Giấy phép | **GPL-2.0** (file LICENSE là GPL v2 đầy đủ; README có chỗ ghi "GPL-2.0-or-later" — không thống nhất, an toàn nhất coi là GPL-2.0) | **MIT** (kế thừa Asspp) + fork ApplePackage của nvd29u1 (MIT) |
| iOS tối thiểu | **iOS / iPadOS 16.0** (v2.3.1 khôi phục lại 16.0, weak-link các API 17+) | **iOS 17.0 / macOS 15.0** (kẹt vì `@Observable`, `ContentUnavailableView`) |
| Ngôn ngữ UI | 11 ngôn ngữ (zh, en, ja, ko, ru, es, fr, de, pt-BR, ar + zh-Hant) | Tiếng Việt chính + en + zh-Hans (215 chuỗi) |
| Nhịp phát hành | Rất nhanh: v2.3.1 → v2.3.5 chỉ trong 21–23/11/2026 | Theo nhu cầu của anh Dũng, từng bản lẻ |
| Nền tảng | iPhone / iPad / Apple TV / Mac (tải PKG Mac) | iPhone / iPad / Mac (native, không Catalyst) |
| Cài app đã tải | **Native install** (qua LocalDevVPN + pairing, App Store nhận diện được, cập nhật được, ghi đè giữ dữ liệu) + one-tap install + local-cert + proxy | OTA qua manifest worker `nvd-manifest` (mặc định) hoặc local server HTTPS + CA tự ký "NVD Local Installation CA" |
| Đăng nhập | Tự làm toàn bộ: SAPSigner (WASM/Unicorn trong WKWebView) + StoreProof (Anisette/ADI on-device), session/cookie snapshot khôi phục lặng lẽ | Dựa vào ApplePackage 2.0.3 (chỉ SAP, không Anisette) + fork thêm header Anisette từ **server ngoài** (build 3), retry 3 lần lỗi 204/403/404/redirect |

## Bảng so sánh theo trục

### (1) Đăng nhập / xác thực — khác biệt lớn nhất

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| SAP signing | Tự làm: `SAPSigner.swift` chạy Go/WASM + Unicorn trong WKWebView trên máy, qua loopback server nội bộ, có cache chữ ký (tối đa 128), hàng đợi ưu tiên thao tác của người dùng, prewarm runtime | ApplePackage 2.0.3 làm sẵn (Swift, thư viện ngoài, đã đóng băng, không còn bản mới) |
| Anisette / device verification (cửa Apple từ ~06/11/2026) | **Có, on-device, từ v1.8.0 (09/11/2026):** `storeProofHeaders()` / `provisionStoreProof()` trong SAPSigner tạo header `X-Apple-AMD` / `X-Apple-AMD-M`; `AppleAuthentication.withStoreProof()` tự xử lý vòng lặp challenge: Apple trả `X-Apple-AMD-Action: SP` + `X-Apple-AMD-Data` (challenge) thì provision, `RP` thì reset, tối đa 3 vòng. Không cần server ngoài, không cần PC | **Không có trong app.** ApplePackage 2.0.3 không làm Anisette. Workaround là fork ApplePackage thêm `anisetteHeaders` + server Anisette riêng chạy ipatool 2.8.1 (PC/VPS, ~11 GB IPSW lần đầu). Server chưa từng chạy thật; login trên iPhone thật lúc 24/11 vẫn qua được theo từng lúc (có lúc 204/404, có lúc được) — không ổn định |
| Cách iPadn có được Anisette | Bundle Unicorn + 2 thư viện xác thực của Apple trích từ Apple Music bản Android, chạy trong WASM. Chính tác giả/stringers.io ghi rõ: các component này "complete license authorization not yet confirmed" (chưa xác nhận xong bản quyền) | Không bundle gì của Apple trong IPA (đúng luật hơn, nhưng yếu hơn) |
| 2FA / session | Đa số điện thoại tin cậy để chọn khi 2FA; đổi tài khoản/khởi động ưu tiên **khôi phục lặng lẽ session + cookie snapshot**, không hỏi mã bừa (fix 2.3.4: hết cảnh đổi acc là bật mã); lỗi 5020/2FA có hướng dẫn, session hết hạn (1008) tự refresh | 2FA: `verificationCodeRequired` hiện ô nhập mã ngay, không retry; `rotate(id:)` đăng nhập lại bằng cookie đã lưu; lỗi 204/redirect thì retry 3 lần + báo tiếng Việt |
| Chẩn đoán lỗi | Log chẩn đoán **đã khử nhạy cảm** (chỉ mã lỗi + số, không URL/cookie/mật khẩu), lỗi số lạ hiện luôn mã số để tra | Tương tự: `StoreDiagnostics.errorSummary` chỉ log loại lỗi + mã số, không log body/cookie/URL |

**Kết luận trục 1:** iPadn qua được cửa Apple tháng 11/2026 **ngay trên máy**, không cần server ngoài. Đây là lý do nó nổi lên (500 sao trong 2 ngày sau khi Asspp gãy login). NVD hiện phụ thuộc server Anisette ngoài — mà server đó còn chưa chạy thật lần nào và anh Dũng đã bỏ cả PC lẫn Oracle VPS.

### (2) Lệch vùng / đa vùng — đúng vấn đề anh Dũng vừa gặp (tài khoản IN, gói VN)

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Số vùng | **177 vùng** tùy chỉnh (v2.3.5): quản lý trong Cài đặt, tìm theo tên tiếng Trung/Anh + mã ISO-2, tick chọn, kéo sắp xếp, hiện cờ, khôi phục mặc định | Vùng = `store` của tài khoản đăng nhập (VN/IN/...); vùng tìm kiếm theo tài khoản đã chọn |
| Lệch vùng khi tải | **Chỉ chẩn đoán sau khi tải thật sự lỗi** (không chặn trước): lỗi 2059/1010 thì popup nêu đúng nguyên nhân vùng + nút **"Đổi và thử lại" / "Đổi tài khoản"** (v2.3.1) | Build 5 (đang làm): picker hiện mọi tài khoản, tài khoản khác vùng vẫn chọn được + cảnh báo cam; nút chỉ mờ khi không có tài khoản nào |
| CountryMismatch -128 | **Tự sửa** (v2.3.3): `-128 (CountryMismatch)` thì tự chỉnh vùng tài khoản cho khớp | Chưa có tự sửa; chỉ báo lỗi tiếng Việt |
| Mua license khác vùng | Apple chỉ cho mua theo storefront của tài khoản (`X-Apple-Store-Front`); iPadn cũng không phá được luật này — nó chỉ **lấy license xong tự refresh cache + retry** tải lịch sử phiên bản (v2.3.5) và báo rõ | Build 5 đã xác nhận y hệt: 1 tài khoản không mua được license ở vùng khác (2059/1010); nút vẫn bật để thử khi app có ở cả 2 vùng, lỗi thì dịch ra tiếng Việt + gợi ý thêm tài khoản đúng vùng |

**Kết luận trục 2:** iPadn không phá được luật vùng của Apple (không ai phá được), nhưng nó **không bao giờ để người dùng kẹt ở nút chết**: chẩn đoán sau lỗi thật + nút đổi tài khoản 1 chạm + tự sửa -128. NVD build 5 đang đi đúng hướng này, còn thiếu nút "đổi tài khoản rồi thử lại" trong popup lỗi.

### (3) Đã mua (Purchased)

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Đồng bộ | **2 nguồn gộp:** DMAP (`MZPurchaseDaap`, parser tự viết ~170 dòng, duyệt tag không copy) + API lịch sử mua đầy đủ `/commerce/account/purchases` (JSON:API, gộp theo order-id, khử trùng). Lần đầu đồng bộ **6 luồng song song theo năm**, sau đó chỉ quét tăng lượng năm hiện tại (vài giây). Có nút "Đồng bộ toàn bộ lịch sử mua" | **Không có màn Đã mua trong app.** Chỉ có nút "Nhập vào Đã mua" (build 4, gọi `ApplePackage.Purchase.purchase`, free-only, không tải IPA) và danh sách mua của Apple nằm ngoài app |
| App đã gỡ khỏi App Store | Tìm được bằng tên/bí danh/App ID (kết hợp danh mục + bản ghi local, có tùy chọn ưu tiên lên đầu); đồng bộ gộp cả app đã gỡ/ẩn | Tìm bằng Bundle ID tay ở Tải trực tiếp (giữ lại cho app đã rời store); không có danh sách đã gỡ |
| Thao tác hàng loạt | Chọn nhiều → tải hàng loạt; 1 chạm tìm app đã gỡ nhưng vẫn tải được rồi **backup toàn bộ**; xuất danh sách đã mua ra bảng | Chưa có |
| License app miễn phí chưa mua | Lấy license xong **tự refresh cache + retry** tải lịch sử phiên bản (v2.3.5) | Nút "Nhập vào Đã mua" riêng; chưa có auto-refresh sau khi mua (người dùng phải tự mở lại Lịch sử phiên bản) |

### (4) Lịch sử phiên bản / tải bản cũ

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Danh sách | Mỗi phiên bản có: số version, ngày, **dung lượng IPA**, icon của đúng phiên bản đó (đọc từ PNG trong IPA, có cache), ghi chú cập nhật; nhập trực tiếp version ID; bấm giữ để copy version/version ID | Danh sách external version ID qua `StoreDownloadService.versions()` + metadata (số version, ngày phát hành) qua `versionMetadata()`; build 4 fix lỗi `AuthenticationError 0` khi chọn bản cũ (do id tài khoản cũ) + retry lỗi tạm thời 3 lần |
| Giữ bản cũ | Đã tải rồi có thể **"Giữ phiên bản này"**, không nhắc cập nhật nữa | Chưa có |
| Nguồn version | Nhiều nguồn, có màn "Kiểm tra toàn bộ nguồn" trong Cài đặt (địa chỉ có `{id}`/`{appId}`) | 1 nguồn: Apple qua ApplePackage + catalog lookup fallback (`redownload` → `update`) |

### (5) Cài đặt app đã tải

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Native install | **Có:** qua LocalDevVPN + pairing (iOS 27 pairing ngay trên máy, không cần PC; iOS 17.4–26 cần file pairing từ PC 1 lần). App cài kiểu này **App Store nhận diện, cập nhật được, ghi đè bản App Store giữ dữ liệu**, không cần giải mã/ký lại | Không có. Cài qua OTA manifest (App Store không nhận diện, không tự cập nhật, không ghi đè được bản App Store) |
| Các cách khác | One-tap install (khuyên dùng), local cert (`ipadn.localtest.me`), proxy (Surge/Loon, rule DIRECT cho `api.palera.in`) | Manifest worker `nvd-manifest` (mặc định) hoặc local HTTPS server + CA tự ký |
| Sau tải | Tải xong **tự động cài** (tùy chọn); Live Activity/Động đảo + màn hình khóa hiện tiến độ; tải nền + resume thật (`resumeData`, CDN hết hạn tự refresh link) | Tải qua Digger (tối đa 3 song song), xong thì bấm Cài đặt; chưa có tự cài sau tải, chưa có resumeData/Live Activity |
| Lấy file IPA ra | Nút chia sẻ trên thẻ tải (tên file có tên app + version); Wi-Fi transfer (mở trình duyệt trên PC cùng Wi-Fi để tải IPA) | **Mới có ở build 4:** nút "Tải IPA về máy" (Share Sheet → Lưu vào Tệp/AirDrop), file `<bundleID>-<version>.ipa` |

### (6) Tính năng khác hay ho (iPadn có, NVD chưa có)

| Tính năng | iPadn | NVD |
|---|---|---|
| TestFlight (mới, thử nghiệm, v2.3.0) | Module riêng: trang TestFlight theo "đang test / không tương thích / đã test", tìm + đổi tài khoản, tải có tốc độ/ETA, chèn SINF + native install không cần ký lại, hỗ trợ Apple TV, `TFNet` 3 chế độ mạng, DoH | Không có |
| So giá đa vùng | So giá app + IAP/subscription nhiều vùng, quy đổi tiền tệ, xếp từ rẻ đến đắt, tự chọn vùng so sánh | Không có |
| Theo dõi app (Watch) | Follow app: có bản mới / giảm giá / miễn phí / bị gỡ thì nhắc; ghi lại **lịch sử giá** | Không có (chỉ có nhắc cập nhật app đã tải — mà NVD cũng chưa có) |
| Nhắc cập nhật | App đã tải có bản mới thì nhắc trong danh sách + gửi thông báo (kiểm tra nền) | Chưa có |
| Decrypt FairPlay on-device | **Pro Mode:** `FairPlayCore` (C, `FairPlayCore.c`) + SINF decrypt IPA đã tải + kiểm tra từng kiến trúc; xem log decrypt | Không có, và **không nên làm** (xem mục bản quyền) |
| Pro Mode / xem gói | Duyệt nội dung IPA, trích file, **so sánh 2 phiên bản** (version/quyền/extension/framework), quản lý token/device ID | Không có; chỉ có xem thông tin gói cơ bản |
| Mac PKG | Tải PKG Mac App Store, gửi qua AirDrop/Tệp sang Mac; lần đầu tải thêm ~47 MB component | NVD có bản macOS nhưng chỉ tải IPA iOS; chưa có PKG Mac |
| App đã cài trên máy | Liệt kê app đã cài, tìm app có bản mới trên Store để cập nhật 1 chạm | Không có (chỉ có tab Lượt tải) |
| Khóa app | Face ID / Touch ID / mật khẩu khóa app, ẩn nội dung ở đa nhiệm | Không có |
| Backup / khôi phục | Export/import đầy đủ: cài đặt, follow, nguồn version, **session Apple + StoreProof**, mã hóa AES-256-GCM bằng mật khẩu hoặc plaintext; xuất chẩn đoán đã khử nhạy cảm | Tài khoản lưu Keychain; chưa có export/import |
| Widget / Shortcut | Widget màn hình chính + khóa, Shortcut: tải app, kiểm tra cập nhật, xem tiến độ tải, follow | Không có |
| Khác | Dịch mô tả (dịch hệ thống / dịch thay thế iOS 18+), bảng xếp hạng free/paid/bán chạy theo vùng, app cùng developer, đánh giá; tự cập nhật iPadn trong app (đổi bản standard/lite) | NVD có: tìm bằng tên/bundle ID ở Tải trực tiếp (build 4), viền sáng BorderBeam, giao diện mận + lợn xanh, tiếng Việt |

### (7) Kiến trúc / UI / iOS tối thiểu

| | iPadn | NVDAppleIDDownload |
|---|---|---|
| Kiến trúc | Tự viết toàn bộ, không dùng thư viện App Store ngoài: `Services/` ~40 file (AppleAuthentication, SAPSigner, DMAP, StoreService, DownloadManager, InstallCoordinator, NativeInstaller, PriceService, WatchService, TestFlightKit...), `Views/` ~40 file, `Models/`, `FairPlayCore/` (C), `MacPKGBridge`, `NativeInstall`, `vendor/SAPRuntime` (WASM/Unicorn) + `vendor/TelegramRevealAnimations` | Dựa vào **ApplePackage 2.0.3** (thư viện ngoài, đã đóng băng) cho mọi giao tiếp App Store; app chỉ là UI + download (Digger) + installer (Vapor) + glue code. `Backend/` (AppStore/Downloader/Installer/DeviceCTL) + `Interface/` (Account/Search/Download/Installed/Setting/Welcome) |
| iOS tối thiểu | **16.0** (weak-link API 17+/18+, sửa crash 16.0–16.2 ở 2.3.5) | **17.0** (kẹt `@Observable` ở 7 file; muốn xuống 15/16 phải viết lại, đã chốt không làm) |
| UI | Theo phong cách App Store, 11 ngôn ngữ, Dynamic Type, iPad sidebar, đổi icon app | SwiftUI theo Asspp, tiếng Việt, mận + lợn xanh, BorderBeam (build 4) |
| Test | Có `iPadnTests` + `iPadnUITests` | Không có test target |
| AltStore source | Có `altstore-source.json` (cài/cập nhật qua SideStore/AltStore/Feather) | Không có (giao IPA trực tiếp) |

## Bản quyền — đọc kỹ trước khi lấy gì

**iPadn là GPL-2.0, NVDAppleIDDownload là MIT. Hai giấy phép này không trộn tùy tiện được.**

- **Học ý tưởng rồi tự viết lại = được.** Ý tưởng, luồng xử lý, tên endpoint của Apple (`/commerce/account/purchases`, `volumeStoreDownloadProduct`, `X-Apple-AMD-Action: SP/RP`...), mã lỗi (2059/1010/-128/1008...), danh sách 177 mã vùng ISO — đây là **sự thật kỹ thuật / giao thức**, không phải code có bản quyền. Đọc để hiểu rồi viết code của mình bằng Swift khác đi là hợp lệ, giữ nguyên MIT.
- **Copy code iPadn vào app MIT = không được, trừ khi đổi cả app sang GPL-2.0.** GPL-2.0 điều 2b: bất kỳ tác phẩm nào chứa 1 phần của chương trình GPL rồi đem phân phối thì **toàn bộ tác phẩm phải cấp phép GPL-2.0 miễn phí cho mọi bên**, kèm source. Tức là copy dù chỉ `DMAP.swift`, `SAPSigner.swift` hay `FairPlayCore.c` vào NVDAppleIDDownload rồi phát IPA thì: (1) toàn bộ app NVD thành GPL-2.0 (mất MIT, mất quyền giữ kín phần khác), (2) phải công khai source đầy đủ kèm IPA, (3) phải ghi rõ file nào đã sửa + ngày sửa. Anh Dũng hiện phát app qua repo public nên điều (2) làm được, nhưng đó là quyết định đổi giấy phép cả app — **không tự ý làm, phải hỏi anh chốt**.
- **Riêng phần Anisette của iPadn còn có thêm 1 lớp rủi ro:** nó bundle Unicorn (GPL) + 2 thư viện của Apple trích từ Apple Music Android. Chính tài liệu về iPadn ghi các component này "chưa xác nhận xong bản quyền" (complete license authorization not yet confirmed). Tức là ngay cả iPadn cũng đang ở vùng xám về việc phân phối lại binary của Apple. Asspp/Lakr233 đã **từ chối** đúng hướng này 2 lần vì lý do đó. NVD hiện tại (server Anisette ngoài, không bundle binary Apple) là hướng sạch hơn về pháp lý, dù bất tiện hơn.
- **Trường hợp đặc biệt — viết lại "sạch" (clean-room):** chỉ đọc mô tả cách làm (VD: "SAP chạy trong WKWebView qua WASM, challenge SP thì provision...") rồi tự triển khai bằng code của mình, không mở file source iPadn để chép, là cách an toàn nhất nếu muốn tính năng tương đương mà giữ MIT. Tốn công hơn copy rất nhiều.
- **Không lấy:** bất kỳ file nào trong `vendor/SAPRuntime` (Unicorn/WASM runtime + thư viện Apple), `FairPlayCore/`, `SAPSigner.swift`, `DMAP.swift`, `AppleAuthentication.swift` — copy nguyên file là vi phạm GPL nếu giữ MIT.

## 10 thứ hay ho lấy được, xếp theo hữu ích cho anh Dũng

### 1. ⭐ On-device StoreProof/Anisette (tự xác thực thiết bị ngay trên máy) — HỮU ÍCH NHẤT, KHÓ NHẤT
- **iPadn làm thế nào:** `SAPSigner.storeProofHeaders()` + `provisionStoreProof()` chạy Unicorn/WASM trong WKWebView, tự provision ADI rồi sinh `X-Apple-AMD`/`X-Apple-AMD-M`; `AppleAuthentication.withStoreProof()` tự xử lý challenge SP/RP của Apple, retry tối đa 3 vòng. Từ v1.8.0 (09/11/2026) login qua được cửa Apple mới, không cần PC/server ngoài.
- **NVD thiếu gì:** ApplePackage 2.0.3 không có Anisette; workaround hiện tại là server Anisette ngoài (build 3) — server chưa chạy thật lần nào, anh Dũng đã bỏ cả PC (đầy, nặng ~11 GB) lẫn Oracle VPS (đăng ký bị từ chối 2 lần). Login iPhone lúc được lúc lỗi 204/404.
- **Lấy bằng cách nào:** **Không copy code GPL được.** 3 đường: (a) **Giữ nguyên hướng server ngoài** (đã làm, sạch về pháp lý, chỉ cần 1 VPS/PC chạy được là xong — đây là đường rẻ nhất); (b) **Đổi cả app sang GPL-2.0 rồi port SAPSigner + SAPRuntime** — phải hỏi anh chốt, và vẫn dính vùng xám binary Apple; (c) **Viết lại sạch theo ý tưởng** (tự build WASM runtime + tự provision ADI) — khó nhất, hàng tuần, không khuyến nghị. **Khuyến nghị: (a).**

### 2. ⭐ Chẩn đoán lệch vùng sau lỗi thật + nút "Đổi tài khoản rồi thử lại" — HỮU ÍCH, DỄ
- **iPadn làm thế nào:** Không chặn trước khi tải; chỉ khi tải thật sự lỗi 2059/1010 mới popup nêu đúng nguyên nhân vùng + nút "Đổi và thử lại" / "Đổi tài khoản" (v2.3.1); lỗi `-128 CountryMismatch` thì **tự chỉnh vùng tài khoản cho khớp** (v2.3.3).
- **NVD thiếu gì:** Build 5 mới chỉ cảnh báo cam + cho chọn tài khoản khác vùng; khi Apple từ chối vẫn chỉ báo lỗi chữ, người dùng phải tự quay lại đổi tài khoản rồi bấm lại.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại (MIT giữ nguyên).** Thêm: bắt failureType 2059/1010/-128 trong `StoreDownloadService`/`AuthenticationService` → popup tiếng Việt "Lỗi do lệch vùng: tài khoản vùng X, gói vùng Y" + 2 nút [Đổi sang tài khoản vùng Y và thử lại] [Đổi tài khoản]. Tự sửa -128: khi gặp -128 thì đổi `account.store` sang vùng của gói rồi retry 1 lần (cẩn thận: build 5 đã ghi chú không được sửa lung tung `store` đã lưu — chỉ đổi trong bản sao của request, không ghi đè account đã lưu, hoặc hỏi người dùng trước).

### 3. ⭐ Màn Đã mua đầy đủ: DMAP + lịch sử mua Apple, app đã gỡ, tải hàng loạt — HỮU ÍCH, TRUNG BÌNH–KHÓ
- **iPadn làm thế nào:** Gộp DMAP (`MZPurchaseDaap`, parser tự viết) + `/commerce/account/purchases` (khử trùng theo order-id), lần đầu 6 luồng theo năm, sau đó quét tăng lượng; tìm được app đã gỡ bằng tên/bí danh/App ID; chọn nhiều tải hàng loạt; xuất danh sách ra bảng.
- **NVD thiếu gì:** **Không có màn Đã mua.** Chỉ có nút "Nhập vào Đã mua" (build 4) và phải nhớ app nằm trong danh sách Apple.
- **Lấy bằng cách nào:** **Học ý tưởng + giao thức, viết lại parser của mình (MIT giữ nguyên).** Endpoint và format DMAP là sự thật kỹ thuật; viết lại parser tag DMAP theo mô tả (không mở file `DMAP.swift` để chép từng dòng thì sạch nhất). Làm theo bước: (1) màn Đã mua chỉ đọc DMAP trước (dễ), (2) thêm `/commerce/account/purchases` sau (khó hơn, phân trang theo năm), (3) tải hàng loạt + xuất bảng sau cùng.

### 4. ⭐ 177 vùng App Store tùy chỉnh (tìm, tick, kéo sắp xếp, cờ) — HỮU ÍCH, TRUNG BÌNH
- **iPadn làm thế nào:** Cài đặt › vùng cửa hàng: toàn bộ 177 vùng, tìm theo tên/mã ISO-2, tick chọn, kéo sắp xếp, hiện cờ, khôi phục mặc định (v2.3.5).
- **NVD thiếu gì:** Vùng gắn cứng theo tài khoản đăng nhập; muốn đổi vùng phải đổi tài khoản.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại (MIT giữ nguyên).** Danh sách mã vùng ISO là dữ liệu sự thật, không phải code. Thêm màn chọn vùng tìm kiếm độc lập với tài khoản (lưu danh sách vùng ưa thích), rồi truyền `countryCode` vào `Searcher.search`/`catalogVersion` thay vì lấy từ `account.store`.

### 5. Lấy license free xong tự refresh + retry tải lịch sử phiên bản — HỮU ÍCH, DỄ
- **iPadn làm thế nào:** App miễn phí chưa mua: lấy license xong **tự làm mới cache + retry có lùi** rồi mới tải lịch sử phiên bản (v2.3.5).
- **NVD thiếu gì:** Nút "Nhập vào Đã mua" xong là xong; người dùng phải tự mở lại Lịch sử phiên bản, dễ gặp lại lỗi cũ.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại (dễ).** Sau `Purchase.purchase` thành công thì invalidate cache của `ProductView`/`AppPackageArchive` rồi tự gọi lại `versions()` 1 lần (có lùi 1–2 giây). Vài chục dòng.

### 6. Lịch sử phiên bản giàu hơn: icon đúng phiên bản, dung lượng, ghi chú, giữ bản — HỮU ÍCH, DỄ–TRUNG BÌNH
- **iPadn làm thế nào:** Mỗi phiên bản có icon đọc từ PNG trong IPA (có cache, tắt được), dung lượng IPA, ghi chú cập nhật; nhập trực tiếp version ID; bấm giữ copy version; app đã tải có thể "Giữ phiên bản này" để không nhắc cập nhật.
- **NVD thiếu gì:** Chỉ có số version + ngày phát hành; không có dung lượng/icon từng phiên bản, không có giữ bản.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại.** Dung lượng + ghi chú lấy từ catalog lookup đã có sẵn (`catalogVersion`); icon từng phiên bản: tải range đầu của IPA rồi đọc PNG chính — làm sau, tốn流量. "Giữ phiên bản này": thêm 1 flag vào `PackageManifest`, dễ.

### 7. Native install (App Store nhận diện, cập nhật được, ghi đè giữ dữ liệu) — HỮU ÍCH, KHÓ
- **iPadn làm thế nào:** `NativeInstaller` + `OnDevicePairing` + LocalDevVPN: iOS 27 pairing ngay trên máy; iOS 17.4–26 cần file pairing từ PC 1 lần. Cài qua system install service như cắm máy tính.
- **NVD thiếu gì:** Chỉ có OTA manifest (App Store không nhận diện, không tự cập nhật, không ghi đè bản App Store).
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại (khó, hàng tuần).** Cần triển khai pairing + giao thức cài đặt hệ thống từ đầu; không copy `NativeInstaller.swift`/`OnDevicePairing.swift` (GPL). Chỉ nên làm sau khi trục đăng nhập (mục 1) đã ổn, vì native install không có giá trị nếu không tải được app.

### 8. Tải nền thật sự: resume, tự refresh link CDN, tự cài sau tải, Live Activity — HỮU ÍCH, TRUNG BÌNH–KHÓ
- **iPadn làm thế nào:** `resumeData` tạm dừng/tiếp tục thật, link CDN hết hạn tự refresh, "tải xong tự cài", Live Activity/Động đảo + màn hình khóa hiện tiến độ (v2.3.4).
- **NVD thiếu gì:** Digger tải 3 song song nhưng chưa có resumeData thật, chưa tự cài sau tải, chưa có Live Activity.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại.** "Tải xong tự cài" là dễ nhất (gọi installer khi download xong); resumeData cần sửa lớp download (trung bình); Live Activity cần extension mới (trung bình, tốn 1 App ID — bản lite của iPadn bỏ Live Activity vì lý do này, anh Dũng cũng chỉ có số App ID miễn phí giới hạn nên cân nhắc).

### 9. Theo dõi app + so giá đa vùng — HAY, TRUNG BÌNH
- **iPadn làm thế nào:** `WatchService` + `PriceService`: follow app → nhắc khi có bản mới/giảm giá/miễn phí/bị gỡ, lưu lịch sử giá; so giá app + IAP/subscription nhiều vùng theo tiền tệ đã chọn.
- **NVD thiếu gì:** Không có follow, không có so giá, không có nhắc cập nhật app đã tải.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại.** Giá lấy từ iTunes Lookup API công khai (không cần đăng nhập) — phần so giá là dễ nhất trong nhóm này; follow + nhắc nền cần scheduler kiểm tra định kỳ (khó hơn, tốn pin/quota).

### 10. Wi-Fi transfer + xem/trích nội dung IPA + Mac PKG — HAY, DỄ–TRUNG BÌNH (trừ decrypt)
- **iPadn làm thế nào:** Wi-Fi transfer: mở trình duyệt PC cùng Wi-Fi để tải IPA đã xong; Pro Mode: duyệt nội dung IPA, trích file, so sánh 2 phiên bản; tải PKG Mac App Store (lần đầu thêm ~47 MB component).
- **NVD thiếu gì:** Chưa có Wi-Fi transfer (chỉ có Share Sheet/AirDrop từ build 4); chưa xem được nội dung IPA; chưa tải PKG Mac.
- **Lấy bằng cách nào:** **Học ý tưởng, viết lại.** Wi-Fi transfer = server HTTP nhỏ trên máy (NVD đã có sẵn Vapor cho installer — tái dùng được, dễ–trung bình). Xem/trích IPA = đọc ZIP (dễ–trung bình). Mac PKG = thêm endpoint tải PKG của Apple (trung bình). **Không lấy:** decrypt FairPlay on-device (`FairPlayCore`) — cần thư viện Apple + GPL, đúng thứ Lakr233 đã từ chối; NVD đã chốt từ đầu là IPA tải về vẫn mã hóa FairPlay, không giải mã.

### Đáng nhắc thêm (nhỏ, không xếp hạng riêng)
- **Khóa app bằng Face ID** (iPadn `AppLock.swift`): học ý tưởng, viết lại, dễ.
- **Backup/restore mã hóa AES-256-GCM** gồm cả session Apple + StoreProof (iPadn `AccountBackupService`): học ý tưởng, viết lại, trung bình — hữu ích khi anh Dũng đổi máy.
- **AltStore source JSON** (`altstore-source.json`): học ý tưởng, viết lại, rất dễ — cho phép cài/cập nhật NVDAppleIDDownload qua SideStore/AltStore/Feather mà không cần gửi lại IPA mỗi bản.
- **Tự cập nhật trong app + đổi bản standard/lite** (iPadn `AppUpdateView`): học ý tưởng, dễ–trung bình.
- **Widget + Shortcut** (iPadn): học ý tưởng, trung bình; tốn App ID cho widget extension.

## Khuyến nghị làm trước (cho anh Dũng)

1. **Mục 2 (chẩn đoán lệch vùng + nút đổi tài khoản thử lại)** — dễ, đúng nỗi đau vừa gặp tối 24/11 (IN vs VN), làm tiếp ngay sau build 5.
2. **Mục 5 (lấy license xong tự refresh)** — dễ, vài chục dòng, hết cảnh mua xong vẫn lỗi lịch sử phiên bản.
3. **Mục 3 (màn Đã mua, bắt đầu chỉ bằng DMAP)** — trung bình, là tính năng thiếu lớn nhất của NVD so với iPadn; làm xong thì nút "Nhập vào Đã mua" mới có chỗ để xem kết quả.
4. **Mục 4 (177 vùng)** — trung bình, đi kèm mục 3.
5. **Mục 1 (Anisette on-device)** — chỉ làm khi anh chốt đổi giấy phép sang GPL-2.0 hoặc chấp nhận viết lại sạch; trước mắt cứ giữ server Anisette ngoài. **Không copy code GPL vào app MIT.**

## Rủi ro / lưu ý khi tham khảo iPadn

- iPadn mới 6 tuần tuổi (12/10 → 25/11/2026), phát hành rất nhanh nhưng cũng đổi liên tục; GitHub Issues đã **đóng nhận câu hỏi mới** (chỉ còn Telegram @ipadn_official), nên gặp lỗi khó tra cứu.
- Phần Anisette/decrypt của iPadn dựa vào binary của Apple mà chính tác giả thừa nhận chưa xác nhận xong bản quyền — dùng cho cá nhân thì ít rủi ro, nhưng **đem vào app của mình để phát cho người khác thì rủi ro cao hơn**.
- iPadn hỗ trợ iOS 16, NVD kẹt iOS 17 — muốn xuống 16 thì phải viết lại phần `@Observable`, không liên quan iPadn.
- NVD có thứ iPadn không có: **máy chủ manifest riêng của anh Dũng (`nvd-manifest`)**, giao diện tiếng Việt + lợn xanh + BorderBeam, và server Anisette ngoài (sạch về pháp lý). Đừng bỏ những thứ này khi học theo iPadn.
