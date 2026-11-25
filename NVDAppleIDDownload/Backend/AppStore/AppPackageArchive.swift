//
//  AppPackageArchive.swift
//  NVDAppleIDDownload
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import Foundation
import OrderedCollections

@MainActor
class AppPackageArchive: ObservableObject {
    let accountIdentifier: String?
    let region: String

    @Published var package: AppStore.AppPackage

    typealias VersionIdentifier = String
    private var _versionIdentifiers: Persist<[VersionIdentifier]>

    var versionIdentifiers: [VersionIdentifier] {
        get {
            return _versionIdentifiers.wrappedValue
        }
        set {
            objectWillChange.send()
            _versionIdentifiers.wrappedValue = newValue
        }
    }

    private var _versionItems: Persist<OrderedDictionary<VersionIdentifier, VersionMetadata>>

    var versionItems: OrderedDictionary<VersionIdentifier, VersionMetadata> {
        get {
            return _versionItems.wrappedValue
        }
        set {
            objectWillChange.send()
            _versionItems.wrappedValue = newValue
        }
    }

    /// Dung lượng IPA + ghi chú cập nhật theo từng version ID (đợt 3,
    /// build 8 — ý tưởng iPadn mục 6). Lưu riêng với VersionMetadata
    /// của ApplePackage (chỉ có số version + ngày) để không đụng tới
    /// thư viện ngoài.
    private var _versionExtras: Persist<[VersionIdentifier: VersionExtra]>

    var versionExtras: [VersionIdentifier: VersionExtra] {
        get {
            return _versionExtras.wrappedValue
        }
        set {
            objectWillChange.send()
            _versionExtras.wrappedValue = newValue
        }
    }

    func extra(for versionID: VersionIdentifier) -> VersionExtra? {
        versionExtras[versionID]
    }

    var isVersionItemsFullyLoaded: Bool {
        assert(versionItems.count <= versionIdentifiers.count)
        return versionItems.count == versionIdentifiers.count
    }

    @Published var error: String?
    @Published var loading = false
    @Published var shouldDismiss = false

    init(accountID: String?, region: String, package: AppStore.AppPackage) {
        accountIdentifier = accountID
        self.region = region
        self.package = package

        let packageIdentifier = [package.id, package.software.bundleID.lowercased(), region, (package.entityType ?? .iPhone).rawValue]
            .joined()
            .lowercased()
        _versionItems = Persist(key: "\(packageIdentifier).versions", defaultValue: [:])
        _versionIdentifiers = Persist(key: "\(packageIdentifier).versionNumbers", defaultValue: [])
        _versionExtras = Persist(key: "\(packageIdentifier).versionExtras", defaultValue: [:])
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        if let metadata = versionItems[externalVersion] {
            var pkg = package
            pkg.software.version = metadata.displayVersion
            pkg.externalVersionID = externalVersion
            return pkg
        } else {
            return nil
        }
    }

    func clearVersionItems() {
        assert(!loading)
        error = nil
        versionIdentifiers = []
        versionItems = [:]
        versionExtras = [:]
    }

    /// Tài khoản đang đăng nhập dùng cho region này. Ưu tiên id tài khoản
    /// đã chọn ở màn chi tiết app; nếu tài khoản đó không còn trong app
    /// (đăng xuất rồi đăng nhập lại bằng Apple ID khác, hoặc tài khoản đã
    /// bị xoá) thì dùng tài khoản đầu tiên còn đăng nhập cho region — thay
    /// vì ném lỗi "không tìm thấy tài khoản" ngay khi mở Lịch sử phiên bản.
    /// Nếu không có tài khoản nào đúng vùng (vd gói vùng VN mà chỉ có tài
    /// khoản vùng IN), fallback sang tài khoản đã đăng nhập đầu tiên dù
    /// khác vùng, giống picker ở màn chi tiết app (build 5) — để Lịch sử
    /// phiên bản vẫn mở được thay vì báo lỗi ngay.
    /// Dùng chung phiên đã đăng nhập (cookie + passwordToken đã lưu), không
    /// tạo session/authenticator mới.
    func resolvedAccountID() -> String? {
        let accounts = AppStore.this.accounts
        if let accountIdentifier, accounts.contains(where: { $0.id == accountIdentifier }) {
            return accountIdentifier
        }
        return AppStore.this.eligibleAccounts(for: region).first?.id
            ?? accounts.first?.id
    }

