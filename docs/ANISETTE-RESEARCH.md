# Nghiên cứu Anisette cho NVDAppleIDDownload — kết luận 24/11/2026

## Kết luận ngắn

**Không thể port cơ chế Anisette local của ipatool 2.8.0 sang app iOS trong phạm vi này.**
Đăng nhập trong app vẫn sẽ lỗi (204 / redirect không Location / 404) cho tới khi có một
trong hai thứ: (1) một máy chủ Anisette từ xa do chính anh Dũng tự chạy, hoặc
(2) một thư viện Anisette Swift đã được chứng minh là qua được cổng otp/1.5 mới của Apple.
Đường tải IPA vẫn chạy được ngay bây giờ: **ipatool 2.8.1 trên PC** (đã đăng nhập thành
công sáng 24/11 với cùng tài khoản).

## 1. Anisette là gì, Apple chặn ở đâu

- Từ ~06/11/2026, Apple yêu cầu đăng nhập App Store phải kèm bằng chứng xác minh
  thiết bị (Anisette/ADI): các header `X-Apple-I-MD` (OTP), `X-Apple-I-MD-M`
  (machine ID), `X-Apple-I-MD-RINFO` (routing info), `X-Apple-I-MD-LU`,
  `X-Apple-I-TimeZone`, `X-Mme-Device-Id`, `X-MMe-Client-Info`.
- Không có các header này, Apple chặn ngay từ đầu, trước khi xét mật khẩu/2FA —
  nên lỗi đổi mã liên tục (204 trống, redirect không có `Location`, 404) nhưng cùng
  một gốc. Mật khẩu sai / tài khoản không tồn tại trả về HTTP 200 + plist có
  failureType, không ra các lỗi này.
- ApplePackage 2.0.3 (thư viện app đang dùng, pin `773583a`) chỉ ký SAP
  (`X-Apple-ActionSignature`), không làm Anisette. Đã kiểm tra
  `Authenticate.swift` (181 dòng): `makeRequest()` chỉ gắn User-Agent,
  Content-Type, cookie và `X-Apple-ActionSignature` — **không có chỗ nào để
  chèn header Anisette từ ngoài vào**. Muốn gắn header thì phải fork ApplePackage
  và sửa `makeRequest()`.
- Upstream Asspp đã archive 18/11/2026; không có ApplePackage mới hơn 2.0.3
  (release mới nhất 20/10/2026). Tìm trên GitHub không có fork ApplePackage nào
  làm Anisette (search API trả về 0 kết quả).

## 2. ipatool 2.8.0 làm Anisette như thế nào (nguồn: majd/ipatool, MIT)

Commit sửa lỗi: `001d889` "fix: restore app store authentication locally"
(08/11/2026), 40 file thay đổi. Không phải "thêm vài header" mà là cả một
bộ máy giả lập:

1. **Tải tài nguyên Apple (11 GB):** `internal/sap/assets/assets.go` tải file
   IPSW macOS 27.0.1 (`UniversalMac_27.0.1_26A434_Restore.ipsw`,
   `updates.cdn-apple.com`, 11.274.289.152 byte) rồi giải nén, lấy 7 binary
   đã ghim SHA256: AppleMediaServices (~14,8 MB), commerce (~2,7 MB),
   adid (~3 MB), CoreFP (~30,8 MB), CoreFP.icxs (~7,4 MB),
   fairplayd (~17,4 MB), FairPlayIOKit (~2,1 MB). Đây là code có bản quyền
   của Apple — ipatool **không đóng gói sẵn** mà tải từ CDN của Apple lúc chạy.
2. **Giả lập bằng Unicorn (Go):** `internal/sap/machine/` — `machine.go`,
   `shim_platform.go` (~44 KB), `modern_adi.go` (662 dòng mới), `dyld`,
   `machimage`… — chạy 4 máy ảo cùng lúc (commerce runtime, adid daemon,
   fairplayd, FairPlay kernel) với các entry point hard-code theo địa chỉ
   (`storeAgentBase + 0x1b4400`…), shim XPC/Mach RPC, để chạy code ADI thật
   của Apple.
