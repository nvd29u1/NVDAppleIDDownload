//  PurchasedStore.swift
//  NVDAppleIDDownload
//
//  Kho danh sách Đã mua (đợt 2, build 7): cache theo tài khoản, đồng bộ
//  qua DMAP, tra cứu thêm icon/gói qua Lookup, tải hàng loạt, xuất CSV.
//

import ApplePackage
import Foundation

@MainActor
final class PurchasedStore: ObservableObject {
    static let shared = PurchasedStore()

    /// Danh sách app đã mua của tài khoản đang chọn (đọc từ cache trước,
    /// đồng bộ xong thì ghi đè).
    @Published private(set) var items: [PurchasedApp] = []

    /// Tài khoản mà `items` đang thuộc về (id = email).
    @Published private(set) var accountID: String = ""

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastError: String?

    /// Đang đồng bộ toàn bộ lịch sử mua (bước Commerce, đợt 4 build 9).
    @Published private(set) var isSyncingFullHistory = false

    /// Ghi chú khi bước Commerce thất bại nhưng DMAP vẫn cho danh sách:
    /// hiện màu cam (không phải lỗi đỏ) để người dùng biết lịch sử có
    /// thể chưa đủ.
    @Published private(set) var fullHistoryHint: String?

    /// Năm đồng bộ đầy đủ gần nhất theo tài khoản (đợt 4, build 9):
    /// ghi lại khi bước Commerce chạy xong 1 lượt; lần sau chỉ cần quét
    /// năm hiện tại khi đã biết dạng response (xem PurchasedCommerceService).
    private var _fullSyncYears = Persist<[String: Int]>(
        key: "PurchasedFullSyncYearByAccount",
        defaultValue: [:]
    )

    /// Năm đồng bộ đầy đủ gần nhất của tài khoản đang chọn (nil = chưa
    /// bao giờ đồng bộ toàn bộ).
    var lastFullSyncYear: Int? {
        _fullSyncYears.wrappedValue[accountID]
    }

    /// Chế độ chọn nhiều để tải hàng loạt.
    @Published var isSelecting = false
    @Published var selectedIDs: Set<Int64> = []

    /// Icon (artwork) tra được qua Lookup, theo Bundle ID. DMAP không trả
    /// icon nên phải tra thêm — tra lười theo từng hàng khi hiện ra.
    @Published private(set) var artworkURLs: [String: URL] = [:]

    /// Gói đầy đủ tra được qua Lookup, theo Bundle ID — dùng để mở màn
    /// chi tiết app và để tải. App đã gỡ khỏi App Store mà Lookup vẫn
    /// trả về thì tải được như thường; Lookup không trả về thì hàng đó
    /// vẫn hiện (tên + Bundle ID + ngày mua) nhưng chưa tải được từ đây.
    @Published private(set) var resolvedPackages: [String: AppStore.AppPackage] = [:]

