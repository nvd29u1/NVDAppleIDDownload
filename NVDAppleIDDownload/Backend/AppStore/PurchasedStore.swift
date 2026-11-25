//  PurchasedStore.swift
//  NVDAppleIDDownload
//
//  Kho danh sách Đã mua (đợt 2, build 7): cache theo tài khoản, đồng bộ
//  qua DMAP, tra cứu thêm icon/gói qua Lookup, tải hàng loạt, xuất CSV.
//

import ApplePackage
import Foundation

@MainActor
@Observable
final class PurchasedStore {
    static let shared = PurchasedStore()

    /// Danh sách app đã mua của tài khoản đang chọn (đọc từ cache trước,
    /// đồng bộ xong thì ghi đè).
    private(set) var items: [PurchasedApp] = []

    /// Tài khoản mà `items` đang thuộc về (id = email).
    private(set) var accountID: String = ""

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?

    /// Chế độ chọn nhiều để tải hàng loạt.
    var isSelecting = false
    var selectedIDs: Set<Int64> = []

    /// Icon (artwork) tra được qua Lookup, theo Bundle ID. DMAP không trả
    /// icon nên phải tra thêm — tra lười theo từng hàng khi hiện ra.
    private(set) var artworkURLs: [String: URL] = [:]

    /// Gói đầy đủ tra được qua Lookup, theo Bundle ID — dùng để mở màn
    /// chi tiết app và để tải. App đã gỡ khỏi App Store mà Lookup vẫn
    /// trả về thì tải được như thường; Lookup không trả về thì hàng đó
    /// vẫn hiện (tên + Bundle ID + ngày mua) nhưng chưa tải được từ đây.
    private(set) var resolvedPackages: [String: AppStore.AppPackage] = [:]

    /// Bundle ID đang tra Lookup dở (để không tra trùng).
    private var enrichingBundleIDs: Set<String> = []

    @ObservationIgnored
    private var _cachedByAccount = Persist<[String: [PurchasedApp]]>(
        key: "PurchasedAppsByAccount",
        defaultValue: [:]
    )

    private init() {}