3. **Provisioning 2 bước:** `internal/storeauth/anisette.go`
   (`AnisetteHeaders`): `startMachineProvisioning` /
   `finishMachineProvisioning` tới `gsa.apple.com/grandslam/MidService/…`
   (spim → cpim, ptm, tk, `X-Apple-I-MD-RINFO`), rồi `RequestOTP` cho ra
   `X-Apple-I-MD` / `X-Apple-I-MD-M`, lưu state `adi.pb`.
   Thêm bước Store riêng: `store_provisioning.go`
   (`ProvisionStoreAnisette`, spim từ `auth.itunes.apple.com` → cpim,
   settingInfo, transportKey, import FairPlay keybag, kbsync).
4. **Đăng nhập:** `pkg/appstore/appstore_login.go` (`loginRequest`) gắn
   `X-Apple-I-MD` → `X-Apple-AMD`, `X-Apple-I-MD-M` → `X-Apple-AMD-M`
   (bằng chứng AMS loại 2, Configurator AMD, chạy AppleMediaServices trong
   máy ảo — `internal/store/emulator/anisette.go`, `StoreAMDHeaders`).
   Ghi chú trong code: *"Apple Store otp/1.5 provisioning requires this
   generation; the Sierra implementation cannot consume its settingInfo
   payload"* — tức thế hệ ADI cũ đã không ăn được cổng mới.

## 3. Vì sao không port được sang app iOS

1. **Khối lượng:** port nguyên bộ máy Unicorn + shim Mach/XPC + dyld từ Go
   sang Swift, cộng một Unicorn cho iOS — hàng chục nghìn dòng, không phải
   một tính năng.
2. **Tài nguyên 11 GB:** trên iPhone phải tải và giải nén IPSW 11 GB rồi
   chạy 4 máy ảo macOS — không thực tế về dung lượng, RAM, thời gian.
3. **Không có JIT trên iOS:** app sideload không có quyền JIT; giả lập bằng
   TCI (thông dịch) sẽ chậm hơn hàng chục lần, chưa từng được chứng minh
   với bộ máy này.
4. **Không có điểm chèn header:** ApplePackage 2.0.3 không nhận header ngoài
   (mục 1) — phải fork thư viện trước đã.
5. **Bản quyền:** đóng gói binary macOS/FairPlay của Apple vào IPA là phân
   phối lại code có bản quyền của Apple; ipatool né bằng cách tải từ CDN
   của Apple lúc chạy, không đóng gói.

## 4. Các hướng khác đã kiểm tra

### 4.1 AnisetteKit (mahee96/AnisetteKit, Swift SPM, iOS 15+)
- Làm Anisette ngay trên máy bằng Unicorn TCI, không cần server — nghe đúng
  thứ cần. Nhưng: chỉ 7 sao, 49 commit, **0 release**, chưa có bằng chứng
  nào là qua được cổng otp/1.5 của Apple tháng 11/2026 (test của nó chỉ
  kiểm tra provisioning ra `adi.pb` và header không rỗng, không đăng nhập
  thật vào App Store).
- **Không kèm binary Apple:** người dùng phải tự cung cấp `libstoreservicescore.so`
  và `libCoreADI.so` (lấy từ APK Apple Music Android) qua
  `libraryDirectoryResolver` — file này là code của Apple, không được phân
  phối lại, và trên iPhone không có cách nào lấy sẵn.
- **Giấy phép AGPLv3:** link vào là toàn bộ app thành AGPLv3 — phát hành là
  phải công khai toàn bộ source; điều khoản của nó còn cấm phân phối qua
  App Store. Không phù hợp với app này (gốc MIT).
- ADI thế hệ cũ (lib .so Android) rất có thể đã lỗi thời trước cổng otp/1.5
  như ghi chú của ipatool ở mục 2.

### 4.2 Máy chủ Anisette từ xa (mô hình AltStore/SideStore)
- Đây là kiến trúc đã được chứng minh cho app iOS: app GET header JSON từ
  một server do chính người dùng chạy (`GET http://server:6969` →
  `{"X-Apple-I-MD": …, "X-Apple-I-MD-M": …}`, Dadoum/Provision
  `anisette-server`, Docker `dadoum/anisette-server`, cổng 6969).
