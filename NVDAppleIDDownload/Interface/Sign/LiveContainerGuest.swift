#if os(iOS)
import Foundation

/// Phát hiện chạy dạng guest trong LiveContainer (đợt 5, build 17;
/// sửa tiêu chí ở build 18).
///
/// LiveContainer nạp guest bằng dlopen trong process của chính nó, nên
/// Bundle.main là bundle của host (LiveContainer), không phải của app.
/// Khi đó nhập file (.ipa/.p12/.mobileprovision) và cài đặt đều không
/// hoạt động được — đã chứng minh với NVDsign 24/11, rào cản nằm ở iOS
/// chứ không phải code app. App tự nhận biết để báo rõ thay vì lỗi
/// lặng lẽ; các tính năng không cần nhập file (tìm kiếm, xem, tải IPA
/// về đường foreground) vẫn chạy được.
///
/// Build 18: chỉ khác bundle ID thôi CHƯA ĐỦ để kết luận guest — bản
/// 17 báo sai trên máy cài qua SideStore (anh báo 20:27 25/11), trong
/// khi bundle ID của IPA đã giao đã kiểm chứng là đúng
/// com.NVD.appleiddownload. Nên cần thêm bằng chứng dương tính:
/// process đang chạy phải là LiveContainer (processName ==
/// "LiveContainer"; cài trực tiếp thì processName là tên executable
/// của app, "NVDAppleIDDownload"). Lần test sau, log chẩn đoán ở đây
/// sẽ ghi rõ bundleIdentifier + processName thực tế để đối chiếu.
enum LiveContainerGuest {
    /// Bundle ID thật của app khi cài trực tiếp (SideStore/AltStore/
    /// TrollStore).
    static let appBundleIdentifier = "com.NVD.appleiddownload"

    /// true chỉ khi CẢ HAI điều kiện đúng: Bundle.main không phải của
    /// app (guest dlopen trong process host) VÀ process đang chạy là
    /// LiveContainer. Một mình khác bundle ID không kết luận được.
    static var isGuest: Bool {
        Bundle.main.bundleIdentifier != appBundleIdentifier
            && ProcessInfo.processInfo.processName == "LiveContainer"
    }

    /// Ghi 1 lần (lúc mở tab Ký IPA) các giá trị thật để lần test sau
    /// đối chiếu được banner hiện/ẩn là đúng hay sai.
    private static var didLogDetection = false

    static func logDetectionOnce() {
        guard !didLogDetection else { return }
        didLogDetection = true
        logger.info("LiveContainer detection: bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil"), processName=\(ProcessInfo.processInfo.processName), isGuest=\(isGuest)")
    }
}
#endif
