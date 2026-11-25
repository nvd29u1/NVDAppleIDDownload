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
    @ObservedObject private var archive: AppPackageArchive
    @Binding var navigationPath: NavigationPath

    var region: String {
        archive.region
    }

    init(archive: AppStore.AppPackage, region: String, navigationPath: Binding<NavigationPath>) {
        _archive = State(initialValue: AppPackageArchive(accountID: nil, region: region, package: archive))
        _navigationPath = navigationPath
    }

    @StateObject private var vm = AppStore.this
    @StateObject private var dvm = Downloads.this
    @StateObject private var followStore = FollowStore.shared

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

    /// Ghi chú dưới nút "Nhập vào Đã mua" khi lệch vùng: Apple chỉ cho
    /// nhập app vào Đã mua ở đúng vùng của tài khoản — nút vẫn bấm được
    /// (app có ở cả hai vùng thì vẫn nhập được bằng vùng của tài khoản),
    /// nhưng nếu Apple báo app không có trong cửa hàng thì phải thêm tài
    /// khoản đúng vùng. Đã kiểm tra ApplePackage (fork nvd29u1, pin
    /// 541c43a): `Purchase.purchase(account:app:anisetteHeaders:)` KHÔNG có tham số vùng
    /// — header `X-Apple-Store-Front` lấy từ `account.store` (vùng đăng ký
    /// của tài khoản, do Apple trả về lúc đăng nhập), không có cách nào
    /// mua license theo vùng của gói bằng 1 tài khoản; đổi `store` của
    /// tài khoản đã lưu cũng không được vì `withAccount` sẽ ghi đè lại
    /// tài khoản đã lưu. Đây là giới hạn phía Apple, không phải lỗi app.
    private func crossRegionPurchaseNote(for accountRegion: String) -> String {
        String(
            format: String(localized: "Tài khoản đang chọn vùng %@, app này vùng %@. Apple chỉ cho nhập vào Đã mua ở đúng vùng của tài khoản — nếu Apple báo lỗi, hãy thêm tài khoản vùng %@ ở tab Tài khoản rồi chọn lại."),
            accountRegion, region, region
        )
    }

    /// Lỗi khi Apple từ chối nhập vào Đã mua vì app không có trong cửa
    /// hàng vùng của tài khoản: ApplePackage trả failureType 2059 ("app is
    /// unavailable ... in this storefront"), 1010 ("invalid store or app
    /// unavailable in this storefront") hoặc -128 (CountryMismatch) — dịch
    /// sang tiếng Việt kèm hướng dẫn thêm tài khoản đúng vùng. `code` giữ
    /// lại mã gốc để màn hình biết đây là lỗi vùng và mở popup chẩn đoán
    /// (thay vì chỉ hiện chữ lỗi).
    private struct RegionPurchaseRefusal: LocalizedError {
        let code: String
        let accountRegion: String
        let packageRegion: String
        var errorDescription: String? {
            String(
                format: String(localized: "Apple từ chối: app này không có trong cửa hàng vùng %@ của tài khoản. Hãy thêm tài khoản vùng %@ ở tab Tài khoản rồi chọn tài khoản đó để nhập vào Đã mua."),
                accountRegion, packageRegion
            )
        }
    }

    /// Lỗi khi Apple từ chối yêu cầu nhập vào Đã mua trước khi xét tài
    /// khoản — cùng họ lỗi cửa Apple như lúc đăng nhập (trả về trống 204
    /// / chuyển hướng không có địa chỉ), không phải lỗi sai tài khoản.
    /// Hai case *NoServer (build 15): cùng lỗi cửa đó nhưng máy chưa
    /// cấu hình máy chủ Anisette nên app không gửi được bằng chứng xác
    /// minh thiết bị — nói rõ để người dùng biết phải cấu hình máy chủ
    /// chứ không phải tài khoản sai.
    private enum PurchaseGateError: LocalizedError {
        case appleEmptyResponse
        case appleRedirectRefused
        case appleEmptyResponseNoServer
        case appleRedirectRefusedNoServer
        /// Token hết hạn thật (Apple trả failureType 2034 — build 16:
        /// rotate lặng lẽ thất bại rồi buyProduct báo token hết hạn).
        case passwordTokenExpired

        var errorDescription: String? {
            switch self {
            case .appleEmptyResponse:
                return String(localized: "Apple đã từ chối yêu cầu nhập vào Đã mua (máy chủ trả về trống — HTTP 204). Đây không phải lỗi sai tài khoản: hãy thử lại sau hoặc trên mạng khác, kiểm tra máy chủ Anisette trong Cài đặt, hoặc dùng ipatool 2.8.1 trên máy tính.")
            case .appleRedirectRefused:
                return String(localized: "Apple đã từ chối yêu cầu nhập vào Đã mua (máy chủ trả về chuyển hướng nhưng không có địa chỉ chuyển tiếp). Đây không phải lỗi sai tài khoản: hãy thử lại sau hoặc trên mạng khác, kiểm tra máy chủ Anisette trong Cài đặt, hoặc dùng ipatool 2.8.1 trên máy tính.")
            case .appleEmptyResponseNoServer:
                return String(localized: "Apple đã từ chối yêu cầu nhập vào Đã mua (máy chủ trả về trống — HTTP 204). Máy chưa cấu hình máy chủ Anisette (Cài đặt → Máy chủ Anisette) nên app không gửi được bằng chứng xác minh thiết bị mà Apple đòi — hãy cấu hình máy chủ rồi thử lại, hoặc dùng ipatool 2.8.1 trên máy tính.")
            case .appleRedirectRefusedNoServer:
                return String(localized: "Apple đã từ chối yêu cầu nhập vào Đã mua (máy chủ trả về chuyển hướng nhưng không có địa chỉ chuyển tiếp). Máy chưa cấu hình máy chủ Anisette (Cài đặt → Máy chủ Anisette) nên app không gửi được bằng chứng xác minh thiết bị mà Apple đòi — hãy cấu hình máy chủ rồi thử lại, hoặc dùng ipatool 2.8.1 trên máy tính.")
            case .passwordTokenExpired:
                return String(localized: "Phiên đăng nhập của tài khoản này đã hết hạn (mã 2034) — app đã thử làm mới lặng lẽ nhưng Apple không chấp nhận. Hãy đăng nhập lại tài khoản ở tab Tài khoản rồi bấm \"Nhập vào Đã mua\" lại.")
            }
        }
    }

    /// Thao tác vừa thất bại vì lệch vùng — để popup biết bấm "thử lại"
    /// thì chạy lại thao tác nào.
    private enum RegionFailedOperation {
        case download
        case purchase
    }

    /// Chẩn đoán lệch vùng sau một lỗi thật (ý tưởng iPadn v2.3.1): không
    /// chặn trước khi tải/mua, chỉ khi Apple đã trả 2059/1010/-128 mới
    /// hiện popup nêu đúng vùng tài khoản / vùng gói + nút đổi tài khoản
    /// rồi thử lại.
    private struct RegionDiagnosis: Identifiable {
        let id = UUID()
        let code: String
        let accountRegion: String
        let packageRegion: String
        let operation: RegionFailedOperation
    }

    /// Mã lỗi vùng trong một lỗi bất kỳ: failureType 2059/1010/-128 từ
    /// ApplePackage (mua license), hoặc `StoreDownloadError.rejected`
    /// cùng mã (tải / lịch sử phiên bản). Trả nil nếu không phải lỗi vùng.
    private static func regionFailureCode(in error: Error) -> String? {
        if let refusal = error as? RegionPurchaseRefusal { return refusal.code }
        if let downloadError = error as? StoreDownloadError,
           case let .rejected(code, _) = downloadError,
           ["2059", "1010", "-128"].contains(code) {
            return code
        }
        let description = error.localizedDescription
        if description.contains("failureType: 2059") || description.contains("code: 2059") { return "2059" }
        if description.contains("failureType: 1010") || description.contains("code: 1010") { return "1010" }
        if description.contains("failureType: -128") || description.contains("code: -128") { return "-128" }
        // Thông điệp của fork cho 2059/1010 không phải lúc nào cũng kèm
        // failureType (vd. "app is unavailable ... in this storefront").
        if description.contains("unavailable in this storefront") { return "2059" }
        if description.contains("invalid store") { return "1010" }
        return nil
    }

    /// Lỗi tạm thời của Apple khi mua license: máy chủ trả về trống hoặc
    /// lỗi HTTP 204/403/404/5xx, redirect không có địa chỉ — cùng họ lỗi
    /// với đăng nhập, đáng thử lại. Lỗi phán quyết thật (lệch vùng
    /// 2059/1010/-128, app trả phí, bắt chấp nhận điều khoản, token hết
    /// hạn) thì không thử lại. Build 15: thêm 301/302/303/307/308 —
    /// buyProduct dùng redirectConfiguration .disallow nên Apple chuyển
    /// hướng (vd sang pod của vùng khác) sẽ trả về đúng mã 3xx thay vì
    /// theo chuyển hướng; trước đây mã này rơi ra ngoài danh sách nên
    /// không retry và không dịch ra tiếng Việt.
    private static func isTransientPurchaseError(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return ["request failed with status 204", "request failed with status 301", "request failed with status 302", "request failed with status 303", "request failed with status 307", "request failed with status 308", "request failed with status 403", "request failed with status 404",
                "request failed with status 500", "request failed with status 502", "request failed with status 503", "request failed with status 504",
                "HTTP 204", "HTTP 403", "HTTP 404", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504",
                "failed to retrieve redirect location", "redirect limit exceeded",
                "response body is empty"].contains { message.contains($0) }
    }

    /// Dịch lỗi cửa Apple khi mua license sang tiếng Việt rõ ràng (như
    /// AuthenticationService làm cho đăng nhập). Lỗi khác giữ nguyên.
    /// `anisetteConfigured` (build 15): đã cấu hình máy chủ Anisette
    /// trong Cài đặt hay chưa — chưa cấu hình mà gặp lỗi cửa thì nói
    /// rõ nguyên nhân có thể là thiếu header xác minh thiết bị.
    private static func translatePurchaseGateError(_ error: Error, anisetteConfigured: Bool) -> Error {
        let message = error.localizedDescription
        if message.contains("failed to retrieve redirect location") || message.contains("redirect limit exceeded")
            || message.contains("request failed with status 301") || message.contains("request failed with status 302")
            || message.contains("request failed with status 303") || message.contains("request failed with status 307")
            || message.contains("request failed with status 308")
        {
            return anisetteConfigured ? PurchaseGateError.appleRedirectRefused : PurchaseGateError.appleRedirectRefusedNoServer
        }
        if message.contains("request failed with status 204") || message.contains("HTTP 204") {
            return anisetteConfigured ? PurchaseGateError.appleEmptyResponse : PurchaseGateError.appleEmptyResponseNoServer
        }
        // Token hết hạn thật (fork: failureType 2034 → "password token is
        // expired (failureType: 2034)"): phiên đã chết, đăng nhập lại mới
        // xong — đừng để nguyên câu thô tiếng Anh.
        if message.contains("password token is expired") || message.contains("failureType: 2034") {
            return PurchaseGateError.passwordTokenExpired
        }
        return error
    }

    var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == selection }
    }

    @State private var selection: AppStore.UserAccount.ID = .init()
    @State private var licenseHint: Hint?
    @State private var showLicenseAlert = false
    @State private var hint: Hint?
    @State private var regionDiagnosis: RegionDiagnosis?

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
            followSection
            PriceComparisonView(bundleID: archive.package.software.bundleID)
        }
        .formStyle(.grouped)
        .onAppear {
            selectFallbackAccount()
        }
        .onChange(of: vm.accounts) { _ in
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
        .alert(item: $regionDiagnosis) { diagnosis in
            Alert(
                title: Text("Lỗi do lệch vùng"),
                message: Text(String(
                    format: String(localized: "Lỗi do lệch vùng: tài khoản vùng %@, gói vùng %@ — Apple chỉ cho tải và nhập vào Đã mua ở đúng vùng của tài khoản. Đổi sang tài khoản vùng %@ rồi thử lại, hoặc thêm tài khoản vùng %@ ở tab Tài khoản."),
                    diagnosis.accountRegion, diagnosis.packageRegion, diagnosis.packageRegion, diagnosis.packageRegion
                )),
                primaryButton: .default(Text(String(
                    format: String(localized: "Đổi sang tài khoản vùng %@ và thử lại"),
                    diagnosis.packageRegion
                ))) {
                    Task {
                        await retryAfterRegionSwitch(diagnosis)
                    }
                },
                secondaryButton: .cancel(Text("Đổi tài khoản")) {}
            )
        }
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
                            if let refusal = error as? RegionPurchaseRefusal {
                                regionDiagnosis = RegionDiagnosis(
                                    code: refusal.code,
                                    accountRegion: refusal.accountRegion,
                                    packageRegion: refusal.packageRegion,
                                    operation: .purchase
                                )
                            } else {
                                licenseHint = Hint(message: error.localizedDescription, color: .red)
                            }
                        }
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
        } message: {}
    }

    /// Nút "Đổi sang tài khoản vùng Y và thử lại" trong popup lệch vùng:
    /// nếu đã có tài khoản đúng vùng đăng nhập thì tự đổi picker sang nó
    /// rồi chạy lại đúng thao tác vừa lỗi 1 lần; chưa có tài khoản đúng
    /// vùng thì chỉ hiện hướng dẫn thêm tài khoản ở tab Tài khoản (picker
    /// chọn tài khoản vẫn nằm ngay trên màn này để người dùng tự đổi).
    /// Lần thử lại này không mở popup nữa — lỗi thì hiện hint đỏ.
    private func retryAfterRegionSwitch(_ diagnosis: RegionDiagnosis) async {
        guard let matching = vm.eligibleAccounts(for: diagnosis.packageRegion).first else {
            hint = Hint(message: String(
                format: String(localized: "Chưa có tài khoản vùng %@ đăng nhập. Hãy thêm tài khoản vùng %@ ở tab Tài khoản rồi chọn lại."),
                diagnosis.packageRegion, diagnosis.packageRegion
            ), color: .red)
            return
        }
        selection = matching.id
        do {
            switch diagnosis.operation {
            case .download:
                try await requestDownload()
            case .purchase:
                try await acquireLicense()
            }
        } catch {
            hint = Hint(message: error.localizedDescription, color: .red)
        }
    }

    /// Yêu cầu tải gói đang xem bằng tài khoản đã chọn. Tách riêng để nút
    /// "thử lại" trong popup lệch vùng dùng lại được sau khi đã đổi tài
    /// khoản. Lỗi vùng (2059/1010/-128) thì caller mở popup chẩn đoán;
    /// lỗi khác thì hiện hint đỏ như trước.
    private func requestDownload() async throws {
        guard let account else { return }
        try await dvm.startDownload(for: archive.package, accountID: account.id, region: region)
        hint = Hint(message: String(localized: "Download Requested"), color: nil)
        if let req = dvm.downloadRequest(forArchive: archive.package) {
            navigationPath.append(req)
        }
    }

    /// Rotates the password token and requests a license for the current
    /// account. Sets `licenseHint` to a success message; callers handle errors.
    ///
    /// Mua license có gắn Anisette headers (build 6): rotate token và
    /// buyProduct đều nhận header lấy từ máy chủ Anisette trong Cài đặt
    /// (fork nvd29u1/ApplePackage 541c43a) — trước đây cả hai đều gọi
    /// Apple thiếu header nên Apple có thể từ chối ngay bằng 204 /
    /// redirect không địa chỉ ("failed to retrieve redirect location"),
    /// đúng lỗi gặp sáng 25/11/2026. Lỗi tạm thời kiểu đó thì thử lại tối
    /// đa 3 lần như đăng nhập; lỗi vùng (2059/1010/-128) thì dịch sang
    /// tiếng Việt kèm hướng dẫn thêm tài khoản đúng vùng (xem
    /// RegionPurchaseRefusal) và KHÔNG thử lại vô ích.
    ///
    /// Build 15 — rotate chỉ là best-effort: lỗi "failed to retrieve
    /// redirect location" mà anh gặp 17:55 25/11 chỉ ném được ở
    /// `Authenticator.parseResponse` trong fork, tức là ở bước rotate
    /// (đăng nhập lại), TRƯỚC CẢ khi buyProduct chạy — và request
    /// authenticate không hề chứa vùng của app nên đây KHÔNG phải lỗi
    /// chặn theo vùng (vùng chỉ được xét ở buyProduct, chưa chạy tới).
    /// Phiên đã lưu đã chứng minh còn sống (đồng bộ DMAP ra 368 app +
    /// tải chạy được cùng tài khoản) nên lỗi cửa ở rotate thì giữ phiên
    /// cũ rồi thử mua tiếp; chỉ lỗi phán quyết thật (đòi mã 2FA, sai
    /// mật khẩu, token hết hạn) mới dừng ngay. Nếu token cũ thật sự
    /// chết thì buyProduct sẽ báo đúng lỗi hết hạn, không bị nhầm
    /// thành lỗi cửa nữa.
    private func acquireLicense() async throws {
        guard let account else { return }
        // Lấy header Anisette trước (cùng chính sách như đăng nhập: máy
        // chủ đã đặt mà lấy không được thì dừng, không mua thiếu header).
        let anisetteHeaders = try await vm.anisetteHeadersForStoreCall()
        // AppStore là @MainActor nên đọc URL máy chủ cần await; ghi lại
        // từ đầu để cuối hàm báo lỗi chính xác (đã cấu hình máy chủ hay
        // chưa) mà không phải đọc lại từ ngữ cảnh không phải MainActor.
        let serverURL = await vm.anisetteServerURL
        let anisetteConfigured = !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var lastError: Error?
        // Rotate có lần nào chạm cửa Apple không — để cuối hàm ghi rõ
        // chuỗi lỗi khi buyProduct sau đó báo token hết hạn (build 16:
        // log máy thật 18:43 25/11 chỉ thấy câu 2034 cuối cùng, không
        // thấy rotate lỗi gì nên không soi tiếp được).
        var rotateFailed = false
        for attempt in 1 ... 3 {
            do {
                try await vm.withAccount(id: account.id) { userAccount in
                    do {
                        try await ApplePackage.Authenticator.rotatePasswordToken(for: &userAccount.account, anisetteHeaders: anisetteHeaders)
                    } catch {
                        if Self.isTransientPurchaseError(error) {
                            // Lỗi cửa Apple ở bước làm mới phiên: phiên đã
                            // lưu vẫn còn sống nên thử mua tiếp bằng phiên
                            // đó thay vì bỏ cả lần mua (xem ghi chú trên).
                            // withAccount chỉ ghi lại tài khoản khi closure
                            // chạy xong không lỗi, và rotate chỉ gán tài
                            // khoản mới khi authenticate thành công, nên
                            // rotate hỏng không làm bẩn tài khoản đã lưu.
                            rotateFailed = true
                            logger.info("acquireLicense: token rotation hit Apple gate, continuing with saved session: \(StoreDiagnostics.errorSummary(error))")
                        } else {
                            throw error
                        }
                    }
                    try await ApplePackage.Purchase.purchase(
                        account: &userAccount.account,
                        app: archive.package.software,
                        anisetteHeaders: anisetteHeaders,
                    )
                }
                lastError = nil
                break
            } catch {
                lastError = error
                if let code = Self.regionFailureCode(in: error) {
                    throw RegionPurchaseRefusal(
                        code: code,
                        accountRegion: selectedAccountRegion ?? "?",
                        packageRegion: region
                    )
                }
                guard Self.isTransientPurchaseError(error), attempt < 3 else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if let lastError {
            // Chuỗi lỗi đầy đủ cho lần chẩn đoán sau: rotate chạm cửa
            // rồi buyProduct báo token hết hạn — làm mới lặng lẽ không
            // xong, phải đăng nhập lại tay.
            if rotateFailed, lastError.localizedDescription.contains("password token is expired") || lastError.localizedDescription.contains("failureType: 2034") {
                logger.error("acquireLicense: token rotation failed earlier (Apple gate), buyProduct then reported token expired — silent refresh did not work, re-login needed")
            }
            throw Self.translatePurchaseGateError(lastError, anisetteConfigured: anisetteConfigured)
        }
        licenseHint = Hint(message: String(localized: "Đã nhập vào mục Đã mua. App sẽ hiện trong danh sách Đã mua của Apple ID này, chưa tải file IPA về máy."), color: .green)
        hint = licenseHint
        refreshVersionHistoryAfterLicense()
    }

    /// Lấy license xong thì tự làm mới Lịch sử phiên bản (ý tưởng iPadn
    /// v2.3.5): xoá cache phiên bản cũ rồi tự gọi lại versions() 1 lần
    /// sau ~1,5 giây, để người dùng mở Lịch sử phiên bản là thấy danh
    /// sách mới thay vì phải tự mở lại / bấm Refresh. Cache dùng chung
    /// kho Persist theo gói + vùng nên màn Lịch sử (tạo archive riêng
    /// nhưng cùng khoá) cũng đọc được danh sách mới. Lỗi khi làm mới thì
    /// lặng lẽ bỏ qua — người dùng vẫn mở lại Lịch sử như trước được.
    private func refreshVersionHistoryAfterLicense() {
        guard let account else { return }
        let refreshArchive = AppPackageArchive(accountID: account.id, region: region, package: archive.package)
        guard !refreshArchive.loading else { return }
        refreshArchive.clearVersionItems()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                refreshArchive.populateVersionIdentifiers()
            }
        }
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
                    do {
                        try await acquireLicense()
                    } catch {
                        if let refusal = error as? RegionPurchaseRefusal {
                            regionDiagnosis = RegionDiagnosis(
                                code: refusal.code,
                                accountRegion: refusal.accountRegion,
                                packageRegion: refusal.packageRegion,
                                operation: .purchase
                            )
                        } else {
                            licenseHint = Hint(message: error.localizedDescription, color: .red)
                        }
                        throw error
                    }
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

    /// Theo dõi app (đợt 3, build 8 — ý tưởng iPadn mục 9): bấm Theo dõi
    /// thì app vào màn Đang theo dõi, giá + lịch sử giá được tra qua
    /// iTunes Lookup công khai khi mở màn đó.
    var followSection: some View {
        let appID = archive.package.software.id
        return Section {
            if followStore.isFollowing(appID: appID) {
                if let item = followStore.followed(appID: appID) {
                    HStack {
                        Text("Giá hiện tại")
                        Spacer()
                        Text(item.lastFormattedPrice ?? "Chưa có giá")
                            .foregroundStyle(.secondary)
                    }
                    if let lastVersion = item.lastVersion {
                        HStack {
                            Text("Phiên bản hiện tại")
                            Spacer()
                            Text("v\(lastVersion)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Đã theo dõi từ \(item.addedDate.formatted(date: .abbreviated, time: .omitted)) · \(item.priceHistory.count) lần ghi giá.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Bỏ theo dõi", role: .destructive) {
                    followStore.unfollow(appID: appID)
                }
            } else {
                Button("Theo dõi app này") {
                    followStore.follow(package: archive.package, region: region)
                }
                .nvdBorderBeam(shape: .rounded(10))
            }
        } header: {
            Text("Theo dõi")
        } footer: {
            Text("Theo dõi để xem giá hiện tại và lịch sử giá ở màn Đang theo dõi. Giá chỉ được kiểm tra khi bạn mở màn đó, không chạy nền.")
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
            Text("Đang xem gói ở vùng \(region) (\(StoreRegionCatalog.displayName(for: region))). Vùng tìm kiếm chỉ dùng để tìm app và tra cứu — việc tải và nhập vào Đã mua vẫn theo vùng của tài khoản đã chọn.")
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
                    do {
                        try await requestDownload()
                    } catch {
                        if let code = Self.regionFailureCode(in: error) {
                            regionDiagnosis = RegionDiagnosis(
                                code: code,
                                accountRegion: selectedAccountRegion ?? "?",
                                packageRegion: region,
                                operation: .download
                            )
                        } else if case ApplePackageError.licenseRequired = error, archive.package.software.price == 0 {
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
                            if let refusal = error as? RegionPurchaseRefusal {
                                regionDiagnosis = RegionDiagnosis(
                                    code: refusal.code,
                                    accountRegion: refusal.accountRegion,
                                    packageRegion: refusal.packageRegion,
                                    operation: .purchase
                                )
                            } else {
                                hint = Hint(message: String(localized: "Không nhập được vào mục Đã mua.") + "\n" + error.localizedDescription, color: .red)
                            }
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
                    if isRegionMismatch, let accountRegion = selectedAccountRegion {
                        Text(crossRegionPurchaseNote(for: accountRegion))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
