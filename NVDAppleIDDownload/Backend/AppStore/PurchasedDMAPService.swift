//  PurchasedDMAPService.swift
//  NVDAppleIDDownload
//
//  Màn Đã mua, bước DMAP (đợt 2, build 7 — ý tưởng iPadn mục 3, viết lại
//  sạch, KHÔNG copy code iPadn GPL-2.0).
//
//  Cách làm (giao thức công khai của Apple, đã kiểm chứng qua tài liệu
//  công khai của ipatool MIT — endpoint + format DMAP là sự thật kỹ
//  thuật, không phải code có bản quyền):
//  - Endpoint: https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase
//  - POST /login (body rỗng) → lấy session id (tag DMAP "mlid").
//  - POST /update (body form session-id + query lọc app) → lấy revision
//    (tag "musr"). Body này phải ký SAP (header x-apple-actionsignature),
//    giống cách ipatool ký — xem ghi chú SAP bên dưới.
//  - POST /databases/{revision}/items (body DMAP "adsr") → danh sách app
//    đã mua, mỗi mục là một tag "mlit".
//  - Làm 2 lượt cửa hàng: "34" (iPhone/iPad) và "13" (Mac), gộp lại và
//    khử trùng theo App ID.
//  - Tag trong mỗi mục: aeSI (App ID), aeBI (Bundle ID), aeLN (tên),
//    minm (tên dự phòng), aePd (phiên bản lúc mua), asdp (ngày mua,
//    giây Unix), aeMk (loại media), aeSS (nền tảng hỗ trợ).
//  - App đã gỡ khỏi App Store vẫn hiện ở đây (tìm được bằng App ID) và
//    tải được nếu Apple còn phục vụ — đường tải dùng lại
//    StoreDownloadService như app thường.
//  - CHƯA làm bước /commerce/account/purchases trong đợt này (ghi rõ ở
//    màn Đã mua và trong AGENTS.md) — bước đó làm sau.
//
//  Chữ ký SAP: ApplePackage (fork nvd29u1, pin 541c43a) KHÔNG có API
//  lấy lịch sử mua sẵn — chính tài liệu SAPIntegration.md của fork ghi
//  "ipatool also signs purchase-history requests with SAP; ApplePackage
//  does not expose that API". Nhưng cùng tài liệu đó ghi
//  "SAPSigner.connect() also exposes fresh setup for clients needing only
//  signing" — tức SAPSigner là API public để ký body tùy ý. Code dưới
//  dùng đúng API đó: mở một phiên SAP mới (fresh setup, như lúc đăng
//  nhập vẫn làm) rồi ký body /update và /items. Nếu CI báo SAPSigner
//  không public thì chỉ cần sửa fork thêm ~10 dòng để public nó (cùng
//  kiểu như 2 lần thêm anisetteHeaders trước đây) rồi nâng pin — xem
//  AGENTS.md mục đợt 2 build 7.
//

import ApplePackage
import Foundation

/// Một app trong danh sách Đã mua của tài khoản.
struct PurchasedApp: Codable, Identifiable, Hashable {
    /// App ID (Adam ID) của Apple, vd 310633997.
    let appID: Int64
    let bundleID: String
    let name: String
    /// Phiên bản lúc mua (tag aePd); có thể rỗng.
    let version: String
    let purchaseDate: Date?
    /// Nền tảng hỗ trợ, vd ["iPhone", "iPad"] hoặc ["macOS"].
    let platforms: [String]

    var id: Int64 { appID }
}

enum PurchasedDMAPError: LocalizedError {
    /// Phiên đăng nhập hết hạn (Apple trả 401/403).
    case sessionExpired
    /// Apple từ chối yêu cầu (mã HTTP).
    case appleRefused(Int)
    /// Apple trả về dữ liệu DMAP không đọc được / thiếu trường bắt buộc.
    case badResponse
    /// Không mở được phiên ký SAP để ký yêu cầu.
    case sapUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            String(localized: "Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại tài khoản rồi bấm Đồng bộ lại.")
        case let .appleRefused(status):
            String(localized: "Apple đã từ chối yêu cầu xem mục Đã mua (HTTP \(status)). Thử đồng bộ lại sau.")
        case .badResponse:
            String(localized: "Apple trả về danh sách Đã mua không đọc được. Thử đồng bộ lại sau.")
        case .sapUnavailable:
            String(localized: "Không ký được yêu cầu xem mục Đã mua (thiếu API ký SAP trong thư viện ApplePackage). Cần cập nhật fork ApplePackage rồi thử lại.")
        }
    }
}

