//  FollowStore.swift
//  NVDAppleIDDownload
//
//  Theo dõi app + lịch sử giá (đợt 3, build 8 — ý tưởng iPadn mục 9,
//  viết lại sạch, giữ MIT).
//
//  Giá lấy từ iTunes Lookup API công khai (không cần đăng nhập) qua
//  ApplePackage.Lookup — giống cách màn Đã mua tra cứu app. Không có
//  kiểm tra nền liên tục: giá chỉ được tra khi người dùng bấm "Kiểm tra
//  giá" ở màn Đang theo dõi (hoặc khi vừa bấm Theo dõi), để khỏi tốn
//  quota / pin. Mỗi lần kiểm tra ghi 1 điểm vào lịch sử giá (chỉ ghi
//  khi giá đổi, hoặc điểm cuối đã hơn 24 giờ, để lịch sử không phình
//  vì bấm kiểm tra liên tục); giữ tối đa 60 điểm/app.
//

import ApplePackage
import Foundation

/// Một điểm trong lịch sử giá của app đã theo dõi.
struct PricePoint: Codable, Hashable {
    let date: Date
    /// Giá số (đơn vị tiền tệ của vùng) — dùng để so sánh rẻ/đắt.
    let price: Double?
    /// Giá đã định dạng theo tiền tệ của vùng, vd "₫22.000" / "$0.99".
    let formattedPrice: String?
}

/// Một app đang được theo dõi.
struct FollowedApp: Codable, Hashable, Identifiable {
    var id: Int64 { appID }

    let appID: Int64
    let bundleID: String
    var name: String
    var artworkURL: String?
    /// Vùng dùng để tra giá (mã ISO-2, vd "VN").
    let region: String
    let addedDate: Date

    var lastPrice: Double?
    var lastFormattedPrice: String?
    var lastVersion: String?
    var lastChecked: Date?
    var priceHistory: [PricePoint]
}

@MainActor
final class FollowStore: ObservableObject {
    static let shared = FollowStore()

    private var _items = Persist<[FollowedApp]>(key: "FollowedApps", defaultValue: [])

    var items: [FollowedApp] {
        get {
            return _items.wrappedValue
        }
        set {
            objectWillChange.send()
            _items.wrappedValue = newValue
        }
    }

    private init() {}

    func isFollowing(appID: Int64) -> Bool {
        items.contains { $0.appID == appID }
    }

    func followed(appID: Int64) -> FollowedApp? {
        items.first { $0.appID == appID }
    }

    /// Bấm Theo dõi ở màn chi tiết app. Ghi ngay 1 lần tra giá đầu
    /// tiên (không chờ người dùng mở màn Đang theo dõi).
    func follow(package: AppStore.AppPackage, region: String) {
        guard !isFollowing(appID: package.software.id) else { return }
        let item = FollowedApp(
            appID: package.software.id,
            bundleID: package.software.bundleID,
            name: package.software.name,
            artworkURL: package.software.artworkUrl.isEmpty ? nil : package.software.artworkUrl,
            region: region,
            addedDate: Date(),
            lastPrice: package.software.price,
            lastFormattedPrice: package.software.formattedPrice,
            lastVersion: package.software.version,
            lastChecked: nil,
            priceHistory: [],
        )
        items.append(item)
        Task { await refresh(appID: package.software.id) }
    }

    func unfollow(appID: Int64) {
        items.removeAll { $0.appID == appID }
    }

    /// Tra lại giá + phiên bản hiện tại của 1 app qua Lookup công khai.
    /// Trả false khi tra không được (mạng lỗi / app đã gỡ) — giữ lại dữ
    /// liệu cũ thay vì xoá.
    @discardableResult
    func refresh(appID: Int64) async -> Bool {
        guard let index = items.firstIndex(where: { $0.appID == appID }) else { return false }
        let item = items[index]
        guard let software = try? await ApplePackage.Lookup.lookup(
            bundleID: item.bundleID,
            countryCode: item.region,
        ) else { return false }
        var updated = item
        updated.name = software.name
        if !software.artworkUrl.isEmpty {
            updated.artworkURL = software.artworkUrl
        }
        updated.lastPrice = software.price
        updated.lastFormattedPrice = software.formattedPrice
        updated.lastVersion = software.version
        updated.lastChecked = Date()
        // Chỉ ghi điểm mới khi giá đổi, hoặc điểm cuối đã hơn 24 giờ —
        // bấm "Kiểm tra giá" liên tục không làm lịch sử phình ra.
        let lastPoint = updated.priceHistory.last
        let priceChanged = lastPoint?.price != software.price
            || lastPoint?.formattedPrice != software.formattedPrice
        let stale = lastPoint.map { Date().timeIntervalSince($0.date) > 24 * 60 * 60 } ?? true
        if updated.priceHistory.isEmpty || priceChanged || stale {
            updated.priceHistory.append(PricePoint(
                date: Date(),
                price: software.price,
                formattedPrice: software.formattedPrice,
            ))
            if updated.priceHistory.count > 60 {
                updated.priceHistory.removeFirst(updated.priceHistory.count - 60)
            }
        }
        items[index] = updated
        logger.info("Follow refresh: \(item.bundleID) price=\(software.formattedPrice ?? "?") version=\(software.version)")
        return true
    }

    /// Tra lại toàn bộ app đang theo dõi (tuần tự, từng app lỗi thì bỏ
    /// qua app đó). Trả về (số app tra được, số app tra lỗi).
    func refreshAll() async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        for item in items {
            if await refresh(appID: item.appID) {
                succeeded += 1
            } else {
                failed += 1
            }
        }
        return (succeeded, failed)
    }
}
