//  PurchasedCommerceService.swift
//  NVDAppleIDDownload
//
//  Màn Đã mua, bước /commerce/account/purchases (đợt 4, build 9 — ý
//  tưởng iPadn mục 3, viết lại sạch, KHÔNG copy code iPadn GPL-2.0).
//
//  ⚠️ ĐIỂM CHƯA BIẾT LỚN NHẤT — ĐỌC KỸ TRƯỚC KHI TIN KẾT QUẢ:
//  Hình dạng request/response chính xác của endpoint này CHƯA được xác
//  minh bằng tài khoản thật. Những gì code dưới đây dựa vào là: tên
//  endpoint /commerce/account/purchases (JSON:API) mà iPadn dùng, và
//  cách Apple thường làm JSON:API (khối `data` + `included` + phân
//  trang `links.next`). Có thể Apple trả về dạng khác (tên trường khác,
//  phân trang khác, hoặc yêu cầu thêm tham số / header khác) — khi đó
//  service ném PurchasedCommerceError.unknownShape, PurchasedStore giữ
//  nguyên danh sách DMAP và báo rõ trong màn Đã mua, KHÔNG crash,
//  KHÔNG bịa app. Muốn chắc chắn phải thử thật với tài khoản thật trên
//  iPhone rồi sửa parser theo response thật; CI không kiểm chứng được
//  bước này (không có tài khoản Apple thật trên runner).
//
//  Cách làm (best-effort, học ý tưởng + giao thức, không copy code):
//  - Endpoint: https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/commerce/account/purchases
//    (cùng họ MZFinance với các lệnh mua/tải — xem StoreDownloadService).
//  - Xác thực bằng phiên đã đăng nhập: X-Token, X-DSID,
//    X-Apple-Store-Front, GUID máy, kèm cookie phiên + header
//    Anisette như DMAP (build 15; trước đây thiếu cả hai — nghi
//    phạm số 1 của lỗi HTTP 500 ngày 25/11/2026); body GET nên ký
//    SAP trên body rỗng (như DMAP ký body) nếu ký được, ký không
//    được thì vẫn gửi (token có thể đã đủ) — không dừng cả lần
//    đồng bộ chỉ vì thiếu chữ ký.
//  - Phân trang: theo `links.next` của JSON:API, tối đa 10 trang, gọi
//    tuần tự (không gọi song song để khỏi bị Apple gắn cờ).
//  - Gộp: khử trùng nội bộ theo order-id (id của mục data) rồi theo
//    App ID; PurchasedStore gộp tiếp với kết quả DMAP theo App ID.
//  - Không quét theo từng năm: vì chưa biết endpoint có tham số lọc
//    theo năm hay không, gọi 1 lượt phân trang lấy toàn bộ lịch sử mà
//    endpoint trả về rồi khử trùng; năm đồng bộ đầy đủ ghi theo tài
//    khoản để màn Đã mua hiển thị, không dùng để lọc request.
//

import ApplePackage
import Foundation

enum PurchasedCommerceError: LocalizedError {
    /// Phiên đăng nhập hết hạn (Apple trả 401/403).
    case sessionExpired
    /// Apple từ chối yêu cầu (mã HTTP).
    case appleRefused(Int)
    /// Apple trả về JSON không đúng dạng JSON:API đã biết (tên trường /
    /// cấu trúc khác) — cần thử thật rồi sửa parser theo response thật.
    case unknownShape
    /// Mạng lỗi / không đọc được body.
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            String(localized: "Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại tài khoản rồi bấm Đồng bộ lại.")
        case let .appleRefused(status):
            String(localized: "Apple đã từ chối yêu cầu xem lịch sử mua đầy đủ (HTTP \(status)). Danh sách Đã mua vẫn hiện theo bước DMAP.")
        case .unknownShape:
            String(localized: "Apple trả về lịch sử mua đầy đủ với dạng dữ liệu chưa biết (endpoint /commerce/account/purchases chưa xác minh). Danh sách Đã mua vẫn hiện theo bước DMAP — cần thử thật với tài khoản thật rồi sửa lại cách đọc dữ liệu.")
        case let .networkError(message):
            String(localized: "Không lấy được lịch sử mua đầy đủ: \(message). Danh sách Đã mua vẫn hiện theo bước DMAP.")
        }
    }
}

enum PurchasedCommerceService {
    private static let baseURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/commerce/account/purchases"

