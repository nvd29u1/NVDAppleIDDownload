//
//  AppStore.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation

@MainActor
class AppStore: ObservableObject {
    private var _accounts = Persist<[UserAccount]>(
        key: "Accounts",
        defaultValue: [],
        engine: KeychainStorage(service: "com.NVD.appleiddownload.Accounts"),
    )

    var accounts: [UserAccount] {
        get {
            return _accounts.wrappedValue
        }
        set {
            objectWillChange.send()
            _accounts.wrappedValue = newValue
        }
    }

    private var _deviceIdentifier = Persist<String>(
        key: "DeviceIdentifier",
        defaultValue: "",
        engine: KeychainStorage(service: "com.NVD.appleiddownload.DeviceIdentifier"),
    )

    var deviceIdentifier: String {
        get {
            return _deviceIdentifier.wrappedValue
        }
        set {
            objectWillChange.send()
            _deviceIdentifier.wrappedValue = newValue
            ApplePackage.Configuration.deviceIdentifier = newValue
        }
    }

    private var _demoMode = Persist<Bool>(key: "DemoMode", defaultValue: false)

    var demoMode: Bool {
        get {
            return _demoMode.wrappedValue
        }
        set {
            objectWillChange.send()
            _demoMode.wrappedValue = newValue
        }
    }

    /// Default manifest server (NVD Cloudflare worker) used to install
    /// downloaded apps directly. Only builds the manifest plist — the IPA
    /// itself never leaves the phone. Empty string = built-in local server.
    static let defaultManifestServerURL = "https://nvd-manifest.nguyenvietdung156195.workers.dev"

    private var _manifestServerURL = Persist<String>(
        key: "ManifestServerURL",
        defaultValue: defaultManifestServerURL,
    )

    var manifestServerURL: String {
        get {
            return _manifestServerURL.wrappedValue
        }
        set {
            objectWillChange.send()
            _manifestServerURL.wrappedValue = newValue
        }
    }

    /// URL of the Anisette server (e.g. http://192.168.1.10:6969)
    /// that serves device-verification (Anisette/ADI) headers as JSON.
    /// The app fetches the headers from this server before signing in
    /// and attaches them to the Apple sign-in requests. Only the server
    /// URL is stored here — no Apple ID or password is ever sent to
    /// this server.
    /// Build 18: no stored value means "use the default server"
    /// (`AnisetteService.defaultServerURL`, jkcoxson — the server the
    /// user already uses, verified live), so the store path always has
    /// a server and the user never has to type one by hand. There is no
    /// "off" anymore: since Nov 2026 Apple gates sign-in on Anisette
    /// headers, signing in header-less fails with an empty 204 (proven
    /// on the real device 20:32 25/11 when the URL was deleted) — the
    /// old "empty = off" behaviour only produced a cryptic failure.
    /// The picker in Settings shows this effective value, never blank.
    private var _anisetteServerURL = Persist<String>(
        key: "AnisetteServerURL",
        defaultValue: "",
    )

    var anisetteServerURL: String {
        get {
            let stored = _anisetteServerURL.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? AnisetteService.defaultServerURL : stored
        }
        set {
            objectWillChange.send()
            _anisetteServerURL.wrappedValue = newValue
        }
    }

    /// Bật "Chia sẻ IPA qua Wi-Fi" (đợt 3, build 8): chỉ là công tắc cho
    /// phép mở màn Chia sẻ qua Wi-Fi — máy chủ chỉ chạy khi đang ở màn
    /// đó, rời màn là tắt, không chạy nền.
    private var _wifiTransferEnabled = Persist<Bool>(
        key: "WiFiTransferEnabled",
        defaultValue: false,
    )

    var wifiTransferEnabled: Bool {
        get {
            return _wifiTransferEnabled.wrappedValue
        }
        set {
            objectWillChange.send()
            _wifiTransferEnabled.wrappedValue = newValue
        }
    }

    /// Bật khoá app bằng Face ID / Touch ID / mật khẩu thiết bị (đợt 3,
    /// build 8 — LocalAuthentication, không lưu mật khẩu nào trong app).
    /// Mở app lên là khoá; rời app thì khoá lại ngay.
    private var _appLockEnabled = Persist<Bool>(
        key: "AppLockEnabled",
        defaultValue: false,
    )

    var appLockEnabled: Bool {
        get {
            return _appLockEnabled.wrappedValue
        }
        set {
            objectWillChange.send()
            _appLockEnabled.wrappedValue = newValue
        }
    }

    /// Bật "Tải xong tự cài đặt" (đợt 4, build 9 — ý tưởng iPadn mục 8):
    /// tải xong thì tự mở đường cài đặt hiện có của iOS (Installer +
    /// itms-services qua máy chủ manifest trong Cài đặt). Mặc định TẮT
    /// — tải xong vẫn phải bấm Cài đặt tay như trước. Chỉ có tác dụng
    /// trên iOS (macOS cài qua DeviceCTL, không qua đường này).
    private var _autoInstallAfterDownload = Persist<Bool>(
        key: "AutoInstallAfterDownload",
        defaultValue: false,
    )

