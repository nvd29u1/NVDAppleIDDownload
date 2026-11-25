#if os(iOS)
import Foundation
import Security

// MARK: - Hỗ trợ port từ iPadn (GPL-2.0-or-later, mengangs/iPadn)
//
// Các kiểu nhỏ mà hệ đăng nhập iPadn dùng chung, port từ:
// - Models.swift (ToolError, HTTPStatusError, plistString)
// - Services/PriceService.swift (NSLockedValue)
// - Services/AccountBackupService.swift (StoreProofRecord, normalizedDeviceGUID)
// - Services/KeychainStore.swift (StoreProofStore)
// - Services/StoreService.swift (storefrontIdentifier, pod from host)
// Đã đổi tên tiền tố IPadn/ipadn + dịch chuỗi hiển thị sang tiếng Việt.

/// Lỗi chung dạng một câu thông báo (port từ iPadn ToolError).
enum IPadnToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Lỗi HTTP không thành công, giữ nguyên mã để phân biệt (port từ iPadn HTTPStatusError).
struct IPadnHTTPStatusError: LocalizedError {
    let code: Int
    var errorDescription: String? {
        switch code {
        case 404: return "Không tìm thấy nội dung liên quan."
        case 401: return "Apple đã từ chối yêu cầu này (\(code)), phiên đăng nhập có thể đã hết hạn — hãy đăng nhập lại ở tab Tài khoản rồi thử lại."
        default: return "Yêu cầu mạng thất bại (\(code)), hãy thử lại sau."
        }
    }
}

/// Giá trị dùng chung cho nhiều luồng, khoá một lúc một luồng (port từ iPadn NSLockedValue).
final class IPadnLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Đọc chuỗi từ plist (String hoặc NSNumber), thiếu thì "" (port từ iPadn plistString).
func ipadnPlistString(_ value: Any?) -> String {
    guard let value = value else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

/// Mã vùng cửa hàng từ chuỗi storefront đầy đủ, vd "143467-1,29" → "143467" (port từ iPadn StoreService).
func ipadnStorefrontIdentifier(_ storefront: String) -> String {
    String(storefront.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Pod từ host dạng p<digits>-buy.itunes.apple.com → "<digits>" (port từ iPadn CommercePurchaseHistory.pod).
func ipadnPodFromHost(_ host: String) -> String? {
    guard host.hasPrefix("p"), host.hasSuffix("-buy.itunes.apple.com") else { return nil }
    let digits = host.dropFirst().dropLast("-buy.itunes.apple.com".count)
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return String(digits)
}

/// Chuẩn hoá GUID thiết bị 12 ký tự hex (port từ iPadn AccountBackupService.normalizedDeviceGUID).
func ipadnNormalizedDeviceGUID(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
          trimmed.count == 12,
          trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
        return nil
    }
    return trimmed
}

/// Bản ghi xác minh thiết bị (store proof) gắn với một GUID, lưu trong Keychain (port từ iPadn StoreProofRecord).
struct IPadnStoreProofRecord: Codable, Equatable, Sendable {
    var identifier: String
    var files: [String: String]
    var updatedAt: Date = Date()
}

/// Kho lưu StoreProofRecord trong Keychain (port từ iPadn StoreProofStore).
/// Service dùng bundle ID của app này nên không đụng kho của iPadn.
enum IPadnStoreProofStore {
    private static let maxEntries = 8
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.NVD.appleiddownload") + ".storeproof"
    }
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "store-proof-v1"]
    }
    static func load() -> [String: IPadnStoreProofRecord] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: IPadnStoreProofRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }
    static func save(_ records: [String: IPadnStoreProofRecord]) {
        let trimmed: [String: IPadnStoreProofRecord]
        if records.count > maxEntries {
            let kept = records.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            trimmed = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        } else {
            trimmed = records
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
#endif