/// Parser tag DMAP (Digital Media Access Protocol) tự viết: mỗi tag là
/// 4 ký tự mã + 4 byte độ dài big-endian + nội dung. Đây là format nhị
/// phân công khai của Apple (dùng trong iTunes/DAAP từ lâu), viết lại
/// từ mô tả format, không copy code parser của ai.
enum DMAP {
    /// Các tag chứa tag con bên trong (container) — parser đệ quy vào các
    /// tag này khi tìm kiếm; các tag khác là lá.
    static let containers: Set<String> = [
        "adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl",
        "mlcl", "mlit", "mlog", "msrv", "mupd",
    ]

    /// Đọc các tag con trực tiếp trong một khối dữ liệu (không đệ quy).
    /// Tag hỏng (thiếu byte) thì dừng và trả về những tag đã đọc được.
    static func children(of data: Data) -> [(code: String, payload: Data)] {
        var result: [(code: String, payload: Data)] = []
        var offset = 0
        while offset + 8 <= data.count {
            let codeData = data[offset ..< offset + 4]
            guard let code = String(data: codeData, encoding: .ascii) else { break }
            // Độ dài big-endian, ghép tay từng byte (không dùng load(as:)
            // để khỏi phụ thuộc căn chỉnh bộ nhớ).
            let length = UInt32(data[offset + 4]) << 24
                | UInt32(data[offset + 5]) << 16
                | UInt32(data[offset + 6]) << 8
                | UInt32(data[offset + 7])
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(length)
            guard payloadEnd <= data.count else { break }
            result.append((code, data[payloadStart ..< payloadEnd]))
            offset = payloadEnd
        }
        return result
    }

    /// Tìm tag đầu tiên có mã cho trước ở bất kỳ độ sâu nào (đệ quy vào
    /// container). Dùng để lấy "mstt" (trạng thái), "mlid" (session id),
    /// "musr" (revision).
    static func first(_ data: Data, code target: String) -> Data? {
        for (code, payload) in children(of: data) {
            if code == target { return payload }
            if containers.contains(code), let found = first(payload, code: target) {
                return found
            }
        }
        return nil
    }