    /// Chuyển sang tài khoản khác: đọc cache của tài khoản đó (nếu có),
    /// xoá lựa chọn cũ.
    func switchAccount(to accountID: String) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        items = _cachedByAccount.wrappedValue[accountID] ?? []
        lastError = nil
        lastSyncDate = nil // ngày đồng bộ thật chỉ có sau lần sync mới
        isSelecting = false
        selectedIDs = []
    }

    /// Đồng bộ lại danh sách từ Apple qua DMAP. Dùng chung phiên đã đăng
    /// nhập (cookie + token đã lưu), không tạo authenticator mới. Lỗi
    /// tạm thời (máy chủ trả trống / 5xx) thì thử lại tối đa 3 lần như
    /// đăng nhập; lỗi phiên hết hạn thì báo đăng nhập lại, không retry.
    func sync() async {
        guard !accountID.isEmpty, !isSyncing else { return }
        let accountID = self.accountID
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        var lastFailure: Error?
        for attempt in 1 ... 3 {
            do {
                let apps = try await AppStore.this.withAccount(id: accountID) { userAccount in
                    try await PurchasedDMAPService.fetchPurchasedApps(account: userAccount.account)
                }
                items = apps
                var cached = _cachedByAccount.wrappedValue
                cached[accountID] = apps
                _cachedByAccount.wrappedValue = cached
                lastSyncDate = Date()
                logger.info("Purchased sync: \(apps.count) apps for account")
                return
            } catch {
                lastFailure = error
                if let dmapError = error as? PurchasedDMAPError, case .sessionExpired = dmapError {
                    break
                }
                guard Self.isTransientSyncError(error), attempt < 3 else { break }
                logger.info("Purchased sync: transient failure (attempt \(attempt)/3), retrying")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if let lastFailure {
            lastError = lastFailure.localizedDescription
            logger.error("Purchased sync failed: \(StoreDiagnostics.errorSummary(lastFailure))")
        }
    }

    private static func isTransientSyncError(_ error: Error) -> Bool {
        if let dmapError = error as? PurchasedDMAPError {
            if case let .appleRefused(status) = dmapError {
                return [500, 502, 503, 504].contains(status)
            }
            return false
        }
        let message = error.localizedDescription
        return ["HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504", "The network connection was lost", "timed out"]
            .contains { message.contains($0) }
    }

    /// Tra thêm icon + gói đầy đủ cho một hàng qua Lookup ở vùng tìm kiếm
    /// đang chọn. Chỉ tra 1 lần cho mỗi Bundle ID; tra hỏng thì thôi (hàng
    /// vẫn hiện tên + Bundle ID), lần mở màn chi tiết sẽ tra lại.
    func enrich(_ item: PurchasedApp, region: String) async {
        guard !item.bundleID.isEmpty,
              resolvedPackages[item.bundleID] == nil,
              enrichingBundleIDs.insert(item.bundleID).inserted
        else { return }
        defer { enrichingBundleIDs.remove(item.bundleID) }
        guard let package = await lookupPackage(bundleID: item.bundleID, region: region) else { return }
        resolvedPackages[item.bundleID] = package
        if let artworkURL = URL(string: package.software.artworkUrl) {
            artworkURLs[item.bundleID] = artworkURL
        }
    }

    /// Lấy gói đầy đủ cho một mục Đã mua để mở màn chi tiết / tải: dùng
    /// gói đã tra được, nếu chưa có thì tra Lookup ngay. Trả nil khi app
    /// không còn tra được trên App Store ở vùng đang tìm.
    func resolvePackage(for item: PurchasedApp, region: String) async -> AppStore.AppPackage? {
        if let package = resolvedPackages[item.bundleID] {
            return package
        }
        guard let package = await lookupPackage(bundleID: item.bundleID, region: region) else {
            return nil
        }
        resolvedPackages[item.bundleID] = package
        if let artworkURL = URL(string: package.software.artworkUrl) {
            artworkURLs[item.bundleID] = artworkURL
        }
        return package
    }

    /// Lookup theo Bundle ID ở vùng tìm kiếm đang chọn. App chỉ có trên
    /// iPad thì Lookup kiểu iPhone có thể không trúng nên thử thêm kiểu
    /// iPad. (Lookup thường vẫn trả về app đã gỡ khỏi cửa hàng.)
    private func lookupPackage(bundleID: String, region: String) async -> AppStore.AppPackage? {
        for entityType in [ApplePackage.EntityType.iPhone, .iPad] {
            if let software = try? await ApplePackage.Lookup.lookup(
                bundleID: bundleID,
                countryCode: region,
                entityType: entityType
            ) {
                return AppStore.AppPackage(software: software, entityType: entityType)
            }
        }
        return nil
    }

    /// Tải hàng loạt các app đang chọn: tra gói từng app rồi đưa vào hàng
    /// đợi tải như bấm "Yêu cầu tải" ở màn chi tiết. App nào tra không
    /// được (đã gỡ hẳn khỏi App Store) thì bỏ qua và tính vào số lỗi.
    /// Trả về (số app đã đưa vào hàng đợi, số app không tải được).
    func downloadSelected(region: String) async -> (succeeded: Int, failed: Int) {
        guard !accountID.isEmpty else { return (0, 0) }
        let accountID = self.accountID
        let selected = items.filter { selectedIDs.contains($0.appID) }
        var succeeded = 0
        var failed = 0
        for item in selected {
            guard let package = await resolvePackage(for: item, region: region) else {
                failed += 1
                continue
            }
            do {
                try await Downloads.this.startDownload(for: package, accountID: accountID, region: region)
                succeeded += 1
            } catch {
                logger.error("Purchased batch download failed for \(item.bundleID): \(StoreDiagnostics.errorSummary(error))")
                failed += 1
            }
        }
        return (succeeded, failed)
    }

    /// Nội dung CSV danh sách Đã mua: Tên, Bundle ID, Ngày mua (ISO).
    /// Tên có dấu phẩy / ngoặc kép thì bọc ngoặc kép theo chuẩn CSV.
    func csvText() -> String {
        var lines = ["Tên,Bundle ID,Ngày mua"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for item in items {
            let date = item.purchaseDate.map { formatter.string(from: $0) } ?? ""
            lines.append("\(Self.csvField(item.name)),\(Self.csvField(item.bundleID)),\(date)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Ghi CSV ra file tạm rồi trả về URL để mở Share Sheet (Lưu vào Tệp
    /// / AirDrop / chia sẻ). Trả nil khi ghi không được.
    func csvFileURL() -> URL? {
        let fileName = "Da-mua-\(accountID).csv"
        let url = temporaryDirectory.appendingPathComponent(fileName)
        do {
            try csvText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Purchased CSV export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
