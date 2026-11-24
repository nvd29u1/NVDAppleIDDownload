//
//  ProductView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import Kingfisher
import SwiftUI

struct ProductView: View {
    @State private var archive: AppPackageArchive
    @Binding var navigationPath: NavigationPath

    var region: String {
        archive.region
    }

    init(archive: AppStore.AppPackage, region: String, navigationPath: Binding<NavigationPath>) {
        _archive = State(initialValue: AppPackageArchive(accountID: nil, region: region, package: archive))
        _navigationPath = navigationPath
    }

    @State private var vm = AppStore.this
    @State private var dvm = Downloads.this

    var eligibleAccounts: [AppStore.UserAccount] {
        vm.eligibleAccounts(for: region)
    }

    /// Mọi tài khoản đã đăng nhập, tài khoản đúng vùng đứng trước, tài
    /// khoản khác vùng đứng sau (vẫn chọn được, có ghi chú vùng) — không
    /// ẩn hẳn như trước. Trước build 5, picker chỉ liệt kê tài khoản đúng
    /// vùng nên với gói vùng VN + chỉ tài khoản vùng IN đăng nhập, picker
    /// rỗng và nút "Yêu cầu tải" / "Nhập vào Đã mua" chết hẳn.
    var pickerAccounts: [AppStore.UserAccount] {
        let eligible = eligibleAccounts
        let others = vm.accounts.filter { account in
            !eligible.contains(where: { $0.id == account.id })
        }
        return eligible + others
    }

    /// Vùng (mã quốc gia, vd "IN", "VN") của tài khoản đang chọn.
    var selectedAccountRegion: String? {
        guard let account else { return nil }
        return ApplePackage.Configuration.countryCode(for: account.account.store)
    }

    /// Tài khoản đang chọn khác vùng với gói đang xem.
    var isRegionMismatch: Bool {
        guard let code = selectedAccountRegion else { return false }
        return code != region
    }

    /// Chọn tài khoản: giữ lựa chọn hiện tại nếu vẫn còn trong danh sách;
    /// nếu không, ưu tiên tài khoản đúng vùng, nếu không có thì fallback
    /// sang tài khoản đã đăng nhập đầu tiên (dù khác vùng) thay vì để
    /// picker rỗng.
    private func selectFallbackAccount() {
        if pickerAccounts.contains(where: { $0.id == selection }) { return }
        selection = pickerAccounts.first?.id ?? .init()
    }

    /// Nhãn trong picker: email + mã vùng, tài khoản khác vùng ghi rõ
    /// "khác vùng" để người dùng biết trước là có thể tải không được.
    private func pickerLabel(for account: AppStore.UserAccount) -> String {
        let code = ApplePackage.Configuration.countryCode(for: account.account.store) ?? "?"
        if code == region {
            return "\(account.account.email) (\(code))"
        }
        return "\(account.account.email) (\(code)) — \(String(localized: "khác vùng"))"
    }

    /// Cảnh báo khi tài khoản đang chọn khác vùng với gói đang xem.
    private func regionMismatchWarning(for accountRegion: String) -> String {
        String(
            format: String(localized: "Tài khoản này vùng %@, gói đang xem vùng %@ — có thể tải không được, hãy thêm tài khoản vùng %@ hoặc đổi vùng tìm kiếm."),
            accountRegion, region, region
        )
    }