    var autoInstallAfterDownload: Bool {
        get {
            return _autoInstallAfterDownload.wrappedValue
        }
        set {
            objectWillChange.send()
            _autoInstallAfterDownload.wrappedValue = newValue
        }
    }

    /// Vùng App Store ưa thích để tìm kiếm (đợt 2, build 7 — ý tưởng
    /// iPadn mục 4): danh sách mã vùng ISO-2 theo thứ tự người dùng sắp
    /// xếp, lưu bằng Persist. Vùng tìm kiếm chỉ dùng để tìm app / tra
    /// cứu catalog, độc lập với vùng của tài khoản. Vùng đang tìm thì
    /// lưu ở AppStorage "searchRegion" (dùng chung với SearchView).
    private var _searchFavoriteRegions = Persist<[String]>(
        key: "SearchFavoriteRegions",
        defaultValue: StoreRegionCatalog.defaultFavorites,
    )

    var searchFavoriteRegions: [String] {
        get {
            return _searchFavoriteRegions.wrappedValue.filter { StoreRegionCatalog.region(for: $0) != nil }
        }
        set {
            objectWillChange.send()
            _searchFavoriteRegions.wrappedValue = newValue.filter { StoreRegionCatalog.region(for: $0) != nil }
        }
    }

    /// Thêm/bỏ một vùng khỏi danh sách ưa thích (giữ nguyên thứ tự còn
    /// lại; vùng mới thêm vào cuối).
    func toggleSearchFavoriteRegion(_ code: String) {
        var favorites = searchFavoriteRegions
        if let index = favorites.firstIndex(of: code) {
            favorites.remove(at: index)
        } else {
            favorites.append(code)
        }
        searchFavoriteRegions = favorites
    }

    /// Đưa danh sách ưa thích về mặc định (VN + các cửa hàng lớn).
    func resetSearchFavoriteRegions() {
        searchFavoriteRegions = StoreRegionCatalog.defaultFavorites
    }

    static let this = AppStore()

    static func normalizedDeviceIdentifier(_ value: String) -> String? {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        guard identifier.utf8.count == 12,
              identifier.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) }),
              !["020000000000", "000000000000", "FFFFFFFFFFFF"].contains(identifier)
        else { return nil }
        return identifier
    }

    private init() {
        // Preserve identifiers used by existing accounts until the user edits them.
        if deviceIdentifier.isEmpty || (accounts.isEmpty && Self.normalizedDeviceIdentifier(deviceIdentifier) == nil) {
            if let systemIdentifier = (try? ApplePackage.DeviceIdentifier.system()).flatMap(Self.normalizedDeviceIdentifier) {
                deviceIdentifier = systemIdentifier
                logger.info("obtained system device identifier")
            } else {
                logger.info("using a generated device identifier")
                var randomIdentifier = ApplePackage.DeviceIdentifier.random()
                while Self.normalizedDeviceIdentifier(randomIdentifier) == nil {
                    randomIdentifier = ApplePackage.DeviceIdentifier.random()
                }
                deviceIdentifier = randomIdentifier
            }
        }
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
    }

    @discardableResult
    func save(email: String, account: ApplePackage.Account) throws -> UserAccount {
        logger.info("saving account for user")
        let account = UserAccount(account: account)
        let updatedAccounts = (accounts.filter { $0.account.email != email } + [account])
            .sorted { $0.account.email < $1.account.email }
        do {
            try _accounts.setAndSave(updatedAccounts)
            objectWillChange.send()
        } catch {
            throw AccountStorageError()
        }
        return account
    }

    private struct AccountStorageError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Unable to save the account to Keychain. Check the app's code signing and Keychain access, then try again.")
        }
    }

    func delete(id: UserAccount.ID) {
        logger.info("deleting account id: \(id)")
        accounts = accounts.filter { $0.id != id }
    }

    var possibleRegions: Set<String> {
        Set(accounts.compactMap { ApplePackage.Configuration.countryCode(for: $0.account.store) })
    }

    func eligibleAccounts(for region: String) -> [UserAccount] {
        accounts.filter { ApplePackage.Configuration.countryCode(for: $0.account.store) == region }
    }

    nonisolated func withAccount<T>(id: String, _ body: (inout UserAccount) async throws -> T) async throws -> T {
        guard var account = await accounts.first(where: { $0.id == id }) else {
            throw AuthenticationError.accountNotFound
        }
        let result = try await body(&account)
        let updatedAccount = account
        // Re-resolve by id: the accounts array may have been mutated (added,
        // removed, re-sorted) during the await, so the original index is stale.
        await MainActor.run {
            if let idx = accounts.firstIndex(where: { $0.id == id }) {
                accounts[idx] = updatedAccount
            }
        }
        return result
    }
}