    /// Lấy toàn bộ lịch sử mua mà endpoint trả về (phân trang tuần tự
    /// qua links.next, tối đa 10 trang). `account` chỉ đọc — hàm không
    /// đổi gì trong tài khoản đã lưu. `anisetteHeaders` (build 15):
    /// header xác minh thiết bị lấy từ máy chủ Anisette trong Cài đặt —
    /// cùng chính sách như DMAP (build 14); rỗng khi chưa cấu hình.
    static func fetchAllPurchasedApps(account: ApplePackage.Account, anisetteHeaders: [String: String] = [:]) async throws -> [PurchasedApp] {
        var all: [PurchasedApp] = []
        var nextURL: URL? = URL(string: baseURL)
        var pages = 0
        while let url = nextURL, pages < 10 {
            pages += 1
            let (data, next) = try await fetchPage(account: account, url: url, anisetteHeaders: anisetteHeaders)
            all.append(contentsOf: data)
            nextURL = next
        }
        return merge(all)
    }

    /// Một trang: GET JSON:API, theo links.next nếu có. Trả về (app
    /// trong trang, URL trang sau hoặc nil).
    private static func fetchPage(account: ApplePackage.Account, url: URL, anisetteHeaders: [String: String] = [:]) async throws -> ([PurchasedApp], URL?) {
        let session = URLSession(configuration: ephemeralConfiguration(), delegate: nil, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        applyHeaders(&request, account: account, anisetteHeaders: anisetteHeaders)
        // Ký SAP trên body rỗng (GET không có body): ký được thì gắn,
        // ký không được thì vẫn gửi — token có thể đã đủ, xem ghi chú
        // đầu file.
        if let signer = try? await ApplePackage.SAPSigner.connect(),
           let signature = try? await signer.sign(Data())
        {
            request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "x-apple-actionsignature")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PurchasedCommerceError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PurchasedCommerceError.appleRefused(0)
        }
        logger.info("Purchased commerce: HTTP=\(http.statusCode) bytes=\(data.count)")
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PurchasedCommerceError.sessionExpired
        }
        guard http.statusCode == 200 else {
            throw PurchasedCommerceError.appleRefused(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PurchasedCommerceError.unknownShape
        }
        return try parsePage(json)
    }

    /// Đọc 1 trang JSON:API thành danh sách app + URL trang sau.
    /// Chấp nhận nhiều dạng đóng gói (data / results / purchases /
    /// items) và nhiều tên trường vì dạng thật chưa xác minh — nhưng
    /// KHÔNG bịa: mục nào không có App ID hợp lệ thì bỏ, trang nào
    /// không đọc được cấu trúc thì ném unknownShape để UI báo rõ.
    private static func parsePage(_ json: [String: Any]) throws -> ([PurchasedApp], URL?) {
        // Tài nguyên đi kèm (JSON:API `included`): tra cứu theo id để
        // lấy tên / Bundle ID khi mục data chỉ có quan hệ.
        var includedByID: [String: [String: Any]] = [:]
        if let included = json["included"] as? [[String: Any]] {
            for resource in included {
                if let id = stringValue(resource["id"]) {
                    includedByID[id] = resource
                }
            }
        }
        let rawItems: [[String: Any]]
        if let data = json["data"] as? [[String: Any]] {
            rawItems = data
        } else if let results = json["results"] as? [[String: Any]] {
            rawItems = results
        } else if let purchases = json["purchases"] as? [[String: Any]] {
            rawItems = purchases
        } else if let items = json["items"] as? [[String: Any]] {
            rawItems = items
        } else {
            throw PurchasedCommerceError.unknownShape
        }
        var apps: [PurchasedApp] = []
        for raw in rawItems {
            if let app = parseItem(raw, includedByID: includedByID) {
                apps.append(app)
            }
        }
        var nextURL: URL?
        if let links = json["links"] as? [String: Any],
           let next = stringValue(links["next"]),
           let url = URL(string: next)
        {
            nextURL = url
        }
        return (apps, nextURL)
    }

