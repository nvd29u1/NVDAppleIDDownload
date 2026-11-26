#if os(iOS)
import Foundation

/// Kho tài khoản CHỈ TRONG BỘ NHỚ cho lõi iPadn port sang (thay
/// KeychainStore của iPadn): AppStore của app mới là nguồn thật duy nhất
/// (lưu Keychain + Persist). Lõi iPadn giữ tài khoản hiện tại trong bộ
/// nhớ qua useAccount(); cầu nối ghi cookie/token mới về AppStore sau
/// mỗi lần gọi. Không ghi gì ra đĩa ở đây — load/save chỉ để code port
/// giữ nguyên luồng như bản gốc (giữa các lần gọi trong cùng phiên).
enum IPadnAccountStore {
    private static var stored: [IPadnAppleAccount] = []
    static func load() throws -> [IPadnAppleAccount] { stored }
    static func save(_ accounts: [IPadnAppleAccount]) throws { stored = accounts }
}
#endif
