//  PurchasedCommerceService.swift
//  NVDAppleIDDownload
//
//  Màn Đã mua, bước /commerce/account/purchases (đợt 4, build 9 — ý
//  tưởng iPadn mục 3, viết lại sạch, KHÔNG copy code iPadn GPL-2.0).
//
//  HÌNH DẠNG REQUEST/RESPONSE ĐÃ XÁC MINH (build 16, từ source iPadn
//  v2.3.5 thật — clone mới 25/11/2026, commit 4357456,
//  `iPadn-iOS/iPadn/Services/AppleService.swift` hàm commerce* +
//  `DMAP.swift` CommercePurchaseHistory; chỉ học giao thức, code dưới
//  đây viết lại theo cấu trúc của app):
//  - GET https://[p<pod>-]buy.itunes.apple.com/commerce/account/purchases
//    ?isDeepLink=false&isJsonApiFormat=true[&page=N]&range=<năm>-all
//    (range là "<năm>-all", vd "2026-all"; quét từng năm, năm hiện tại
//    trước rồi lùi dần tới 2008; page chỉ gửi khi > 1).
//  - Host theo pod khi biết pod (cookie `itspod` / header `pod` / host
//    Location của 302 — dạng p<pod>-buy.itunes.apple.com); 404/5xx thì
//    thử lại 1 lần trên host thường buy.itunes.apple.com.
//  - Header: User-Agent, Accept-Language en-us, X-Dsid, X-Apple-Store-Front,
//    Cookie, X-Token (+ header Anisette của app — cơ chế xác minh thiết
//    bị riêng của app, không trùng các header trên). KHÔNG có Accept,
//    KHÔNG có X-Apple-I-*, KHÔNG có X-GUID, KHÔNG có chữ ký SAP.
//  - Theo 302 thủ công tối đa 4 hop (bắt tay `mzcprh=1` + `itspod`),
//    gộp Set-Cookie vào cookie gửi tiếp, bắt pod từ header `pod` / host.
//  - Response JSON:API thật: data là OBJECT, attributes["is-complete"]
//    + attributes["purchases"] là các hoá đơn (order-id, invoice-date,
//    items[] với kind/item-id/item-name/purchase-date). Phân trang bằng
//    tham số `page`, dừng khi is-complete hoặc hết hoá đơn mới.
//  - 429/5xx thì thử lại tối đa 3 lần (nghỉ 0,5s rồi 1,5s).
//
//  VÌ SAO BẢN 9–15 TOÀN 500 (đã chứng minh bằng log máy thật 18:30
//  25/11 — 3/3 lần HTTP 500, body 38 byte giống hệt nhau, không phải
//  lỗi tạm thời): request cũ KHÔNG có tham số query nào (thiếu range +
//  isDeepLink + isJsonApiFormat nên Apple không xác định được phạm vi
//  tra cứu), gửi thừa Accept application/vnd.api+json + X-Apple-I-* +
//  X-GUID + chữ ký SAP trên body rỗng (không lệnh store nào đang chạy
//  ký GET rỗng), luôn dùng host thường thay vì host theo pod, và parser
//  đi tìm `data` dạng mảng + `links.next` trong khi response thật là
//  `data` dạng object với `attributes.purchases` — kể cả Apple có trả
//  200 thì parser cũ cũng ném unknownShape. Cookie + Anisette ở build
//  15 không sửa được vì đó không phải điểm sai.

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
    #if !os(iOS)
    private static let plainHost = "buy.itunes.apple.com"
    private static let commercePath = "/commerce/account/purchases"
    /// App Store mở tháng 7/2008 — không có hoá đơn nào trước năm này.
    private static let earliestYear = 2008
    private static let maxPagesPerYear = 1000

    /// Kết quả 1 trang đã đọc: app trong trang, còn trang nữa không,
    /// số hoá đơn mới trong trang (dùng để dừng khi hết hoá đơn mới).
    private struct PageParse {
        let apps: [PurchasedApp]
        let isComplete: Bool
        let newInvoiceCount: Int
    }
    #endif

    /// Lấy toàn bộ lịch sử mua: quét từng năm từ năm hiện tại lùi về
    /// 2008 (tuần tự, không song song để khỏi bị Apple gắn cờ). `account`
    /// chỉ đọc — hàm không đổi gì trong tài khoản đã lưu.
    /// `anisetteHeaders` (build 14/15 gửi, build 17 BỎ ở Commerce):
    /// tham số giữ lại, mặc định rỗng — chẩn đoán sau test bản 16
    /// (19:34 25/11: Commerce trả 403 authentication thay vì 500;
    /// iPadn không gửi header xác minh thiết bị ở endpoint này).
    /// DMAP vẫn gửi Anisette headers như cũ.
    /// Năm hiện tại lỗi thì ném ngay (lỗi có hệ thống sẽ giống hệt ở
    /// mọi năm, quét tiếp chỉ tốn lượt); năm cũ lỗi thì bỏ qua năm đó
    /// rồi quét tiếp — danh sách trả về có thể thiếu năm đó nhưng các
    /// năm khác vẫn đủ. Chỉ ném lỗi khi không năm nào lấy được.
    ///
    /// 3.0 build 1: trên iOS dùng lõi iPadn port sang (IPadnStoreBridge →
    /// commercePurchaseHistory) thay cho đường fork dưới đây; macOS giữ
    /// fork (lõi iPadn chỉ port cho iOS). Chữ ký hàm + kiểu lỗi giữ
    /// nguyên nên PurchasedStore không phải đổi gì.
    static func fetchAllPurchasedApps(account: ApplePackage.Account, anisetteHeaders: [String: String] = [:]) async throws -> [PurchasedApp] {
        #if os(iOS)
        return try await IPadnStoreBridge.shared.commerceHistory(account: account)
        #else
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        var all: [PurchasedApp] = []
        var pod = account.pod ?? ""
        var cookie = cookieHeaderValue(cookies: account.cookie)
        if pod.isEmpty { pod = podFromCookie(cookie) ?? "" }
        var lastError: Error?
        var anyYearSucceeded = false
        for year in (earliestYear...currentYear).reversed() {
            do {
                let outcome = try await fetchYear(year: year, pod: pod, cookie: cookie, account: account, anisetteHeaders: anisetteHeaders)
                pod = outcome.pod
                cookie = outcome.cookie
                all.append(contentsOf: outcome.apps)
                anyYearSucceeded = true
            } catch {
                lastError = error
                logger.info("Purchased commerce: year \(year) failed, skipping: \(StoreDiagnostics.errorSummary(error))")
                if year == currentYear { throw error }
            }
        }
        if !anyYearSucceeded, let lastError { throw lastError }
        return merge(all)
        #endif
    }

    #if !os(iOS)
    /// Lấy hết 1 năm: trang 1 (không tham số page), rồi page 2, 3...
    /// cho tới khi is-complete hoặc hết hoá đơn mới.
    private static func fetchYear(year: Int, pod: String, cookie: String, account: ApplePackage.Account, anisetteHeaders: [String: String]) async throws -> (apps: [PurchasedApp], pod: String, cookie: String) {
        var seenOrderIDs = Set<String>()
        var pod = pod
        var cookie = cookie
        var apps: [PurchasedApp] = []
        var fetched = try await fetchPage(year: year, page: nil, pod: pod, cookie: cookie, account: account, anisetteHeaders: anisetteHeaders)
        pod = fetched.pod
        cookie = fetched.cookie
        var parsed = try parsePage(fetched.data, seenOrderIDs: &seenOrderIDs)
        apps.append(contentsOf: parsed.apps)
        var page = 2
        while !parsed.isComplete && parsed.newInvoiceCount > 0 && page <= maxPagesPerYear {
            fetched = try await fetchPage(year: year, page: page, pod: pod, cookie: cookie, account: account, anisetteHeaders: anisetteHeaders)
            pod = fetched.pod
            cookie = fetched.cookie
            parsed = try parsePage(fetched.data, seenOrderIDs: &seenOrderIDs)
            apps.append(contentsOf: parsed.apps)
            page += 1
        }
        return (apps, pod, cookie)
    }

    /// Một trang: GET, theo 302 thủ công, bắt pod + gộp cookie, thử lại
    /// lỗi tạm thời. Pod host 404/5xx thì thử lại 1 lần trên host thường.
    private static func fetchPage(year: Int, page: Int?, pod: String, cookie: String, account: ApplePackage.Account, anisetteHeaders: [String: String]) async throws -> (data: Data, pod: String, cookie: String) {
        guard let url = commerceURL(pod: pod, page: page, year: year) else {
            throw PurchasedCommerceError.networkError("Không tạo được địa chỉ yêu cầu lịch sử mua.")
        }
        var outcome = try await fetchFollowingRedirects(url: url, pod: pod, cookie: cookie, account: account, anisetteHeaders: anisetteHeaders)
        if !pod.isEmpty, outcome.http.statusCode == 404 || (500...599).contains(outcome.http.statusCode),
           let plainURL = commerceURL(pod: "", page: page, year: year)
        {
            logger.info("Purchased commerce: pod host HTTP=\(outcome.http.statusCode), retrying on plain host")
            outcome = try await fetchFollowingRedirects(url: plainURL, pod: "", cookie: outcome.cookie, account: account, anisetteHeaders: anisetteHeaders)
        }
        let http = outcome.http
        let data = outcome.data
        if !(200..<300).contains(http.statusCode) {
            // Body lỗi thường rất ngắn (25/11: 38 byte) nên log nguyên
            // văn để lần sau biết Apple chê cái gì, đừng chỉ log số byte.
            let bodyText = String(data: data, encoding: .utf8) ?? "<body không phải UTF-8 (\(data.count) byte)>"
            logger.info("Purchased commerce: HTTP=\(http.statusCode) bytes=\(data.count) body=\(String(bodyText.prefix(500)))")
        } else {
            logger.info("Purchased commerce: HTTP=\(http.statusCode) bytes=\(data.count)")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PurchasedCommerceError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PurchasedCommerceError.appleRefused(http.statusCode)
        }
        return (data, outcome.pod, outcome.cookie)
    }

    /// Gửi 1 request, theo 302 thủ công tối đa 4 hop (bắt tay pod +
    /// cookie của Apple), gộp Set-Cookie vào cookie gửi tiếp, bắt pod từ
    /// header `pod` hoặc host của URL cuối.
    private static func fetchFollowingRedirects(url: URL, pod: String, cookie: String, account: ApplePackage.Account, anisetteHeaders: [String: String]) async throws -> (data: Data, http: HTTPURLResponse, pod: String, cookie: String) {
        var currentURL = url
        var pod = pod
        var cookie = cookie
        let session = URLSession(configuration: ephemeralConfiguration(), delegate: NoFollowRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for _ in 0...4 {
            let (data, response) = try await sendWithRetry(session: session, url: currentURL, cookie: cookie, account: account, anisetteHeaders: anisetteHeaders)
            guard let http = response as? HTTPURLResponse else {
                throw PurchasedCommerceError.appleRefused(0)
            }
            cookie = mergeSetCookie(into: cookie, response: http)
            if let headerPod = http.value(forHTTPHeaderField: "pod")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !headerPod.isEmpty, headerPod.allSatisfy({ $0.isASCII && $0.isNumber })
            {
                pod = headerPod
            } else if let host = http.url?.host, let hostPod = podFromHost(host) {
                pod = hostPod
            }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                      next.scheme?.lowercased() == "https",
                      let host = next.host?.lowercased(),
                      host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com")
                else {
                    throw PurchasedCommerceError.networkError("Apple chuyển hướng lịch sử mua tới địa chỉ không hợp lệ.")
                }
                if let hostPod = podFromHost(next.host ?? "") { pod = hostPod }
                currentURL = next
                continue
            }
            return (data, http, pod, cookie)
        }
        throw PurchasedCommerceError.networkError("Apple chuyển hướng lịch sử mua quá nhiều lần.")
    }

    /// Một lượt GET, thử lại 429/5xx và lỗi mạng tạm thời tối đa 3 lần
    /// (nghỉ 0,5s rồi 1,5s).
    private static func sendWithRetry(session: URLSession, url: URL, cookie: String, account: ApplePackage.Account, anisetteHeaders: [String: String]) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyHeaders(&request, account: account, cookie: cookie, anisetteHeaders: anisetteHeaders)
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < 2
                {
                    try? await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 500_000_000 : 1_500_000_000))
                    continue
                }
                return (data, response)
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                let nsCode = (error as NSError).code
                let retryable = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(nsCode)
                guard retryable, attempt < 2 else {
                    throw PurchasedCommerceError.networkError(error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 500_000_000 : 1_500_000_000))
            }
        }
        throw (lastError as? PurchasedCommerceError) ?? PurchasedCommerceError.networkError(lastError?.localizedDescription ?? "Không rõ lỗi mạng.")
    }

    /// Địa chỉ 1 trang lịch sử mua theo năm. Tham số query là dữ kiện
    /// giao thức của Apple (thấy trong source iPadn v2.3.5): bắt buộc có
    /// isDeepLink + isJsonApiFormat + range "<năm>-all"; page chỉ gửi
    /// khi > 1.
    private static func commerceURL(pod: String, page: Int?, year: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = pod.isEmpty ? plainHost : "p\(pod)-buy.itunes.apple.com"
        components.path = commercePath
        var items = [
            URLQueryItem(name: "isDeepLink", value: "false"),
            URLQueryItem(name: "isJsonApiFormat", value: "true"),
        ]
        if let page, page > 0 {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }
        items.append(URLQueryItem(name: "range", value: "\(year)-all"))
        components.queryItems = items
        return components.url
    }

    /// Header cho Commerce — đúng tập đã chứng minh chạy được (iPadn
    /// v2.3.5): User-Agent, Accept-Language, X-Dsid, X-Apple-Store-Front,
    /// Cookie, X-Token. Header Anisette: build 17 KHÔNG gửi nữa ở
    /// Commerce (chẩn đoán 403 bản 16 — iPadn không gửi ở endpoint này;
    /// vòng lặp dưới giữ lại cho tham số, mặc định rỗng). Không Accept
    /// riêng, không X-Apple-I-*, không X-GUID, không chữ ký SAP (lệnh
    /// này Apple không ký).
    private static func applyHeaders(_ request: inout URLRequest, account: ApplePackage.Account, cookie: String, anisetteHeaders: [String: String] = [:]) {
        request.setValue(ApplePackage.Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        request.setValue("\(account.store)-1", forHTTPHeaderField: "X-Apple-Store-Front")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if !account.passwordToken.isEmpty {
            request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        }
        for (name, value) in anisetteHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Giá trị header Cookie ("a=b; c=d") từ cookie đã lưu của tài khoản.
    /// Gửi TẤT CẢ cookie còn hạn, KHÔNG lọc domain/path như fork
    /// `buildCookieHeader` — cùng lỗi như DMAP (build 21): cookie lưu
    /// từ đăng nhập iPadn mang domain ".itunes.apple.com" hoặc host-only
    /// của pod buy nên matcher của fork lọc hết → Commerce đi không có
    /// Cookie → 401/403. iPadn gửi nguyên chuỗi cookie (commerceHeaders).
    private static func cookieHeaderValue(cookies: [ApplePackage.Cookie]) -> String {
        let now = Date().timeIntervalSince1970
        return cookies
            .filter { !$0.name.isEmpty && !$0.value.isEmpty }
            .filter { ($0.expiresAt ?? .infinity) > now }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Gộp Set-Cookie trong response vào chuỗi cookie gửi tiếp (cookie
    /// cùng tên thì ghi đè, cookie mới thì thêm vào).
    private static func mergeSetCookie(into cookieString: String, response: HTTPURLResponse) -> String {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let name = key as? String, let text = value as? String { fields[name] = text }
        }
        guard let url = response.url else { return cookieString }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return cookieString }
        var pairs: [(String, String)] = []
        for part in cookieString.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            pairs.append((String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces), String(trimmed[trimmed.index(after: eq)...])))
        }
        for cookie in received {
            if let index = pairs.firstIndex(where: { $0.0.lowercased() == cookie.name.lowercased() }) {
                pairs[index] = (pairs[index].0, cookie.value)
            } else {
                pairs.append((cookie.name, cookie.value))
            }
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// Pod từ host dạng p<pod>-buy.itunes.apple.com.
    private static func podFromHost(_ host: String) -> String? {
        let lower = host.lowercased()
        guard lower.hasPrefix("p"), lower.hasSuffix("-buy.itunes.apple.com") else { return nil }
        let digits = String(lower.dropFirst().dropLast("-buy.itunes.apple.com".count))
        return (!digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber })) ? digits : nil
    }

    /// Pod từ cookie `itspod=<số>`.
    private static func podFromCookie(_ cookieString: String) -> String? {
        for part in cookieString.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "itspod" else { continue }
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) { return value }
        }
        return nil
    }

    /// Đọc 1 trang JSON thành danh sách app + còn trang nữa không + số
    /// hoá đơn mới. Dạng thật (iPadn v2.3.5): data là OBJECT,
    /// attributes["is-complete"] + attributes["purchases"] là các hoá
    /// đơn, mỗi hoá đơn có items[] là app. Dạng mảng cũ (data/results/
    /// purchases/items + links.next) giữ lại làm dự phòng cho 1 trang.
    private static func parsePage(_ data: Data, seenOrderIDs: inout Set<String>) throws -> PageParse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PurchasedCommerceError.unknownShape
        }
        if let envelope = json["data"] as? [String: Any],
           let attributes = envelope["attributes"] as? [String: Any]
        {
            let isComplete = (attributes["is-complete"] as? Bool) ?? (attributes["isComplete"] as? Bool) ?? true
            let invoices = attributes["purchases"] as? [[String: Any]] ?? []
            var apps: [PurchasedApp] = []
            var addedInvoices = 0
            for invoice in invoices {
                let orderID = stringValue(invoice["order-id"]) ?? stringValue(invoice["orderId"]) ?? ""
                if !orderID.isEmpty, !seenOrderIDs.insert(orderID).inserted { continue }
                addedInvoices += 1
                let invoiceDate = stringValue(invoice["invoice-date"]) ?? stringValue(invoice["invoiceDate"])
                let items = invoice["items"] as? [[String: Any]] ?? []
                for item in items {
                    if let app = parseInvoiceItem(item, invoiceDate: invoiceDate) {
                        apps.append(app)
                    }
                }
            }
            return PageParse(apps: apps, isComplete: isComplete, newInvoiceCount: addedInvoices)
        }
        // Dự phòng: dạng mảng cũ (build 9) — chỉ đọc 1 trang, coi là đủ.
        let rawItems: [[String: Any]]
        if let dataArray = json["data"] as? [[String: Any]] {
            rawItems = dataArray
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
        let included = includedByID(from: json)
        for raw in rawItems {
            if let app = parseItem(raw, includedByID: included) {
                apps.append(app)
            }
        }
        return PageParse(apps: apps, isComplete: true, newInvoiceCount: apps.count)
    }

    /// Đọc 1 mục trong hoá đơn thành PurchasedApp. kind phải là app
    /// ("iOS App", "iPad App", "Mac App", ... hoặc kết thúc bằng " App");
    /// item-id phải là số; tên lấy item-name rồi item-title; ngày mua
    /// lấy purchase-date của mục, không có thì lấy invoice-date.
    /// Commerce không trả Bundle ID / phiên bản nên để trống — màn Đã
    /// mua gộp với DMAP sẽ điền thêm.
    private static func parseInvoiceItem(_ item: [String: Any], invoiceDate: String?) -> PurchasedApp? {
        let kind = stringValue(item["kind"]) ?? ""
        guard isAppKind(kind) else { return nil }
        let rawID = stringValue(item["item-id"]) ?? stringValue(item["itemId"]) ?? ""
        guard !rawID.isEmpty, rawID.allSatisfy({ $0.isASCII && $0.isNumber }), let appID = Int64(rawID) else { return nil }
        let name = stringValue(item["item-name"]) ?? stringValue(item["itemName"])
            ?? stringValue(item["item-title"]) ?? stringValue(item["itemTitle"]) ?? ""
        let rawDate = stringValue(item["purchase-date"]) ?? stringValue(item["purchaseDate"]) ?? invoiceDate
        return PurchasedApp(
            appID: appID,
            bundleID: "",
            name: name,
            version: "",
            purchaseDate: rawDate.flatMap(dateValue),
            platforms: []
        )
    }

    private static func isAppKind(_ kind: String) -> Bool {
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if ["ios app", "ipad app", "mac app", "apple tv app", "tvos app", "universal app", "app"].contains(normalized) {
            return true
        }
        return normalized.hasSuffix(" app")
    }

    /// Tài nguyên đi kèm (JSON:API `included`) cho đường dự phòng dạng mảng.
    private static func includedByID(from json: [String: Any]) -> [String: [String: Any]] {
        var includedByID: [String: [String: Any]] = [:]
        if let included = json["included"] as? [[String: Any]] {
            for resource in included {
                if let id = stringValue(resource["id"]) {
                    includedByID[id] = resource
                }
            }
        }
        return includedByID
    }

    /// Đọc 1 mục dạng mảng cũ thành PurchasedApp (đường dự phòng, giữ
    /// nguyên logic build 9). App ID có thể nằm ở attributes (nhiều tên
    /// trường thử lần lượt), ở id của mục, hoặc ở tài nguyên included mà
    /// mục trỏ tới qua relationships.
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
                let seconds = number.doubleValue
                // Số > 10^10 là mili-giây (iPadn: > 10_000_000_000 thì /1000).
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
            }
            return nil
        }
        // ISO 8601 trước, Unix giây (hoặc mili-giây) sau.
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        if let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
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
    #endif
}

/// URLSession delegate chặn redirect để caller theo thủ công (bắt pod +
/// gộp cookie từng hop). Trả nil là không theo — request sẽ hoàn thành
/// với response 3xx để caller tự đọc header Location.
#if !os(iOS)
private final class NoFollowRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