    /// Đọc số nguyên big-endian 1/2/4/8 byte trong payload của một tag.
    /// Ghép tay từng byte để khỏi phụ thuộc căn chỉnh bộ nhớ.
    static func intValue(_ payload: Data) -> UInt64? {
        guard [1, 2, 4, 8].contains(payload.count) else { return nil }
        var value: UInt64 = 0
        for byte in payload {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// Đọc chuỗi UTF-8 trong payload của một tag.
    static func stringValue(_ payload: Data) -> String {
        String(data: payload, encoding: .utf8) ?? ""
    }

    /// Mã hoá một tag: mã 4 ký tự + độ dài big-endian + nội dung.
    static func encode(code: String, payload: Data) -> Data {
        var result = Data()
        result.append(contentsOf: code.utf8)
        var length = UInt32(payload.count).bigEndian
        result.append(Data(bytes: &length, count: 4))
        result.append(payload)
        return result
    }

    static func encodeUInt32(code: String, value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return encode(code: code, payload: Data(bytes: &bigEndian, count: 4))
    }

    static func encodeUInt8(code: String, value: UInt8) -> Data {
        encode(code: code, payload: Data([value]))
    }

    static func encodeString(code: String, value: String) -> Data {
        encode(code: code, payload: Data(value.utf8))
    }

    /// Trạng thái DMAP ("mstt") phải là 200, nếu không thì Apple đã từ
    /// chối ngay trong body (vd phiên hết hạn).
    static func requireOK(_ data: Data) throws {
        guard let statusData = first(data, code: "mstt"),
              intValue(statusData) == 200
        else { throw PurchasedDMAPError.badResponse }
    }
}

enum PurchasedDMAPService {
    private static let baseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"

    /// Loại media cần lấy trong query DMAP: app iPhone/iPad (131072),
    /// Arcade (262144) và app Mac (67108864).
    private static let mediaQuery =
        "('com.apple.itunes.extended\\-media\\-kind:131072','com.apple.itunes.extended\\-media\\-kind:262144','com.apple.itunes.extended\\-media\\-kind:67108864')"

    /// Lấy toàn bộ danh sách app đã mua của tài khoản (2 lượt cửa hàng
    /// 34 + 13, gộp + khử trùng, mới nhất lên đầu). `account` chỉ đọc —
    /// hàm không đổi gì trong tài khoản đã lưu.
    static func fetchPurchasedApps(account: ApplePackage.Account) async throws -> [PurchasedApp] {
        // Fork ApplePackage trap (precondition) ở cấu hình TLS khi chưa
        // cài device identifier; AppStore.init cài sẵn identifier đã
        // lưu / tạo ngẫu nhiên vào Configuration, nên chạm vào nó trước
        // khi SAPSigner.connect() mở HTTP client đầu tiên.
        await MainActor.run { _ = AppStore.this }
        let signer: ApplePackage.SAPSigner
        do {
            signer = try await ApplePackage.SAPSigner.connect()
        } catch {
            throw PurchasedDMAPError.sapUnavailable
        }
        var all: [PurchasedApp] = []
        for storefrontSuffix in ["34", "13"] {
            let apps = try await fetchStorefront(account: account, signer: signer, storefrontSuffix: storefrontSuffix)
            all.append(contentsOf: apps)
        }
        return merge(all)
    }

    /// Một lượt cửa hàng ("34" = iPhone/iPad, "13" = Mac): login →
    /// update → items.
    private static func fetchStorefront(
        account: ApplePackage.Account,
        signer: ApplePackage.SAPSigner,
        storefrontSuffix: String
    ) async throws -> [PurchasedApp] {
        let session = URLSession(configuration: ephemeralConfiguration(), delegate: nil, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 1. Login: POST body rỗng (phải có Content-Length: 0, nếu không
        // Apple trả 411). Trả về session id trong tag "mlid".
        var loginRequest = URLRequest(url: URL(string: "\(baseURL)/login")!)
        loginRequest.httpMethod = "POST"
        loginRequest.httpBody = Data()
        loginRequest.setValue("0", forHTTPHeaderField: "Content-Length")
        applyHeaders(&loginRequest, account: account, storefrontSuffix: storefrontSuffix)
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        try checkHTTP(loginResponse, label: "login")
        try DMAP.requireOK(loginData)
        // mlid là session id 32-bit của DAAP; Apple mà trả tag 8 byte
        // với giá trị vượt UInt32 thì ép kiểu trực tiếp sẽ trap và văng
        // app — coi như response hỏng, báo lỗi tiếng Việt thay vì crash.
        guard let sessionData = DMAP.first(loginData, code: "mlid"),
              let sessionValue = DMAP.intValue(sessionData),
              sessionValue <= UInt64(UInt32.max)
        else { throw PurchasedDMAPError.badResponse }
        let sessionID = UInt32(sessionValue)

        // 2. Update: POST form session-id + revision + query, ký SAP.
        // Trả về revision trong tag "musr".
        let updateBody = Data("session-id=\(sessionID)&revision-number=(null)&query=\(mediaQuery)".utf8)
        let updateSignature = try await sign(signer: signer, body: updateBody)
        var updateRequest = URLRequest(url: URL(string: "\(baseURL)/update")!)
        updateRequest.httpMethod = "POST"
        updateRequest.httpBody = updateBody
        updateRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        updateRequest.setValue(updateSignature, forHTTPHeaderField: "x-apple-actionsignature")
        applyHeaders(&updateRequest, account: account, storefrontSuffix: storefrontSuffix)
        let (updateData, updateResponse) = try await session.data(for: updateRequest)
        try checkHTTP(updateResponse, label: "update")
        try DMAP.requireOK(updateData)
        // Như mlid ở trên: musr là revision 32-bit, ép kiểu trực tiếp
        // từ tag 8 byte vượt UInt32 sẽ trap — chặn lại thành badResponse.
        guard let revisionData = DMAP.first(updateData, code: "musr"),
              let revisionValue = DMAP.intValue(revisionData),
              revisionValue <= UInt64(UInt32.max)
        else { throw PurchasedDMAPError.badResponse }
        let revision = UInt32(revisionValue)

        // 3. Items: POST body DMAP "adsr", ký SAP. Trả về các mục "mlit".
        let itemsBody = itemsRequestBody(sessionID: sessionID, revision: revision)
        let itemsSignature = try await sign(signer: signer, body: itemsBody)
        var itemsRequest = URLRequest(url: URL(string: "\(baseURL)/databases/\(revision)/items")!)
        itemsRequest.httpMethod = "POST"
        itemsRequest.httpBody = itemsBody
        itemsRequest.setValue("application/x-dmap-tagged", forHTTPHeaderField: "Content-Type")
        itemsRequest.setValue(itemsSignature, forHTTPHeaderField: "x-apple-actionsignature")
        applyHeaders(&itemsRequest, account: account, storefrontSuffix: storefrontSuffix)
        let (itemsData, itemsResponse) = try await session.data(for: itemsRequest)
        try checkHTTP(itemsResponse, label: "items")
        try DMAP.requireOK(itemsData)
        return parseItems(itemsData)
    }

    /// Body DMAP cho bước items: container "adsr" chứa thời gian hiện
    /// tại (mstc), session id (mlid), loại yêu cầu (mikd = 2), revision
    /// (musr), mder = 0, query (mque) và danh sách trường cần lấy rỗng
    /// (aetl).
    private static func itemsRequestBody(sessionID: UInt32, revision: UInt32) -> Data {
        var inner = Data()
        inner.append(DMAP.encodeUInt32(code: "mstc", value: UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970))))
        inner.append(DMAP.encodeUInt32(code: "mlid", value: sessionID))
        inner.append(DMAP.encodeUInt8(code: "mikd", value: 2))
        inner.append(DMAP.encodeUInt32(code: "musr", value: revision))
        inner.append(DMAP.encodeUInt32(code: "mder", value: 0))
        inner.append(DMAP.encodeString(code: "mque", value: mediaQuery))
        inner.append(DMAP.encode(code: "aetl", payload: Data()))
        return DMAP.encode(code: "adsr", payload: inner)
    }

    /// Ký SAP một body rồi trả về base64 để gắn header
    /// x-apple-actionsignature.
    private static func sign(signer: ApplePackage.SAPSigner, body: Data) async throws -> String {
        do {
            let signature = try await signer.sign(body)
            return signature.base64EncodedString()
        } catch {
            throw PurchasedDMAPError.sapUnavailable
        }
    }

    /// Đọc các mục "mlit" trong body items thành danh sách app. Mục nào
    /// không có App ID (aeSI = 0 / thiếu) thì bỏ.
    private static func parseItems(_ data: Data) -> [PurchasedApp] {
        var apps: [PurchasedApp] = []
        for (code, payload) in DMAP.children(of: data) {
            guard code == "mlit" else { continue }
            if let app = parseItem(payload) {
                apps.append(app)
            }
        }
        // "mlit" cũng có thể nằm sâu trong container "mlcl"/"mupd" — quét
        // đệ quy nếu lượt quét nông không thấy gì (phòng Apple đổi dạng
        // đóng gói).
        if apps.isEmpty {
            apps = collectItems(data)
        }
        return apps
    }

    private static func collectItems(_ data: Data) -> [PurchasedApp] {
        var apps: [PurchasedApp] = []
        for (code, payload) in DMAP.children(of: data) {
            if code == "mlit", let app = parseItem(payload) {
                apps.append(app)
            } else if DMAP.containers.contains(code) {
                apps.append(contentsOf: collectItems(payload))
            }
        }
        return apps
    }

    private static func parseItem(_ data: Data) -> PurchasedApp? {
        var appID: Int64 = 0
        var bundleID = ""
        var name = ""
        var version = ""
        var purchaseDate: Date?
        var mediaKind: UInt64 = 0
        var supportedMask: UInt64 = 0
        for (code, payload) in DMAP.children(of: data) {
            switch code {
            case "aeSI":
                // App ID ép sang Int64 trực tiếp sẽ trap nếu tag 8 byte
                // có bit cao bật; không vừa thì bỏ mục này (guard
                // appID != 0 bên dưới) thay vì văng app.
                if let value = DMAP.intValue(payload), let appIDValue = Int64(exactly: value) {
                    appID = appIDValue
                }
            case "aeBI":
                bundleID = DMAP.stringValue(payload)
            case "aeLN":
                name = DMAP.stringValue(payload)
            case "minm":
                if name.isEmpty { name = DMAP.stringValue(payload) }
            case "aePd":
                version = DMAP.stringValue(payload)
            case "asdp":
                if let seconds = DMAP.intValue(payload) {
                    purchaseDate = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            case "aeMk":
                mediaKind = DMAP.intValue(payload) ?? 0
            case "aeSS":
                supportedMask = DMAP.intValue(payload) ?? 0
            default:
                break
            }
        }
        guard appID != 0 else { return nil }
        return PurchasedApp(
            appID: appID,
            bundleID: bundleID,
            name: name,
            version: version,
            purchaseDate: purchaseDate,
            platforms: platforms(mediaKind: mediaKind, supportedMask: supportedMask)
        )
    }

    /// Nền tảng từ loại media + mặt nạ hỗ trợ: app Mac (67108864) thì
    /// chỉ macOS; app iPhone/iPad/Arcade thì bit 1 = iPhone, 2 = iPad,
    /// 8 = macOS, 16 = visionOS. Không đọc được thì để rỗng (hàng vẫn
    /// hiện, chỉ không ghi nền tảng).
    private static func platforms(mediaKind: UInt64, supportedMask: UInt64) -> [String] {
        if mediaKind == 67_108_864 {
            return ["macOS"]
        }
        guard mediaKind == 131_072 || mediaKind == 262_144 else { return [] }
        var result: [String] = []
        if supportedMask & 1 != 0 { result.append("iPhone") }
        if supportedMask & 2 != 0 { result.append("iPad") }
        if supportedMask & 8 != 0 { result.append("macOS") }
        if supportedMask & 16 != 0 { result.append("visionOS") }
        return result
    }

    /// Gộp 2 lượt cửa hàng, khử trùng theo App ID: giữ tên / Bundle ID /
    /// phiên bản đã có, gộp nền tảng, lấy ngày mua mới nhất.
    private static func merge(_ apps: [PurchasedApp]) -> [PurchasedApp] {
        var byID: [Int64: PurchasedApp] = [:]
        for app in apps {
            if var existing = byID[app.appID] {
                var platforms = existing.platforms
                for platform in app.platforms where !platforms.contains(platform) {
                    platforms.append(platform)
                }
                let date: Date?
                if let new = app.purchaseDate, let old = existing.purchaseDate {
                    date = max(new, old)
                } else {
                    date = app.purchaseDate ?? existing.purchaseDate
                }
                existing = PurchasedApp(
                    appID: existing.appID,
                    bundleID: existing.bundleID.isEmpty ? app.bundleID : existing.bundleID,
                    name: existing.name.isEmpty ? app.name : existing.name,
                    version: existing.version.isEmpty ? app.version : existing.version,
                    purchaseDate: date,
                    platforms: platforms
                )
                byID[app.appID] = existing
            } else {
                byID[app.appID] = app
            }
        }
        return byID.values.sorted {
            switch ($0.purchaseDate, $1.purchaseDate) {
            case let (a?, b?): a > b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.name < $1.name
            }
        }
    }

    private static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    private static func checkHTTP(_ response: URLResponse, label: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PurchasedDMAPError.appleRefused(0)
        }
        logger.info("Purchased DMAP: \(label) HTTP=\(http.statusCode)")
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PurchasedDMAPError.sessionExpired
        }
        guard http.statusCode == 200 else {
            throw PurchasedDMAPError.appleRefused(http.statusCode)
        }
    }

    /// Header xác thực cho DAAP: token + DSID của tài khoản, storefront
    /// của tài khoản kèm hậu tố cửa hàng ("34" / "13"), GUID máy.
    /// Không gửi cookie — DAAP xác thực bằng token, không dùng cookie
    /// như các lệnh tải.
    private static func applyHeaders(_ request: inout URLRequest, account: ApplePackage.Account, storefrontSuffix: String) {
        let now = Date()
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue("5", forHTTPHeaderField: "Client-Cloud-DAAP-Request-Reason")
        request.setValue("1.1/Configurator-2.0", forHTTPHeaderField: "Client-Cloud-Purchase-DAAP-Version")
        request.setValue("3.12", forHTTPHeaderField: "Client-DAAP-Version")
        request.setValue(Self.httpDate(now), forHTTPHeaderField: "Date")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(Self.iso8601(now), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue("en_US", forHTTPHeaderField: "X-Apple-I-Locale")
        request.setValue("UTC", forHTTPHeaderField: "X-Apple-I-Timezone")
        request.setValue("\(account.store)-1,\(storefrontSuffix)", forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue("0", forHTTPHeaderField: "X-Apple-TZ")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-DSID")
        request.setValue(ApplePackage.Configuration.deviceIdentifier, forHTTPHeaderField: "X-GUID")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(ApplePackage.Configuration.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
