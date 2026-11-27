# NVDAppleIDDownload

> Tải file IPA từ App Store ngay trên iPhone, không cần máy tính. Đăng nhập bằng Apple ID sở hữu app, chọn app, tải về rồi cài trực tiếp trên máy.
>
> **Bản 3.0:** lõi đăng nhập, Đã mua và tải dùng lõi iPadn; giao diện NVD giữ nguyên — nền mận đậm, logo lợn xanh, tiếng Việt.

## Tính năng

- **Tìm kiếm:** tìm app trên App Store, xem giá, dung lượng, lịch sử phiên bản; chọn phiên bản cũ để tải khi Apple còn cho.
- **Đã mua:** đồng bộ danh sách app đã mua của tài khoản, gồm cả lịch sử mua đầy đủ; nhập app miễn phí vào Đã mua (chỉ đúng vùng của tài khoản).
- **Lượt tải:** hàng đợi tải tối đa 3 file cùng lúc, tải nền, tải xong tự cài đặt (tuỳ chọn); xuất file IPA đã tải qua Share Sheet để lưu vào Tệp hoặc gửi qua AirDrop; xem nội dung file IPA; chia sẻ IPA qua Wi-Fi cho máy tính cùng mạng.
- **Ký IPA:** ký file IPA bằng chứng chỉ `.p12` + `.mobileprovision`, hoặc đăng nhập Apple ID để ký; cài trực tiếp trên máy.
- **Đang theo dõi:** theo dõi app, xem giá hiện tại và lịch sử giá; so giá app ở các vùng đã chọn.
- **Tài khoản:** đăng nhập nhiều Apple ID, mỗi tài khoản giữ đúng vùng của nó; màn chi tiết app tự chọn tài khoản đúng vùng.
- **Cài đặt:** khoá app bằng Face ID / Touch ID / mật khẩu; chọn máy chủ Anisette; chọn máy chủ manifest để cài app (mặc định `nvd-manifest`); xem nhật ký app.
- **Hỗ trợ:** iOS 16.0–27.2 (đã kiểm chứng thật tới iOS 27.0) và macOS 15.0 trở lên; cài qua chứng chỉ cá nhân, SideStore, AltStore, LiveContainer hoặc TrollStore.

## Giấy phép

App trộn code từ nhiều nguồn mở, mỗi phần giữ giấy phép gốc của nó (xem chi tiết trong [`LICENSES.md`](./LICENSES.md); văn bản đầy đủ của từng giấy phép nằm trong các file LICENSE ở gốc repo):

- **App gốc Asspp** — MIT — [`LICENSE`](./LICENSE)
- **Tính năng ký IPA** — GPL-3.0 — [`LICENSE-SayoSign-GPL-3.0`](./LICENSE-SayoSign-GPL-3.0)
- **Đăng nhập + lõi cửa hàng (iPadn)** — GPL-2.0-or-later — [`LICENSE-iPadn-GPL-2.0`](./LICENSE-iPadn-GPL-2.0)
- **Hiệu ứng viền sáng BorderBeam** — MIT — [github.com/ismnoiet/border-beam-ios](https://github.com/ismnoiet/border-beam-ios)