    /// Bundle ID đang tra Lookup dở (để không tra trùng).
    private var enrichingBundleIDs: Set<String> = []

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
    /// nhập (cookie + token đã lưu). Lỗi tạm thời (máy chủ trả trống /
    /// 5xx) thì thử lại tối đa 3 lần như đăng nhập; gặp 401/403 thì làm
    /// mới token lặng lẽ 1 lần rồi thử lại — chỉ khi làm mới cũng thất
    /// bại mới báo đăng nhập lại (xem fetchDMAPWithTokenRefresh).
    func sync() async {
        guard !accountID.isEmpty, !isSyncing else { return }
        let accountID = self.accountID
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        var lastFailure: Error?
        for attempt in 1 ... 3 {
            do {
                let apps = try await fetchDMAPWithTokenRefresh(accountID: accountID)
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

    /// Lấy danh sách qua DMAP; gặp 401/403 thì làm mới token 1 lần rồi
    /// thử lại. Đường tải dùng cookie để xác thực nên vẫn chạy được
    /// trong khi X-Token đã cũ — làm mới lặng lẽ là đủ, chỉ sau khi
    /// làm mới cũng thất bại mới coi là phiên hết hạn thật và bắt
    /// đăng nhập lại. Dùng chung cho sync thường + bước DMAP của
    /// đồng bộ toàn bộ lịch sử.
    private func fetchDMAPWithTokenRefresh(accountID: String) async throws -> [PurchasedApp] {
        do {
            return try await AppStore.this.withAccount(id: accountID) { userAccount in
                try await PurchasedDMAPService.fetchPurchasedApps(account: userAccount.account)
            }
        } catch let error as PurchasedDMAPError {
            guard case .sessionExpired = error else { throw error }
            let expiredError = error
            logger.info("Purchased sync: session expired, rotating token once and retrying")
            do {
                let anisetteHeaders = try await AppStore.this.anisetteHeadersForStoreCall()
                try await AppStore.this.withAccount(id: accountID) { userAccount in
                    try await ApplePackage.Authenticator.rotatePasswordToken(for: &userAccount.account, anisetteHeaders: anisetteHeaders)
                }
            } catch {
                // Lỗi lấy header Anisette thì báo đúng lỗi đó (người dùng
                // cần sửa máy chủ Anisette, đăng nhập lại không giúp).
                // Lỗi khác (kể cả Apple đòi mã 2FA khi làm mới) thì giữ
                // nguyên lỗi hết hạn ban đầu — đăng nhập lại mới xong.
                if error is AnisetteService.AnisetteError { throw error }
                logger.error("Purchased sync: token rotation failed: \(StoreDiagnostics.errorSummary(error))")
                throw expiredError
            }
            return try await AppStore.this.withAccount(id: accountID) { userAccount in
                try await PurchasedDMAPService.fetchPurchasedApps(account: userAccount.account)
            }
        }
    }

    /// Đồng bộ toàn bộ lịch sử mua (đợt 4, build 9): bước Commerce
    /// (/commerce/account/purchases) gộp với bước DMAP, khử trùng theo
    /// App ID. Commerce thất bại (dạng response chưa xác minh — xem
    /// PurchasedCommerceService) thì vẫn giữ danh sách DMAP và chỉ ghi
    /// chú cam, không xoá danh sách, không báo lỗi đỏ. Commerce chạy
    /// xong thì ghi năm đồng bộ đầy đủ cho tài khoản này.
    func syncFullHistory() async {
        guard !accountID.isEmpty, !isSyncing, !isSyncingFullHistory else { return }
        let accountID = self.accountID
        isSyncingFullHistory = true
        lastError = nil
        fullHistoryHint = nil
        defer { isSyncingFullHistory = false }

        // 1. Bước Commerce: 1 lượt phân trang tuần tự (không song song
        // để khỏi bị Apple gắn cờ). Thất bại thì ghi chú, không dừng.
        // Lỗi tạm thời (vd Apple trả 500) thì thử lại tối đa 3 lần như
        // bước DMAP. Header Anisette lấy chung 1 lần như DMAP (build
        // 14/15); lấy không được thì bước này lỗi với đúng lỗi đó —
        // bước DMAP phía sau cũng sẽ báo lỗi đó (cùng chính sách).
        var commerceApps: [PurchasedApp] = []
        var commerceError: Error?
        do {
            let anisetteHeaders = try await AppStore.this.anisetteHeadersForStoreCall()
            for attempt in 1 ... 3 {
                do {
                    commerceApps = try await AppStore.this.withAccount(id: accountID) { userAccount in
                        try await PurchasedCommerceService.fetchAllPurchasedApps(account: userAccount.account, anisetteHeaders: anisetteHeaders)
                    }
                    commerceError = nil
                    break
                } catch {
                    commerceError = error
                    guard Self.isTransientSyncError(error), attempt < 3 else { break }
                    logger.info("Purchased full sync: commerce transient failure (attempt \(attempt)/3), retrying")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } catch {
            commerceError = error
        }
        if let commerceError {
            logger.error("Purchased full sync: commerce step failed: \(StoreDiagnostics.errorSummary(commerceError))")
        }

        // 2. Bước DMAP (như sync thường, retry tối đa 3 lần, gặp 401/403
        // thì làm mới token 1 lần rồi thử lại — xem
        // fetchDMAPWithTokenRefresh).
        var dmapApps: [PurchasedApp] = []
        var dmapFailure: Error?
        for attempt in 1 ... 3 {
            do {
                dmapApps = try await fetchDMAPWithTokenRefresh(accountID: accountID)
                dmapFailure = nil
                break
            } catch {
                dmapFailure = error
                if let dmapError = error as? PurchasedDMAPError, case .sessionExpired = dmapError {
                    break
                }
                guard Self.isTransientSyncError(error), attempt < 3 else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if let dmapFailure, commerceError != nil {
            // Cả hai bước đều hỏng: báo lỗi đỏ như sync thường.
            lastError = dmapFailure.localizedDescription
            logger.error("Purchased full sync failed: \(StoreDiagnostics.errorSummary(dmapFailure))")
            return
        }

        // 3. Gộp Commerce + DMAP, khử trùng theo App ID.
        let merged = Self.merge(commerce: commerceApps, dmap: dmapApps)
        items = merged
        var cached = _cachedByAccount.wrappedValue
        cached[accountID] = merged
        _cachedByAccount.wrappedValue = cached
        lastSyncDate = Date()
        if commerceError == nil {
            var years = _fullSyncYears.wrappedValue
            years[accountID] = Calendar.current.component(.year, from: Date())
            _fullSyncYears.wrappedValue = years
            logger.info("Purchased full sync: \(merged.count) apps (\(commerceApps.count) commerce + \(dmapApps.count) DMAP) for account")
        } else {
            fullHistoryHint = commerceError?.localizedDescription
            logger.info("Purchased full sync: \(merged.count) apps (DMAP only, commerce step failed) for account")
        }
    }

    /// Gộp 2 nguồn Đã mua, khử trùng theo App ID: giữ tên / Bundle ID /
    /// phiên bản đã có, lấy ngày mua mới nhất, gộp nền tảng (DMAP cho
    /// nền tảng, Commerce thường không trả nền tảng).
    private static func merge(commerce: [PurchasedApp], dmap: [PurchasedApp]) -> [PurchasedApp] {
        var byID: [Int64: PurchasedApp] = [:]
        for app in commerce + dmap {
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
