#if os(iOS)
import ApplePackage
import Foundation

// MARK: - Cầu nối lõi store iPadn (3.0 build 1)
//
// Lõi store port từ iPadn v2.3.5 (IPadnAppleService, GPL-2.0-or-later)
// chỉ giữ tài khoản trong bộ nhớ; AppStore của app mới là nguồn thật
// duy nhất (Keychain + Persist). Cầu nối này là chỗ duy nhất dịch qua
// lại giữa tài khoản fork (ApplePackage.Account) và tài khoản iPadn
// (IPadnAppleAccount), và dịch lỗi iPadn về các kiểu lỗi sẵn có của app
// để UI + PurchasedStore + ProductView không phải đổi gì.
//
// - Một IPadnAppleService dùng chung cho cả 3 đường (Đã mua / Commerce
//   / tải), với signer WASM riêng (IPadnLoginService giữ một signer
//   riêng cho đăng nhập — 2 runtime WASM, chấp nhận được, như bản 20
//   đã ghi).
// - iPadn chỉ có MỘT tài khoản đang dùng tại một thời điểm (activeID);
//   app mình đa tài khoản nên mọi lần gọi qua cầu nối đều xếp hàng
//   nối tiếp (withSerial) — không để 2 tài khoản khác nhau chen nhau
//   làm lõi báo "Tài khoản đã đổi".
// - Sau mỗi lần gọi, cookie mới gộp từ response store được ghi về tài
//   khoản fork đã lưu (syncCookieBack) để các đường fork còn lại (tìm
//   kiếm / mua license) dùng tiếp; đường tải còn cập nhật luôn bản sao
//   local (inout) để caller ghi tiếp qua withAccount của nó.

/// Tên vùng hiển thị cho lỗi lệch vùng của lõi iPadn port sang
/// (IPadnAppleStorefrontDownloadError.errorDescription gọi
/// StoreRegions.name). Dùng bảng vùng sẵn có của app (177 vùng).
enum StoreRegions {
    static func name(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let region = StoreRegionCatalog.all.first(where: { $0.code == upper }) {
            return "\(region.vietnameseName) (\(upper))"
        }
        return upper
    }
}

@MainActor
final class IPadnStoreBridge {
    static let shared = IPadnStoreBridge()

    private let service: IPadnAppleService
    private var tail: Task<Void, Never> = Task {}

    private init() {
        service = IPadnAppleService(signer: IPadnSAPSigner())
    }

    // MARK: - Đã mua (DMAP)

