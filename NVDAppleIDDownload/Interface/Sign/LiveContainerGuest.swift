#if os(iOS)
import Foundation

/// Phát hiện chạy dạng guest trong LiveContainer (đợt 5, build 17).
///
/// LiveContainer nạp guest bằng dlopen trong process của chính nó, nên
/// Bundle.main là bundle của host (LiveContainer), không phải của app.
/// Khi đó nhập file (.ipa/.p12/.mobileprovision) và cài đặt đều không
/// hoạt động được — đã chứng minh với NVDsign 24/11, rào cản nằm ở iOS
/// chứ không phải code app. App tự nhận biết để báo rõ thay vì lỗi
/// lặng lẽ; các tính năng không cần nhập file (tìm kiếm, xem, tải IPA
/// về đường foreground) vẫn chạy được.
enum LiveContainerGuest {
    /// Bundle ID thật của app khi cài trực tiếp (SideStore/AltStore/
    /// TrollStore). Guest trong LiveContainer có Bundle.main là bundle
    /// của LiveContainer nên khác giá trị này.
    static var isGuest: Bool {
        Bundle.main.bundleIdentifier != "com.NVD.appleiddownload"
    }
}
#endif