    func populateVersionIdentifiers(_ completion: (() async -> Void)? = nil) {
        guard !loading else { return }
        guard let accountID = resolvedAccountID() else {
            error = AppStore.AuthenticationError.accountNotFound.localizedDescription
            return
        }
        let requestedPackage = package
        loading = true
        error = nil

        Task {
            do {
                let versions = try await AppStore.this.withAccount(id: accountID) { userAccount in
                    try await StoreDownloadService.versions(account: &userAccount.account, package: requestedPackage, region: region)
                }
                self.versionIdentifiers = versions.reversed()
            } catch {
                if case .licenseRequired = error as? ApplePackageError {
                    self.shouldDismiss = true
                }
                self.error = error.localizedDescription
            }
            self.loading = false
            await completion?()
        }
    }

    func populateNextVersionItems(count: Int = 3) {
        guard !loading, !isVersionItemsFullyLoaded else { return }
        guard let accountID = resolvedAccountID() else {
            error = AppStore.AuthenticationError.accountNotFound.localizedDescription
            return
        }
        loading = true
        error = nil

        Task {
            do {
                for _ in 0 ..< count where !self.isVersionItemsFullyLoaded {
                    let nextIdx = self.versionItems.count
                    let version = self.versionIdentifiers[nextIdx]
                    let requestedPackage = self.package

                    let metadata = try await AppStore.this.withAccount(id: accountID) { userAccount in
                        try await StoreDownloadService.versionMetadata(account: &userAccount.account, package: requestedPackage, versionID: version, region: region)
                    }
                    self.versionItems[version] = metadata.metadata
                    self.versionExtras[version] = metadata.extra
                    // Phiên bản mới nhất (dòng đầu tiên) mà metadata tải
                    // không có dung lượng/ghi chú thì tra thêm qua Lookup.
                    if nextIdx == 0 {
                        await self.enrichLatestExtraIfNeeded(versionID: version, displayVersion: metadata.metadata.displayVersion)
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.loading = false
        }
    }

    func populateVersionItem(for versionID: String) {
        guard !loading, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else { return }
        guard let accountID = resolvedAccountID() else {
            error = AppStore.AuthenticationError.accountNotFound.localizedDescription
            return
        }
        loading = true
        error = nil

        Task {
            do {
                let requestedPackage = self.package
                let result = try await AppStore.this.withAccount(id: accountID) { userAccount in
                    try await StoreDownloadService.versionMetadata(account: &userAccount.account, package: requestedPackage, versionID: versionID, region: region)
                }
                self.versionItems[versionID] = result.metadata
                self.versionExtras[versionID] = result.extra
                await self.enrichLatestExtraIfNeeded(versionID: versionID, displayVersion: result.metadata.displayVersion)
            } catch {
                self.error = error.localizedDescription
            }
            self.loading = false
        }
    }
    /// Phiên bản mới nhất: nếu metadata tải không có dung lượng/ghi chú
    /// thì tra thêm qua iTunes Lookup công khai (chỉ bản hiện tại mới
    /// có trong Lookup — Lookup không trả được bản cũ). Chỉ tra khi
    /// versionID là dòng đầu tiên (mới nhất) và extra còn trống; lỗi
    /// thì thôi, giữ extra cũ, UI hiện "—".
    private func enrichLatestExtraIfNeeded(versionID: String, displayVersion: String) async {
        guard versionID == versionIdentifiers.first,
              versionExtras[versionID]?.isEmpty != false
        else { return }
        guard let software = try? await ApplePackage.Lookup.lookup(
            bundleID: package.software.bundleID,
            countryCode: region,
        ), software.version == displayVersion
        else { return }
        var extra = versionExtras[versionID] ?? VersionExtra()
        if extra.fileSizeBytes == nil,
           let sizeText = software.fileSizeBytes, let size = Int64(sizeText)
        {
            extra.fileSizeBytes = size
        }
        if extra.releaseNotes == nil,
           let notes = software.releaseNotes, !notes.isEmpty
        {
            extra.releaseNotes = notes
        }
        if !extra.isEmpty {
            versionExtras[versionID] = extra
        }
    }
}

extension AppPackageArchive {
    var version: String {
        package.software.version
    }

    var releaseDate: Date? {
        package.releaseDate
    }

    var releaseNotes: String? {
        package.software.releaseNotes
    }

    var formattedPrice: String? {
        package.software.formattedPrice
    }

    var price: Double? {
        package.software.price
    }

    var downloadOutput: DownloadOutput? {
        get { package.downloadOutput }
        set { package.downloadOutput = newValue }
    }
}