- Vấn đề: Dadoum dùng ADI thế hệ cũ (lib .so Sierra) — **chưa chứng minh
  được là qua cổng otp/1.5 mới**; server dùng engine mới (ipatool) thì chưa
  có sẵn, phải tự viết một HTTP server nhỏ bọc quanh engine Go của ipatool
  (package `internal/` của ipatool không import được từ ngoài, phải làm
  trong fork của ipatool hoặc xin phép cấu trúc lại).
- Đây vẫn là hướng khả thi nhất, nhưng là một dự án riêng (server + fork
  ApplePackage + cài đặt trong app), không phải một bản sửa nhỏ, và chưa
  kiểm chứng được đầu-cuối nếu không có server + tài khoản phụ để test.

### 4.3 Dùng native AMS/AuthKit trên chính iPhone
- iPhone thật đã có ADI/FairPlay của Apple, nhưng app sideload bị sandbox,
  không gọi được daemon `akd`/AMS qua XPC bằng API công khai; dùng private
  framework `AMSAnisette` là API riêng, mong manh trên iOS 27 và không có
  tài liệu/tiền lệ đáng tin cho app sideload. Chưa điều tra sâu — chỉ ghi
  nhận là hướng nghiên cứu, không phải giải pháp.

### 4.4 iPadn 1.8.0+
- App đóng, không có source để kiểm tra cách đăng nhập; không có bằng chứng
  là nó qua được cổng mới. Không dựa vào được.

## 5. Kế hoạch khả thi (đề xuất, cần anh Dũng chốt)

**Giai đoạn 1 — máy chủ Anisette của riêng anh (server):**
- Chạy một server Anisette trên PC của anh (hoặc VPS anh quản lý), dùng
  engine mới của ipatool nếu viết được wrapper, nếu không thử Dadoum trước
  và chấp nhận rủi ro nó không qua cổng otp/1.5.
- Server này chỉ phục vụ anh, ADI (`adi.pb`) không chia sẻ cho ai khác.

**Giai đoạn 2 — fork ApplePackage + app:**
- Fork `Lakr233/ApplePackage` sang `nvd29u1/ApplePackage`, sửa
  `Authenticator.makeRequest()` nhận thêm header Anisette; đổi SPM pin
  sang fork.
- Thêm trong app mục Cài đặt → "Máy chủ Anisette" (URL, mặc định trống =
  tắt): trước khi đăng nhập, app GET header từ server rồi chèn vào request.
- Giữ retry 3 lần + lỗi tiếng Việt như hiện tại.

**Giai đoạn 3 — kiểm chứng:** đăng nhập bằng **tài khoản Apple phụ** trên
iPhone thật; nếu qua được thì mới dùng tài khoản chính. Không dùng tài
khoản/mật khẩu của anh để test trên máy ảo.

## 6. Đường thay thế vẫn dùng được ngay
- **ipatool 2.8.1 trên PC:** đã đăng nhập thành công sáng 24/11, tải IPA về
  rồi chuyển sang iPhone cài qua SideStore/NVDsign. Đây là cách chắc chắn
  nhất lúc này.
- Trong app vẫn dùng được phần tìm kiếm/xem (không cần đăng nhập) — chỉ
  đăng nhập/tải là chặn.

## Nguồn tham khảo
- majd/ipatool v2.8.0, commit `001d889`, `internal/storeauth/anisette.go`,
  `internal/storeauth/store_provisioning.go`, `internal/sap/assets/assets.go`,
  `internal/sap/machine/modern_adi.go`, `pkg/appstore/appstore_login.go`
  (MIT).
- Lakr233/ApplePackage 2.0.3, `Sources/ApplePackage/Commands/Authenticate.swift`
  (pin `773583a`).
- mahee96/AnisetteKit (AGPLv3) — README, `Package.swift`, `Sources/Constants.swift`,
  `Tests/AnisetteKitTests/AnisetteKitTests.swift`.
- Dadoum/Provision `anisette-server` (Docker, cổng 6969).