    /// Danh sách Đã mua qua lõi iPadn (ownedApps: login → update → items,
    /// chỉ kind app 131072). Giữ nguyên kiểu lỗi + chữ ký hàm của
    /// PurchasedDMAPService để PurchasedStore không phải đổi gì.
    func purchasedApps(account: ApplePackage.Account) async throws -> [PurchasedApp] {
        do {
            return try await run(account: account) {
                let owned = try await self.service.ownedApps(useCache: true)
                let apps = owned.compactMap(Self.purchasedApp(from:))
                logger.info("Purchased DMAP (iPadn): \(apps.count) apps")
                return apps
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapDMAPError(error)
        }
    }

    // MARK: - Lịch sử mua đầy đủ (Commerce)

    /// Lịch sử mua đầy đủ qua lõi iPadn (commercePurchaseHistory, quét
    /// từng năm từ 2008, tự làm mới phiên khi 401/403). Giữ nguyên kiểu
    /// lỗi + chữ ký hàm của PurchasedCommerceService.
    func commerceHistory(account: ApplePackage.Account) async throws -> [PurchasedApp] {
        do {
            return try await run(account: account) {
                let result = try await self.service.commercePurchaseHistory(
                    sinceYear: 2008, allowSessionRefresh: true)
                let apps = result.apps.compactMap(Self.purchasedApp(from:))
                logger.info("Purchased commerce (iPadn): \(apps.count) apps, complete=\(result.complete)")
                return apps
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapCommerceError(error)
        }
    }

    // MARK: - Tải (asset)

    /// Lấy thông tin gói tải qua lõi iPadn (asset: versionTicket khi chưa
    /// có version ID, kbsync, tự refresh phiên, tự lấy license free khi
    /// operation là download). Trả về dict `item` đúng hình dạng các
    /// parse closure của StoreDownloadService đang chờ (URL, metadata,
    /// sinfs) để output()/versions()/versionMetadata() không đổi gì.
    /// `region` là vùng của gói đang xem (nếu caller biết) — lõi dùng
    /// làm store.country để chẩn đoán lệch vùng + lấy license; không có
    /// thì lấy vùng của tài khoản.
    func fetchProductItem(
        account: inout ApplePackage.Account,
        package: AppStore.AppPackage,
        version: String?,
        operation: String,
        region: String?,
        trace: String
    ) async throws -> [String: Any] {
        let platform = Self.ipadnPlatform(for: package.entityType)
        let country = region
            ?? ApplePackage.Configuration.countryCode(for: account.store)
            ?? "US"
        let store = IPadnStoreContext(country: country, platform: platform)
        let allowLicense = (operation == "download")
        let item: [String: Any]
        do {
            item = try await run(account: account) {
                let asset = try await self.service.asset(
                    appID: String(package.software.id), versionID: version,
                    store: store, useCache: true,
                    allowLicenseAcquisition: allowLicense)
                return try Self.productItem(from: asset)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapDownloadError(error)
        }
        // Ghi cookie mới vào bản sao local để caller (withAccount) ghi
        // tiếp; run() ở trên đã ghi về tài khoản lưu qua syncCookieBack.
        if let merged = service.liveCookie(for: account.email) {
            account.cookie = Self.parseCookieString(merged)
        }
        logger.info("Store download [\(trace)]: product item ready (iPadn asset)")
        return item
    }

    // MARK: - Khung chạy chung

    /// Xếp hàng nối tiếp + đặt tài khoản + ghi cookie về sau mỗi lần gọi.
    private func run<T>(account: ApplePackage.Account, _ body: @escaping () async throws -> T) async throws -> T {
        try await withSerial {
            self.service.useAccount(self.ipadnAccount(from: account))
            do {
                let result = try await body()
                await self.syncCookieBack(for: account)
                return result
            } catch {
                await self.syncCookieBack(for: account)
                throw error
            }
        }
    }

    /// Chạy body sau khi lần gọi trước xong (FIFO theo thứ tự gọi).
    private func withSerial<T>(_ body: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let resultTask = Task<T, Error> {
            await previous.value
            return try await body()
        }
        tail = Task { _ = await resultTask.result }
        return try await resultTask.value
    }

    // MARK: - Mapping tài khoản

    /// Tài khoản fork -> tài khoản iPadn (chỉ trong bộ nhớ).
    private func ipadnAccount(from account: ApplePackage.Account) -> IPadnAppleAccount {
        let name = [account.firstName, account.lastName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return IPadnAppleAccount(
            id: account.email,
            name: name,
            password: account.password,
            cookie: Self.dedupedCookieString(cookies: account.cookie),
            dsid: account.directoryServicesIdentifier,
            passwordToken: account.passwordToken,
            storeFront: account.store,
            fullStoreFront: Self.fullStoreFront(for: account))
    }

    /// Storefront đầy đủ Apple trả lúc đăng nhập (vd "143467-1,34"):
    /// dùng giá trị đã lưu khi nó thuộc đúng store của tài khoản; nếu
    /// tài khoản đã bị chỉnh store (vd bản sao -128 của đường tải) thì
    /// dựng lại từ store hiện tại để header khớp đúng vùng đang thử.
    private static func fullStoreFront(for account: ApplePackage.Account) -> String {
        if let saved = AppStore.this.fullStoreFront(dsid: account.directoryServicesIdentifier),
           !saved.isEmpty,
           saved.split(separator: "-", maxSplits: 1).first.map(String.init) == account.store {
            return saved
        }
        return "\(account.store)-1,34"
    }

    /// Ghi cookie mới (đã gộp từ response store) về tài khoản fork đã
    /// lưu, chỉ khi khác chuỗi cũ.
    private func syncCookieBack(for account: ApplePackage.Account) async {
        guard let merged = service.liveCookie(for: account.email) else { return }
        guard merged != Self.dedupedCookieString(cookies: account.cookie) else { return }
        let cookies = Self.parseCookieString(merged)
        do {
            try await AppStore.this.withAccount(id: account.email) { userAccount in
                userAccount.account.cookie = cookies
            }
        } catch {
            logger.info("IPadn store bridge: could not write back cookies: \(StoreDiagnostics.errorSummary(error))")
        }
    }

    /// Gộp cookie theo tên (tên sau ghi đè tên trước, giữ thứ tự xuất
    /// hiện đầu — đúng `mergedCookie` của iPadn), chỉ lấy cookie còn hạn.
    private static func dedupedCookieString(cookies: [ApplePackage.Cookie]) -> String {
        let now = Date().timeIntervalSince1970
        var order: [String] = []
        var values: [String: String] = [:]
        for cookie in cookies
            where !cookie.name.isEmpty && !cookie.value.isEmpty
            && (cookie.expiresAt ?? .infinity) > now
        {
            if values[cookie.name] == nil { order.append(cookie.name) }
            values[cookie.name] = cookie.value
        }
        return order.map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    }

    /// Chuỗi "a=b; c=d" -> cookie fork (domain itunes.apple.com, path "/").
    private static func parseCookieString(_ string: String) -> [ApplePackage.Cookie] {
        var cookies: [ApplePackage.Cookie] = []
        for part in string.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard !name.isEmpty, !value.isEmpty else { continue }
            cookies.append(ApplePackage.Cookie(
                name: name, value: value, path: "/", domain: "itunes.apple.com",
                expiresAt: nil, httpOnly: false, secure: false))
        }
        return cookies
    }

    // MARK: - Mapping kết quả

    private static func purchasedApp(from owned: IPadnOwnedApp) -> PurchasedApp? {
        guard let appID = Int64(owned.id), appID != 0 else { return nil }
        // platforms để rỗng (chỉ hiển thị): PurchasedStore giữ hậu tố
        // nền tảng cũ khi gộp cache, mục mới không có hậu tố.
        return PurchasedApp(
            appID: appID, bundleID: owned.bundleID, name: owned.name,
            version: owned.version, purchaseDate: owned.purchaseDate,
            platforms: [])
    }

    private static func ipadnPlatform(for entityType: ApplePackage.EntityType?) -> IPadnAppPlatform {
        switch entityType {
        case .iPad: return .iPadOS
        case .appleTV: return .tvOS
        default: return .iOS
        }
    }

    /// Asset iPadn -> dict `item` mà output()/versions()/
    /// versionMetadata() của StoreDownloadService đang chờ. `sinfs` đánh
    /// id theo vị trí (0, 1, 2...) — đúng như fork làm: SignatureInjector
    /// dùng sinfs[index] theo vị trí, không khớp theo id.
    private static func productItem(from asset: IPadnDownloadAsset) throws -> [String: Any] {
        guard var metadata = asset.decodedMetadata else { throw StoreDownloadError.invalidPackage }
        guard let sinfs = asset.sinfs, !sinfs.isEmpty else { throw StoreDownloadError.invalidPackage }
        if metadata["softwareVersionExternalIdentifiers"] == nil, !asset.externalVersionIDs.isEmpty {
            metadata["softwareVersionExternalIdentifiers"] = asset.externalVersionIDs
        }
        var item: [String: Any] = [
            "URL": asset.url.absoluteString,
            "metadata": metadata,
        ]
        item["sinfs"] = sinfs.enumerated().map { (index, data) -> [String: Any] in
            ["id": Int64(index), "sinf": data]
        }
        return item
    }

    // MARK: - Mapping lỗi

    /// Lỗi iPadn -> PurchasedDMAPError (giữ nguyên ngữ nghĩa UI cũ:
    /// sessionExpired thì PurchasedStore làm mới token rồi thử lại).
    private func mapDMAPError(_ error: Error) -> PurchasedDMAPError {
        if error is IPadnAppleAuthError { return .sessionExpired(step: "items", status: 401) }
        if let http = error as? IPadnHTTPStatusError {
            if http.code == 401 || http.code == 403 {
                return .sessionExpired(step: "items", status: http.code)
            }
            return .appleRefused(http.code)
        }
        return .badResponse
    }

    /// Lỗi iPadn -> PurchasedCommerceError (giữ nguyên ngữ nghĩa UI cũ).
    private func mapCommerceError(_ error: Error) -> PurchasedCommerceError {
        if error is IPadnAppleAuthError { return .sessionExpired }
        if let http = error as? IPadnHTTPStatusError {
            if http.code == 401 || http.code == 403 { return .sessionExpired }
            return .appleRefused(http.code)
        }
        return .networkError(error.localizedDescription)
    }

    /// Lỗi iPadn -> lỗi tải sẵn có của app (StoreDownloadError /
    /// ApplePackageError.licenseRequired) để ProductView + Downloads
    /// chẩn đoán như cũ (đặc biệt mã -128 để popup đổi tài khoản hiện).
    private func mapDownloadError(_ error: Error) -> Error {
        if error is IPadnAppleLicenseError { return ApplePackageError.licenseRequired }
        if let auth = error as? IPadnAppleAuthError {
            return StoreDownloadError.rejected("", auth.localizedDescription)
        }
        if let storefront = error as? IPadnAppleStorefrontDownloadError {
            switch storefront.reason {
            case .accountRegionMismatch:
                return StoreDownloadError.rejected("-128", storefront.localizedDescription)
            case .appUnavailableInAccountRegion:
                return StoreDownloadError.rejected("1010", storefront.localizedDescription)
            case .temporarilyUnavailable:
                return StoreDownloadError.catalogUnavailable
            }
        }
        if let http = error as? IPadnHTTPStatusError {
            return StoreDownloadError.response(http.code)
        }
        if error is IPadnToolError {
            return StoreDownloadError.rejected("", error.localizedDescription)
        }
        return error
    }
}
#endif
