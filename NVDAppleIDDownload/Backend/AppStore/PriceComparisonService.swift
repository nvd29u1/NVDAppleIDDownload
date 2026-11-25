//  PriceComparisonService.swift
//  NVDAppleIDDownload
//
//  So giá đa vùng + kiểm tra bản mới cho app đã tải (đợt 3, build 8 —
//  ý tưởng iPadn mục 9, viết lại sạch, giữ MIT).
//
//  Giá lấy từ iTunes Lookup API công khai (không cần đăng nhập) qua
//  ApplePackage.Lookup — cùng đường tra cứu màn Đã mua vẫn dùng. Mỗi
//  vùng hiện giá theo đúng tiền tệ của vùng đó (formattedPrice của
//  Apple), xếp từ rẻ đến đắt theo giá số; không quy đổi sang VNĐ vì
//  app không có tỉ giá — người dùng tự đối chiếu số tiền tệ từng vùng.
//  Kiểm tra bản mới cũng dùng Lookup: chỉ tra khi mở tab Lượt tải,
//  không chạy nền liên tục.
//

import ApplePackage
import Foundation

/// Giá của 1 app ở 1 vùng.
struct RegionPrice: Identifiable, Hashable {
    let region: String
    /// Giá số (đơn vị tiền tệ của vùng); nil = vùng đó không bán / tra lỗi.
    let price: Double?
    /// Giá đã định dạng theo tiền tệ của vùng, vd "₫22.000" / "$0.99".
    let formattedPrice: String?
    /// Phiên bản hiện tại ở vùng đó.
    let version: String?

    var id: String { region }
}

enum PriceComparisonService {
    /// So giá app ở các vùng cho trước (thường là vùng ưa thích đã chọn
    /// ở Cài đặt). Tra tuần tự từng vùng; vùng nào tra lỗi thì vẫn có
    /// mặt trong kết quả với giá nil (xếp cuối) thay vì làm hỏng cả bảng.
    /// Kết quả xếp từ rẻ đến đắt.
    static func compare(bundleID: String, regions: [String]) async -> [RegionPrice] {
        var rows: [RegionPrice] = []
        for region in regions {
            if let software = try? await ApplePackage.Lookup.lookup(bundleID: bundleID, countryCode: region) {
                rows.append(RegionPrice(
                    region: region,
                    price: software.price,
                    formattedPrice: software.formattedPrice,
                    version: software.version,
                ))
            } else {
                rows.append(RegionPrice(region: region, price: nil, formattedPrice: nil, version: nil))
            }
        }
        return rows.sorted {
            ($0.price ?? .greatestFiniteMagnitude) < ($1.price ?? .greatestFiniteMagnitude)
        }
    }

    /// Phiên bản mới nhất của app ở 1 vùng (nil = tra không được).
    static func latestVersion(bundleID: String, region: String) async -> String? {
        try? await ApplePackage.Lookup.lookup(bundleID: bundleID, countryCode: region).version
    }

    /// So sánh 2 số version dạng "1.2.3": từng đoạn so theo số, đoạn
    /// thiếu coi như 0 ("1.2" == "1.2.0"). Trả true khi latest mới hơn.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        let latestParts = latest.split(separator: ".").map { Int($0) ?? 0 }
        let installedParts = installed.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(latestParts.count, installedParts.count)
        for index in 0 ..< count {
            let lhs = index < latestParts.count ? latestParts[index] : 0
            let rhs = index < installedParts.count ? installedParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}

/// Kết quả kiểm tra bản mới cho các app đã tải xong (tab Lượt tải).
/// Chỉ giữ trong bộ nhớ (không lưu file): mỗi lần mở tab thì tra lại.
@MainActor
final class UpdateCheckStore: ObservableObject {
    static let shared = UpdateCheckStore()

    /// Phiên bản mới nhất tra được, theo Bundle ID.
    @Published private(set) var latestVersions: [String: String] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?

    private init() {}

    /// App đã tải có bản mới trên Store không (và chưa được giữ phiên bản).
    func hasUpdate(for manifest: PackageManifest) -> Bool {
        guard !manifest.pinned,
              let latest = latestVersions[manifest.package.software.bundleID]
        else { return false }
        return PriceComparisonService.isNewer(latest, than: manifest.package.software.version)
    }

    func latestVersion(for bundleID: String) -> String? {
        latestVersions[bundleID]
    }

    /// Tra bản mới cho các app đã tải xong. Chỉ tra khi mở tab (caller
    /// gọi từ onAppear), không chạy nền; lần tra cách nhau dưới 10 phút
    /// thì bỏ qua để khỏi spam Lookup.
    func check(manifests: [PackageManifest]) async {
        guard !isChecking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 10 * 60 { return }
        isChecking = true
        defer {
            isChecking = false
            lastChecked = Date()
        }
        for manifest in manifests where manifest.completed {
            let bundleID = manifest.package.software.bundleID
            guard latestVersions[bundleID] == nil else { continue }
            let region = ApplePackage.Configuration.countryCode(for: manifest.account.account.store)
                ?? StoreRegionCatalog.defaultSearchRegion
            if let latest = await PriceComparisonService.latestVersion(bundleID: bundleID, region: region) {
                latestVersions[bundleID] = latest
            }
        }
    }
}
