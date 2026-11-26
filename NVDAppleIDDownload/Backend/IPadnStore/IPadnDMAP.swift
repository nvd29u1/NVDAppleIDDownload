#if os(iOS)
// Port từ iPadn v2.3.5 (commit c7be403, GPL-2.0-or-later, mengangs/iPadn):
// Services/DMAP.swift. Đã đổi tên tiền tố IPadn/ipadn + dịch chuỗi tiếng Trung sang
// tiếng Việt + bỏ AppText/InstallLog, theo cùng quy ước bản 20 (đăng nhập).
// Giấy phép xem LICENSES.md (GPL-2.0-or-later cho phần lõi iPadn này).
import Foundation

enum IPadnDMAP {
    struct Tag { let name: String; let payload: Data }
    private static let containers: Set<String> = ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"]

    static func tag(_ name: String, _ payload: Data = Data()) -> Data {
        precondition(name.utf8.count == 4 && name.utf8.allSatisfy { (32...126).contains($0) })
        precondition(payload.count <= Int(UInt32.max))
        var data = Data(name.utf8)
        var count = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
    static func uint32(_ name: String, _ value: UInt32) -> Data {
        var number = value.bigEndian
        return withUnsafeBytes(of: &number) { tag(name, Data($0)) }
    }
    static func string(_ name: String, _ value: String) -> Data { tag(name, Data(value.utf8)) }
    static func integer(_ data: Data) throws -> UInt64 {
        guard [1, 4, 8].contains(data.count) else { throw IPadnToolError.message("Số nguyên DMAP sai độ dài") }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    /// Walks tags without copying: payloads are slices of the original buffer
    /// (purchase lists can be several megabytes with deep nesting).
    static func walk(_ data: Data, depth: Int = 0, visitor: (Tag) throws -> Void) throws {
        guard depth <= 16 else { throw IPadnToolError.message("DMAP lồng nhau quá sâu") }
        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            guard end - offset >= 8 else { throw IPadnToolError.message("Thẻ DMAP bị cắt ngắn") }
            let nameBytes = data[offset..<(offset + 4)]
            guard nameBytes.allSatisfy({ (32...126).contains($0) }),
                  let name = String(bytes: nameBytes, encoding: .ascii) else { throw IPadnToolError.message("Tên thẻ DMAP không hợp lệ") }
            let length = data[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let start = offset + 8
            guard UInt64(length) <= UInt64(end - start) else { throw IPadnToolError.message("Dữ liệu DMAP bị cắt ngắn") }
            let stop = start + Int(length)
            let payload = data[start..<stop]
            try visitor(Tag(name: name, payload: payload))
            if containers.contains(name) { try walk(payload, depth: depth + 1, visitor: visitor) }
            offset = stop
        }
    }
    private struct Found: Error { let value: UInt32 }
    static func firstInteger(_ data: Data, name: String) throws -> UInt32? {
        do {
            try walk(data) { tag in
                guard tag.name == name else { return }
                let number = try integer(tag.payload)
                guard number <= UInt32.max else { throw IPadnToolError.message("Số DMAP vượt quá uint32") }
                throw Found(value: UInt32(number)) // stop at the first match
            }
        } catch let found as Found { return found.value }
        return nil
    }
    static func validate(_ data: Data) throws {
        guard let status = try firstInteger(data, name: "mstt") else {
            throw IPadnToolError.message("Tạm thời không đồng bộ được danh sách Đã mua, thử lại sau")
        }
        if status != 200 {
            throw IPadnToolError.message("Tạm thời không đồng bộ được danh sách Đã mua (\(status)), thử lại sau")
        }
    }
    static func ownedApps(_ data: Data) throws -> [IPadnOwnedApp] {
        var apps: [IPadnOwnedApp] = []; var seen = Set<String>()
        try walk(data) { item in
            guard item.name == "mlit" else { return }
            var app = IPadnOwnedApp(id: "", bundleID: "", name: "", version: "")
            try walk(item.payload) { field in
                let text = String(data: field.payload, encoding: .utf8) ?? ""
                switch field.name {
                case "aeSI": app.id = String(try integer(field.payload))
                case "aeBI": app.bundleID = text
                case "aeLN": app.name = text
                case "minm": if app.name.isEmpty { app.name = text }
                case "aePd": app.version = text
                case "asdp": app.purchaseDate = Date(timeIntervalSince1970: Double(try integer(field.payload)))
                default: break
                }
            }
            if !app.id.isEmpty, seen.insert(app.id).inserted { apps.append(app) }
        }
        return apps.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
    }
}

/// Parses and merges Apple's `/commerce/account/purchases` JSON:API purchase history
/// responses so delisted, hidden, and sanctioned apps omitted from `MZPurchaseDaap`
/// remain discoverable and downloadable alongside IPadnDMAP records.
enum IPadnCommercePurchaseHistory {
    struct PageResult: Sendable {
        let apps: [IPadnOwnedApp]
        let isComplete: Bool
        let newInvoiceCount: Int
    }

    static func isAppKind(_ kind: String) -> Bool {
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if ["ios app", "ipad app", "mac app", "apple tv app", "tvos app", "universal app", "app"].contains(normalized) {
            return true
        }
        return normalized.hasSuffix(" app")
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let number = Double(text), number > 0 {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        func makeDate(year: Int, month: Int, day: Int) -> Date? {
            guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
            return utc.date(from: DateComponents(year: year, month: month, day: day))
        }

        // Fast regex matches for ISO date prefix, CJK dates (`2026年11月19日`), and slash/dot dates.
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let ymd = try? NSRegularExpression(pattern: #"(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})"#),
           let match = ymd.firstMatch(in: text, range: nsRange),
           let y = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
           let m = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
           let d = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) }),
           let date = makeDate(year: y, month: m, day: d) {
            return date
        }

        // Flexible English month names (`Nov 19, 2026`, `Nov. 19, 2026`, `19 Nov 2026`, `5 Sept. 2024`).
        let months: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        if let mdy = try? NSRegularExpression(pattern: #"([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2})\D+?(\d{4})"#),
           let match = mdy.firstMatch(in: text, range: nsRange),
           let mon = Range(match.range(at: 1), in: text).map({ text[$0].lowercased() }),
           let m = months[mon],
           let d = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
           let y = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) }),
           let date = makeDate(year: y, month: m, day: d) {
            return date
        }
        if let dmy = try? NSRegularExpression(pattern: #"(\d{1,2})\D+?([A-Za-z]{3})[A-Za-z]*\.?\D*?(\d{4})"#),
           let match = dmy.firstMatch(in: text, range: nsRange),
           let d = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
           let mon = Range(match.range(at: 2), in: text).map({ text[$0].lowercased() }),
           let m = months[mon],
           let y = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) }),
           let date = makeDate(year: y, month: m, day: d) {
            return date
        }

        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for localeID in ["en_US_POSIX", "ru_RU", "zh_CN", "zh_TW", "ja_JP", "ko_KR", "de_DE", "fr_FR", "es_ES", "pt_BR"] {
            formatter.locale = Locale(identifier: localeID)
            for format in ["d MMM yyyy 'г.'", "d MMM yyyy", "d MMMM yyyy 'г.'", "d MMMM yyyy", "MM/dd/yyyy", "dd.MM.yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    static func parsePage(_ data: Data, seenOrderIDs: inout Set<String>) throws -> PageResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["data"] as? [String: Any],
              let attributes = envelope["attributes"] as? [String: Any] else {
            throw IPadnToolError.message("Dữ liệu lịch sử mua trả về sai định dạng, thử lại sau")
        }
        let isComplete = ((attributes["is-complete"] ?? attributes["isComplete"]) as? Bool) ?? true
        let purchases = (attributes["purchases"] as? [[String: Any]]) ?? []
        var apps: [IPadnOwnedApp] = []
        var addedInvoices = 0
        func rawValueString(_ value: Any?) -> String {
            if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = value as? NSNumber { return n.stringValue }
            return ""
        }
        for invoice in purchases {
            let orderID = rawValueString(invoice["order-id"] ?? invoice["orderId"])
            if !orderID.isEmpty, !seenOrderIDs.insert(orderID).inserted { continue }
            addedInvoices += 1
            let invoiceDate = rawValueString(invoice["invoice-date"] ?? invoice["invoiceDate"])
            let items = (invoice["items"] as? [[String: Any]]) ?? []
            for item in items {
                let kind = rawValueString(item["kind"])
                guard isAppKind(kind) else { continue }
                let rawID = rawValueString(item["item-id"] ?? item["itemId"])
                guard !rawID.isEmpty, rawID.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
                let primaryName = rawValueString(item["item-name"] ?? item["itemName"])
                let fallbackName = rawValueString(item["item-title"] ?? item["itemTitle"])
                let name = primaryName.isEmpty ? fallbackName : primaryName
                let rawDate = rawValueString(item["purchase-date"] ?? item["purchaseDate"])
                let date = parseDate(rawDate.isEmpty ? invoiceDate : rawDate)
                apps.append(IPadnOwnedApp(id: rawID, bundleID: "", name: name, version: "", purchaseDate: date))
            }
        }
        return PageResult(apps: apps, isComplete: isComplete, newInvoiceCount: addedInvoices)
    }

    static func pod(fromCookie cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "itspod" else { continue }
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) { return value }
        }
        return nil
    }

    static func pod(fromHost host: String) -> String? {
        let lower = host.lowercased()
        guard lower.hasPrefix("p"), lower.hasSuffix("-buy.itunes.apple.com") else { return nil }
        let digits = String(lower.dropFirst().dropLast("-buy.itunes.apple.com".count))
        return (!digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber })) ? digits : nil
    }

    /// Merges IPadnDMAP active-catalog records, full Commerce Purchase History records, and any
    /// previously cached entries by App ID without dropping delisted or historical apps.
    static func merge(dmap: [IPadnOwnedApp], commerce: [IPadnOwnedApp], cached: [IPadnOwnedApp] = []) -> [IPadnOwnedApp] {
        var byID: [String: IPadnOwnedApp] = [:]
        func absorb(_ incoming: IPadnOwnedApp, preferMetadata: Bool) {
            guard !incoming.id.isEmpty else { return }
            guard var current = byID[incoming.id] else {
                byID[incoming.id] = incoming
                return
            }
            if preferMetadata {
                if !incoming.name.isEmpty { current.name = incoming.name }
                if !incoming.bundleID.isEmpty { current.bundleID = incoming.bundleID }
                if !incoming.version.isEmpty { current.version = incoming.version }
                if let date = incoming.purchaseDate {
                    if let existingDate = current.purchaseDate {
                        current.purchaseDate = max(existingDate, date)
                    } else {
                        current.purchaseDate = date
                    }
                }
                if let icon = incoming.iconURL { current.iconURL = icon }
            } else {
                if current.name.isEmpty && !incoming.name.isEmpty { current.name = incoming.name }
                if current.bundleID.isEmpty && !incoming.bundleID.isEmpty { current.bundleID = incoming.bundleID }
                if current.version.isEmpty && !incoming.version.isEmpty { current.version = incoming.version }
                if let date = incoming.purchaseDate {
                    if let existingDate = current.purchaseDate {
                        current.purchaseDate = max(existingDate, date)
                    } else {
                        current.purchaseDate = date
                    }
                }
                if current.iconURL == nil, let icon = incoming.iconURL { current.iconURL = icon }
            }
            byID[incoming.id] = current
        }
        // Seed with cached entries first so historical commerce rows survive incremental syncs,
        // layer commerce records on top, and apply IPadnDMAP's richer bundleID/version metadata last.
        for item in cached { absorb(item, preferMetadata: false) }
        for item in commerce { absorb(item, preferMetadata: false) }
        for item in dmap { absorb(item, preferMetadata: true) }
        return byID.values.sorted { lhs, rhs in
            let lDate = lhs.purchaseDate ?? .distantPast
            let rDate = rhs.purchaseDate ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.id < rhs.id
        }
    }
}
#endif