    /// Đọc 1 mục thành PurchasedApp. App ID có thể nằm ở attributes
    /// (nhiều tên trường thử lần lượt), ở id của mục, hoặc ở tài nguyên
    /// included mà mục trỏ tới qua relationships.
    private static func parseItem(_ raw: [String: Any], includedByID: [String: [String: Any]]) -> PurchasedApp? {
        let attributes = raw["attributes"] as? [String: Any] ?? [:]
        // Ghép attributes với tài nguyên included được trỏ tới (nếu có).
        var merged = attributes
        if let relationships = raw["relationships"] as? [String: Any] {
            for (_, relation) in relationships {
                guard let relation = relation as? [String: Any],
                      let data = relation["data"] as? [String: Any],
                      let refID = stringValue(data["id"]),
                      let resource = includedByID[refID],
                      let resourceAttributes = resource["attributes"] as? [String: Any]
                else { continue }
                for (key, value) in resourceAttributes where merged[key] == nil {
                    merged[key] = value
                }
            }
        }
        let appID = intValue(merged["adamId"])
            ?? intValue(merged["appAdamId"])
            ?? intValue(merged["itemId"])
            ?? intValue(merged["appId"])
            ?? intValue(raw["id"])
        guard let appID, appID != 0 else { return nil }
        let bundleID = stringValue(merged["bundleId"])
            ?? stringValue(merged["bundleID"])
            ?? stringValue(merged["bundleIdentifier"])
            ?? ""
        let name = stringValue(merged["name"])
            ?? stringValue(merged["title"])
            ?? stringValue(merged["appName"])
            ?? ""
        let version = stringValue(merged["version"])
            ?? stringValue(merged["bundleShortVersionString"])
            ?? ""
        let purchaseDate = dateValue(merged["purchaseDate"])
            ?? dateValue(merged["purchase-date"])
            ?? dateValue(merged["datePurchased"])
        return PurchasedApp(
            appID: appID,
            bundleID: bundleID,
            name: name,
            version: version,
            purchaseDate: purchaseDate,
            platforms: []
        )
    }

    /// Khử trùng nội bộ theo App ID (order-id đã là id của mục data,
    /// 1 mục = 1 đơn mua; 2 mục cùng App ID mà khác đơn thì giữ ngày
    /// mua mới nhất). Sắp xếp mới nhất lên đầu như DMAP.
    private static func merge(_ apps: [PurchasedApp]) -> [PurchasedApp] {
        var byID: [Int64: PurchasedApp] = [:]
        for app in apps {
            if let existing = byID[app.appID] {
                let date: Date?
                if let new = app.purchaseDate, let old = existing.purchaseDate {
                    date = max(new, old)
                } else {
                    date = app.purchaseDate ?? existing.purchaseDate
                }
                byID[app.appID] = PurchasedApp(
                    appID: existing.appID,
                    bundleID: existing.bundleID.isEmpty ? app.bundleID : existing.bundleID,
                    name: existing.name.isEmpty ? app.name : existing.name,
                    version: existing.version.isEmpty ? app.version : existing.version,
                    purchaseDate: date,
                    platforms: existing.platforms
                )
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

    // MARK: - Đọc giá trị JSON linh hoạt

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String, let parsed = Int64(text) { return parsed }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let text = stringValue(value) else {
            if let number = value as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            return nil
        }
        // ISO 8601 trước, Unix giây sau.
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return nil
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

    /// Header xác thực cho Commerce: token + DSID của tài khoản,
    /// storefront của tài khoản, GUID máy — cùng họ header với DMAP
    /// (PurchasedDMAPService.applyHeaders). Build 15: gửi kèm cookie
    /// phiên đã đăng nhập + header Anisette như DMAP — trước đây bước
    /// này là lệnh store duy nhất không gửi cả hai (nghi phạm số 1
    /// của lỗi HTTP 500 ngày 25/11/2026: Apple trả 500 chứ không
    /// phải 401/403, tức đã qua cửa xác thực rồi lỗi ở bước tra cứu
    /// phía máy chủ).
    private static func applyHeaders(_ request: inout URLRequest, account: ApplePackage.Account, anisetteHeaders: [String: String] = [:]) {
        let now = Date()
        // Không đặt lại Accept ở đây: fetchPage đã đặt
        // "application/vnd.api+json" cho JSON:API.
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.iso8601(now), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue("en_US", forHTTPHeaderField: "X-Apple-I-Locale")
        request.setValue("UTC", forHTTPHeaderField: "X-Apple-I-Timezone")
        request.setValue("\(account.store)-1", forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue("0", forHTTPHeaderField: "X-Apple-TZ")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-DSID")
        request.setValue(ApplePackage.Configuration.deviceIdentifier, forHTTPHeaderField: "X-GUID")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(ApplePackage.Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let url = request.url {
            for (name, value) in account.cookie.buildCookieHeader(url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        for (name, value) in anisetteHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
