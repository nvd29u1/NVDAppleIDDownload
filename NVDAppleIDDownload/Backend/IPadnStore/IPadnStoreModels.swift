#if os(iOS)
// Port từ iPadn v2.3.5 (commit c7be403, GPL-2.0-or-later, mengangs/iPadn):
// Models/Models.swift (trích type lõi store). Đã đổi tên tiền tố IPadn/ipadn + dịch chuỗi tiếng Trung sang
// tiếng Việt + bỏ AppText/InstallLog, theo cùng quy ước bản 20 (đăng nhập).
// Giấy phép xem LICENSES.md (GPL-2.0-or-later cho phần lõi iPadn này).
import Foundation
enum IPadnAppPlatform: String, Codable, CaseIterable, Identifiable {
    case iOS = "itunes", iPadOS = "ipad", tvOS = "atv9", macOS = "mac"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iOS: return "iOS"
        case .iPadOS: return "iPad"
        case .tvOS: return "tvOS"
        case .macOS: return "Mac"
        }
    }
    var symbol: String {
        switch self {
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .tvOS: return "appletv"
        case .macOS: return "macbook"
        }
    }
    var supportsIPA: Bool { self != .macOS }
    var usesIOSStore: Bool { self == .iOS || self == .iPadOS }
    var searchEntity: String {
        switch self {
        case .iOS: return "software"
        case .iPadOS: return "iPadSoftware"
        case .tvOS: return "software,tvSoftware"
        case .macOS: return "macSoftware"
        }
    }
    var catalogPlatform: String { self == .iPadOS ? IPadnAppPlatform.iOS.rawValue : rawValue }
}

struct IPadnStoreContext: Codable, Equatable {
    var country = "CN"
    var platform: IPadnAppPlatform = .iOS
}

struct IPadnStoreApp: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleID = ""
    var version = ""
    var iconURL: URL?
    var description = ""
    var category = ""
    var size: Int64 = 0
    var price = ""
    /// The listing's price as a number and its ISO currency, from the lookup API.
    var priceValue: Double?
    var currency: String?
    /// Free apps come back without a price, or with the store's own word for
    /// free ("Free", "免費"); older saves stored "免费". A zero amount decides.
    var isFree: Bool { price.isEmpty || priceValue == 0 || price == "免费" }
    var priceLabel: String { isFree ? "Miễn phí" : price }
    var rating: Double = 0
    var minimumOS = ""
    var externalVersionID: String?
    var developerURL: URL?
    // tvSoftware search is unavailable for some storefronts; candidate
    // listings are not proof of compatibility with Apple TV.
    var tvOSCandidate: Bool?
    // No public listing in any storefront (removed from sale); the App ID
    // still works for accounts that own it.
    var delisted: Bool?
    /// Internal `CFBundleVersion` read from Info.plist or dispatch ticket.
    var bundleVersion: String? = nil
    /// App Store public marketing version when tracked separately from `CFBundleShortVersionString`.
    var storeMarketingVersion: String? = nil
    static let delistedPlaceholder = "Không có trong cửa hàng công khai"
    var isDelisted: Bool { delisted == true || category == Self.delistedPlaceholder }
    /// Category for display; never the legacy delisted placeholder.
    var displayCategory: String { category == Self.delistedPlaceholder ? "" : category }
}

struct IPadnAppVersion: Codable, Identifiable, Hashable, Sendable {
    /// Version lists from Apple carry only IDs. The placeholder is data, not
    /// display text: it is stored, merged and compared, so it stays fixed.
    static let unknown = "Không rõ phiên bản"
    var id: String
    var version: String
    var source: String
}

struct IPadnVersionListUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Tạm thời không lấy được lịch sử phiên bản, hãy mở “Lấy đầy đủ danh sách phiên bản từ Apple” hoặc nhập tay ID phiên bản"
    }
}

struct IPadnAppleAccount: Codable, Identifiable {
    var id: String
    var name: String
    var password: String
    var cookie: String
    var dsid: String
    var passwordToken: String
    var storeFront: String
    var fullStoreFront: String

    /// Authenticated store session: Apple sign-in issues both DSID and token.
    /// Imported profile placeholders leave credentials empty until signed in here.
    var hasValidSession: Bool {
        !dsid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !passwordToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsReauthentication: Bool { !hasValidSession }

    static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct IPadnDownloadAsset: Codable {
    var app: IPadnStoreApp
    var url: URL
    var sinf: Data?
    var sinfs: [Data]?
    var metadata: Data?
    var externalVersionIDs: [String]
    var platform: String
    var account: String

    init(app: IPadnStoreApp, url: URL, sinf: Data? = nil, sinfs: [Data]? = nil,
         metadata: Data? = nil, externalVersionIDs: [String] = [],
         platform: String = "", account: String = "") {
        self.app = app
        self.url = url
        self.sinf = sinf ?? sinfs?.first
        self.sinfs = sinfs ?? sinf.map { [$0] }
        self.metadata = metadata
        self.externalVersionIDs = externalVersionIDs
        self.platform = platform
        self.account = account
    }

    var decodedMetadata: [String: Any]? {
        guard let metadata, !metadata.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }
}

struct IPadnOwnedApp: Codable, Identifiable {
    var id: String
    var bundleID: String
    var name: String
    var version: String
    var purchaseDate: Date?
    var iconURL: URL?
    var storeApp: IPadnStoreApp {
        IPadnStoreApp(id: id, name: name, bundleID: bundleID, version: version, iconURL: iconURL)
    }
}

struct IPadnOwnedHistorySyncState: Codable, Equatable {
    var completedFullSync: Bool
    var lastSyncedYear: Int
}

enum IPadnSearchQuery: Equatable {
    case keyword(String), appID(String, versionID: String?)

    static func parse(_ input: String) throws -> IPadnSearchQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IPadnToolError.message("Hãy nhập tên app, App ID hoặc link App Store") }
        if let url = URL(string: text), url.host?.lowercased() == "apps.apple.com" {
            let parts = url.pathComponents
            if let id = parts.first(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) && $0.count > 2 }) {
                return .appID(String(id.dropFirst(2)), versionID: nil)
            }
            throw IPadnToolError.message("Link App Store không có App ID hợp lệ")
        }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: " ,，:/+\t\n")).filter { !$0.isEmpty }
        if (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
            return .appID(parts[0], versionID: parts.count == 2 ? parts[1] : nil)
        }
        return .keyword(text)
    }
}

struct IPadnVersionSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var urlTemplate: String
    var containerKey: String
    var reverse: Bool
    var enabled = true

    static let iosDump = IPadnVersionSource(name: "iosdump", urlTemplate: "https://iosdump.apdoilaan.work/history/{appId}", containerKey: "data", reverse: false)
    /// Placeholders for the App ID; both spellings are in use.
    static let placeholders = ["{id}", "{appId}", "{appid}", "{APPID}"]
    var hasPlaceholder: Bool { Self.placeholders.contains { urlTemplate.contains($0) } }
    /// The request URL for `appID`, or nil when the template is not a usable https address.
    func url(for appID: String) -> URL? {
        guard hasPlaceholder else { return nil }
        let filled = Self.placeholders.reduce(urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)) {
            $0.replacingOccurrences(of: $1, with: appID)
        }
        guard let url = URL(string: filled), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
#endif
