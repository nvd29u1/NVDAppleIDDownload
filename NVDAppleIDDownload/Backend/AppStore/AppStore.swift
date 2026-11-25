//
//  AppStore.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation

@Observable
@MainActor
class AppStore {
    @ObservationIgnored
    private var _accounts = Persist<[UserAccount]>(
        key: "Accounts",
        defaultValue: [],
        engine: KeychainStorage(service: "com.NVD.appleiddownload.Accounts"),
    )

    var accounts: [UserAccount] {
        get {
            access(keyPath: \.accounts)
            return _accounts.wrappedValue
        }
        set {
            withMutation(keyPath: \.accounts) {
                _accounts.wrappedValue = newValue
            }
        }
    }

    @ObservationIgnored
    private var _deviceIdentifier = Persist<String>(
        key: "DeviceIdentifier",
        defaultValue: "",
        engine: KeychainStorage(service: "com.NVD.appleiddownload.DeviceIdentifier"),
    )

    var deviceIdentifier: String {
        get {
            access(keyPath: \.deviceIdentifier)
            return _deviceIdentifier.wrappedValue
        }
        set {
            withMutation(keyPath: \.deviceIdentifier) {
                _deviceIdentifier.wrappedValue = newValue
            }
            ApplePackage.Configuration.deviceIdentifier = newValue
        }
    }

    @ObservationIgnored
    private var _demoMode = Persist<Bool>(key: "DemoMode", defaultValue: false)

    var demoMode: Bool {
        get {
            access(keyPath: \.demoMode)
            return _demoMode.wrappedValue
        }
        set {
            withMutation(keyPath: \.demoMode) {
                _demoMode.wrappedValue = newValue
            }
        }
    }

    /// Default manifest server (NVD Cloudflare worker) used to install
    /// downloaded apps directly. Only builds the manifest plist — the IPA
    /// itself never leaves the phone. Empty string = built-in local server.
    static let defaultManifestServerURL = "https://nvd-manifest.nguyenvietdung156195.workers.dev"

    @ObservationIgnored
    private var _manifestServerURL = Persist<String>(
        key: "ManifestServerURL",
        defaultValue: defaultManifestServerURL,
    )

    var manifestServerURL: String {
        get {
            access(keyPath: \.manifestServerURL)
            return _manifestServerURL.wrappedValue
        }
        set {
            withMutation(keyPath: \.manifestServerURL) {
                _manifestServerURL.wrappedValue = newValue
            }
        }
    }

    /// URL of the user's own Anisette server (e.g. http://192.168.1.10:6969)
    /// that serves device-verification (Anisette/ADI) headers as JSON.
    /// Empty = off: sign-in works exactly as before. When set, the app
    /// fetches the headers from this server before signing in and attaches
    /// them to the Apple sign-in requests. Only the server URL is stored
    /// here — no Apple ID or password is ever sent to this server.
    @ObservationIgnored
    private var _anisetteServerURL = Persist<String>(
        key: "AnisetteServerURL",
        defaultValue: "",
    )

    var anisetteServerURL: String {
        get {
            access(keyPath: \.anisetteServerURL)
            return _anisetteServerURL.wrappedValue
        }
        set {
            withMutation(keyPath: \.anisetteServerURL) {
                _anisetteServerURL.wrappedValue = newValue
            }
        }
    }

    /// Vùng App Store ưa thích để tìm kiếm (đợt 2, build 7 — ý tưởng
    /// iPadn mục 4): danh sách mã vùng ISO-2 theo thứ tự người dùng sắp
    /// xếp, lưu bằng Persist. Vùng tìm kiếm chỉ dùng để tìm app / tra
    /// cứu catalog, độc lập với vùng của tài khoản. Vùng đang tìm thì
    /// lưu ở AppStorage "searchRegion" (dùng chung với SearchView).
    @ObservationIgnored
    private var _searchFavoriteRegions = Persist<[String]>(
        key: "SearchFavoriteRegions",
        defaultValue: StoreRegionCatalog.defaultFavorites,
    )

    var searchFavoriteRegions: [String] {
        get {
            access(keyPath: \.searchFavoriteRegions)
            return _searchFavoriteRegions.wrappedValue.filter { StoreRegionCatalog.region(for: $0) != nil }
        }
        set {
            withMutation(keyPath: \.searchFavoriteRegions) {
                _searchFavoriteRegions.wrappedValue = newValue.filter { StoreRegionCatalog.region(for: $0) != nil }
            }
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
            try withMutation(keyPath: \.accounts) {
                try _accounts.setAndSave(updatedAccounts)
            }
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