    var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == selection }
    }

    @State private var selection: AppStore.UserAccount.ID = .init()
    @State private var licenseHint: Hint?
    @State private var showLicenseAlert = false
    @State private var hint: Hint?

    let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    var formattedSize: String? {
        guard let sizeBytes = archive.package.software.fileSizeBytes.flatMap(Int64.init(_:)) else {
            return nil
        }
        return sizeFormatter.string(fromByteCount: sizeBytes)
    }

    var body: some View {
        Form {
            accountSelector
            if let accountRegion = selectedAccountRegion, isRegionMismatch {
                Section {
                    Text(regionMismatchWarning(for: accountRegion))
                        .foregroundStyle(.orange)
                } header: {
                    Text("Cảnh báo vùng")
                }
            }
            buttons
            packageHeader
            packageDetails
            packageDescription
            if vm.accounts.isEmpty {
                Section {
                    Text("Không có tài khoản nào đăng nhập.")
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                } footer: {
                    Text("Hãy thêm tài khoản trong trang Tài khoản.")
                }
            }
            pricing
        }
        .formStyle(.grouped)
        .onAppear {
            selectFallbackAccount()
        }
        .onChange(of: vm.accounts) { _, _ in
            // Sau khi đăng xuất / đăng nhập lại (kể cả bằng Apple ID khác),
            // id tài khoản đã chọn có thể không còn tồn tại — chọn lại tài
            // khoản đầu tiên còn đăng nhập (ưu tiên đúng vùng, fallback
            // sang tài khoản khác vùng) thay vì giữ id cũ rồi báo lỗi xác
            // thực khi mở Lịch sử phiên bản hay tải bản cũ.
            selectFallbackAccount()
        }
        .navigationDestination(for: PackageManifest.self) { manifest in
            PackageView(pkg: manifest)
        }
        .navigationTitle("Select Account")
        .alert("License Required", isPresented: $showLicenseAlert) {
            var confirmRole: ButtonRole?
            #if compiler(>=6.2)
                if #available(iOS 26.0, macOS 26.0, *) {
                    confirmRole = .confirm
                }
            #endif

            return Group {
                Button("Acquire License", role: confirmRole) {
                    Task {
                        do {
                            try await acquireLicense()
                        } catch {
                            licenseHint = Hint(message: error.localizedDescription, color: .red)
                        }
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
        } message: {}
    }

    /// Rotates the password token and requests a license for the current
    /// account. Sets `licenseHint` to a success message; callers handle errors.
    private func acquireLicense() async throws {
        guard let account else { return }
        try await vm.withAccount(id: account.id) { userAccount in
            try await ApplePackage.Authenticator.rotatePasswordToken(for: &userAccount.account)
            try await ApplePackage.Purchase.purchase(
                account: &userAccount.account,
                app: archive.package.software,
            )
        }
        licenseHint = Hint(message: String(localized: "Đã nhập vào mục Đã mua. App sẽ hiện trong danh sách Đã mua của Apple ID này, chưa tải file IPA về máy."), color: .green)
        hint = licenseHint
    }

    var packageHeader: some View {
        Section {
            PackageDisplayView(archive: archive.package)
            NavigationLink {
                // Build the archive lazily: constructing it eagerly here runs
                // two synchronous file reads + a JSON decode on every body
                // evaluation, even before the user navigates.
                LazyView(ProductHistoryView(vm: AppPackageArchive(accountID: selection, region: region, package: archive.package)))
            } label: {
                let badgeText = archive.releaseDate.flatMap { date in
                    Text(date.formatted(.relative(presentation: .numeric)))
                }

                Text("Version \(archive.package.software.version)")
                    .badge(badgeText)
            }
        } header: {
            Text("Package")
        }
    }

    var packageDetails: some View {
        Section {
            CopyableRow(label: "Bundle ID", value: archive.package.software.bundleID, monospaced: true)
            Text("Developer")
                .badge(archive.package.software.sellerName)
            if !archive.package.software.primaryGenreName.isEmpty {
                Text("Category")
                    .badge(archive.package.software.primaryGenreName)
            }
            if let formattedSize {
                Text("Size")
                    .badge(formattedSize)
            }
            Text("Compatibility")
                .badge("\(archive.package.software.minimumOsVersion)+")
            if archive.package.software.userRatingCount > 0 {
                Text("Rating")
                    .badge("\(String(format: "%.1f", archive.package.software.averageUserRating)) (\(archive.package.software.userRatingCount))")
            }
        } header: {
            Text("Details")
        }
    }

    var packageDescription: some View {
        Section {
            Text(archive.package.software.releaseNotes ?? "")
        } header: {
            Text("What's New")
        }
    }

    var pricing: some View {
        Section {
            Text("\(archive.formattedPrice ?? "N/A")")
            if archive.price == 0 {
                AsyncButton {
                    try await acquireLicense()
                } label: {
                    Text("Acquire License")
                }
                .disabledWhenLoading()
                .disabled(account == nil)
            }
        } header: {
            Text("Pricing")
        } footer: {
            if let licenseHint {
                Text(licenseHint.message)
                    .foregroundStyle(licenseHint.color ?? .primary)
            } else {
                Text("Acquiring a license is not available for paid apps. Purchase from the App Store first, then download here. If you've already purchased it, this may fail.")
            }
        }
    }

    var accountSelector: some View {
        Section {
            Picker("Account", selection: $selection) {
                ForEach(pickerAccounts) { account in
                    Text(pickerLabel(for: account))
                        .id(account.id)
                }
            }
            .pickerStyle(.menu)
            .redacted(reason: .placeholder, isEnabled: vm.demoMode)
        } header: {
            Text("Account")
        } footer: {
            Text("You have searched this package with region \(region)")
        }
    }

    var buttons: some View {
        Section {
            if let req = dvm.downloadRequest(forArchive: archive.package) {
                NavigationLink(value: req) {
                    Text("Show Download")
                }
            } else {
                AsyncButton {
                    guard let account else { return }
                    do {
                        try await dvm.startDownload(for: archive.package, accountID: account.id)
                        hint = Hint(message: String(localized: "Download Requested"), color: nil)
                        if let req = dvm.downloadRequest(forArchive: archive.package) {
                            navigationPath.append(req)
                        }
                    } catch {
                        if case ApplePackageError.licenseRequired = error, archive.package.software.price == 0 {
                            showLicenseAlert = true
                        } else {
                            hint = Hint(message: String(localized: "Unable to retrieve download URL. Please try again later.") + "\n" + error.localizedDescription, color: .red)
                        }
                        throw error
                    }
                } label: {
                    Text("Request Download")
                }
                .disabledWhenLoading()
                .disabled(account == nil)
                .nvdBorderBeam(shape: .rounded(10))

                // Nhập app miễn phí vào mục Đã mua mà không tải về: chỉ gọi
                // purchase để lấy license (ApplePackage.Purchase.purchase,
                // giống lệnh purchase của ipatool), không tải file IPA.
                // App trả phí không dùng được nút này — ApplePackage từ chối.
                if archive.price == 0 {
                    AsyncButton {
                        do {
                            try await acquireLicense()
                        } catch {
                            hint = Hint(message: String(localized: "Không nhập được vào mục Đã mua.") + "\n" + error.localizedDescription, color: .red)
                            throw error
                        }
                    } label: {
                        Text("Nhập vào Đã mua")
                    }
                    .disabledWhenLoading()
                    .disabled(account == nil)
                    .nvdBorderBeam(shape: .rounded(10))
                    Text("Chỉ mua license app miễn phí để app vào danh sách Đã mua, không tải file IPA về máy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Download")
        } footer: {
            if let hint {
                Text(hint.message)
                    .foregroundStyle(hint.color ?? .primary)
            } else {
                Text("Package can be installed later in download page.")
            }
        }
    }
}

extension AppStore.AppPackage {
    var displaySupportedDevicesIcon: String {
        // TODO: assuming iPhone for now
        "iphone"
    }
}

/// Defers building its content until the view is actually rendered, so an
/// expensive destination is not constructed eagerly inside a NavigationLink.
struct LazyView<Content: View>: View {
    private let build: () -> Content

    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }

    var body: Content {
        build()
    }
}
