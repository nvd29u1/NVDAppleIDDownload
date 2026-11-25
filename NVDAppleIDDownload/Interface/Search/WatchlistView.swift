//  WatchlistView.swift
//  NVDAppleIDDownload
//
//  Màn "Đang theo dõi" (đợt 3, build 8 — ý tưởng iPadn mục 9, viết lại
//  sạch, giữ MIT).
//
//  Liệt kê app đã bấm Theo dõi ở màn chi tiết: giá hiện tại + phiên
//  bản hiện tại + lịch sử giá (mỗi lần kiểm tra ghi 1 điểm). Bấm vào
//  app thì mở màn chi tiết để tải / xem lịch sử phiên bản. Nút "Kiểm
//  tra giá" tra lại toàn bộ qua iTunes Lookup công khai — chỉ tra khi
//  người dùng bấm, không chạy nền.
//

import ApplePackage
import Kingfisher
import SwiftUI

struct WatchlistView: View {
    @StateObject private var store = FollowStore.shared
    @State private var navigationPath = NavigationPath()
    @AppStorage("searchRegion") private var searchRegion = StoreRegionCatalog.defaultSearchRegion

    @State private var resolvingID: Int64?
    @State private var hint: Hint?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Đang theo dõi")
                .navigationDestination(for: ProductDestination.self) { dest in
                    ProductView(archive: dest.archive, region: dest.region, navigationPath: $navigationPath)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task {
                                isRefreshing = true
                                let result = await store.refreshAll()
                                isRefreshing = false
                                hint = Hint(
                                    message: result.failed == 0
                                        ? String(localized: "Đã kiểm tra giá \(result.succeeded) app.")
                                        : String(localized: "Đã kiểm tra giá \(result.succeeded) app, \(result.failed) app tra không được."),
                                    color: result.failed == 0 ? .green : .orange,
                                )
                            }
                        } label: {
                            if isRefreshing {
                                ProgressView()
                            } else {
                                Label("Kiểm tra giá", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(store.items.isEmpty || isRefreshing)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            NVDContentUnavailableView(
                "Chưa theo dõi app nào",
                systemImage: "eye",
                description: "Mở màn chi tiết một app rồi bấm \"Theo dõi app này\" — giá hiện tại và lịch sử giá sẽ hiện ở đây."
            )
        } else {
            List {
                if let hint {
                    Section {
                        Text(hint.message)
                            .foregroundStyle(hint.color ?? .primary)
                    }
                }
                ForEach(store.items) { item in
                    WatchlistRow(
                        item: item,
                        isResolving: resolvingID == item.appID,
                        onTap: { onTapItem(item) },
                        onUnfollow: { store.unfollow(appID: item.appID) },
                    )
                }
            }
        }
    }

    private func onTapItem(_ item: FollowedApp) {
        guard resolvingID == nil else { return }
        resolvingID = item.appID
        Task {
            let package: AppStore.AppPackage?
            if let software = try? await ApplePackage.Lookup.lookup(bundleID: item.bundleID, countryCode: item.region) {
                package = AppStore.AppPackage(software: software)
            } else {
                package = nil
            }
            await MainActor.run {
                resolvingID = nil
                if let package {
                    navigationPath.append(ProductDestination(archive: package, region: item.region))
                } else {
                    hint = Hint(
                        message: String(localized: "Không tra được app này trên App Store ở vùng \(item.region) — app có thể đã gỡ hẳn."),
                        color: .red,
                    )
                }
            }
        }
    }
}

/// Một app đang theo dõi: nút mở màn chi tiết (icon + tên + vùng +
/// giá + phiên bản hiện tại), nhóm "Lịch sử giá" mở rộng được, nút bỏ
/// theo dõi. Mỗi phần là 1 dòng riêng trong Section để không lồng
/// Button trong DisclosureGroup.
private struct WatchlistRow: View {
    let item: FollowedApp
    let isResolving: Bool
    let onTap: () -> Void
    let onUnfollow: () -> Void

    var body: some View {
        Section {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    if let artworkURL = item.artworkURL.flatMap(URL.init(string:)) {
                        KFImage(artworkURL)
                            .resizable()
                            .clipShape(.rect(cornerRadius: 11))
                            .frame(width: 50, height: 50)
                            .shadow(radius: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 50, height: 50)
                            .overlay {
                                Image(systemName: "app.badge")
                                    .foregroundStyle(.secondary)
                            }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name.isEmpty ? item.bundleID : item.name)
                                .bold()
                                .lineLimit(1)
                            Spacer()
                            if isResolving {
                                ProgressView()
                            }
                        }
                        Text("\(item.region) — \(StoreRegionCatalog.displayName(for: item.region))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(item.lastFormattedPrice ?? "Chưa có giá")
                            if let lastVersion = item.lastVersion {
                                Text("· v\(lastVersion)")
                            }
                            if let lastChecked = item.lastChecked {
                                Text("· \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            DisclosureGroup("Lịch sử giá (\(item.priceHistory.count))") {
                if item.priceHistory.isEmpty {
                    Text("Chưa có lịch sử giá — bấm \"Kiểm tra giá\" để tra lần đầu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(item.priceHistory, id: \.date) { point in
                        HStack {
                            Text(point.date.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(point.formattedPrice ?? "—")
                        }
                        .font(.caption)
                    }
                }
            }
            Button("Bỏ theo dõi", role: .destructive, action: onUnfollow)
                .font(.caption)
        }
    }
}
