//  PurchasedView.swift
//  NVDAppleIDDownload
//
//  Màn Đã mua (đợt 2, build 7 — ý tưởng iPadn mục 3, bước DMAP).
//  Đọc danh sách app đã mua của tài khoản qua DMAP (MZPurchaseDaap),
//  hiện icon + tên + Bundle ID + ngày mua, tìm theo tên, bấm vào thì mở
//  màn chi tiết app để tải / xem lịch sử phiên bản. App đã gỡ khỏi App
//  Store vẫn hiện (tìm được bằng App ID) và tải được nếu Apple còn phục
//  vụ. Nút "Đồng bộ lại" làm mới danh sách; chọn nhiều app rồi bấm
//  "Tải các app đã chọn" để đưa vào hàng đợi; xuất CSV qua Share Sheet.
//  CHƯA làm bước /commerce/account/purchases — xem ghi chú cuối màn.
//

import Kingfisher
import SwiftUI

struct PurchasedView: View {
    @State private var store = PurchasedStore.shared
    @State private var vm = AppStore.this
    @AppStorage("searchRegion") private var searchRegion = "US"

    @State private var searchText = ""
    @State private var accountID: AppStore.UserAccount.ID = .init()
    @State private var navigationPath = NavigationPath()
    @State private var resolvingID: Int64?
    @State private var batchHint: Hint?
    @State private var didAutoSync = false

    var account: AppStore.UserAccount? {
        vm.accounts.first { $0.id == accountID }
    }

    var filteredItems: [PurchasedApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return store.items.filter { item in
            item.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(needle)
                || item.bundleID.lowercased().contains(query.lowercased())
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Đã mua")
                .navigationDestination(for: ProductDestination.self) { dest in
                    ProductView(archive: dest.archive, region: dest.region, navigationPath: $navigationPath)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            if store.isSyncing {
                                ProgressView()
                            } else {
                                Label("Đồng bộ lại", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(store.isSyncing || account == nil)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            exportCSV()
                        } label: {
                            Label("Xuất CSV", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.items.isEmpty)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // Nút Chọn/Xong tự làm thay vì EditButton: EditButton
                        // ghi vào environment editMode, còn màn này dùng
                        // store.isSelecting làm trạng thái chọn — hai cái
                        // đánh nhau thì bấm Chọn không có tác dụng.
                        Button(store.isSelecting ? "Xong" : "Chọn") {
                            store.isSelecting.toggle()
                            if !store.isSelecting {
                                store.selectedIDs = []
                            }
                        }
                        .disabled(store.items.isEmpty)
                    }
                }
                .searchable(text: $searchText, prompt: "Tìm theo tên hoặc Bundle ID")
                .onAppear {
                    selectFallbackAccount()
                    store.switchAccount(to: accountID)
                    if !didAutoSync, store.items.isEmpty, account != nil {
                        didAutoSync = true
                        Task { await store.sync() }
                    }
                }
                .onChange(of: accountID) { _, newValue in
                    store.switchAccount(to: newValue)
                    if store.items.isEmpty, account != nil {
                        Task { await store.sync() }
                    }
                }
                .onChange(of: vm.accounts) { _, _ in
                    selectFallbackAccount()
                    store.switchAccount(to: accountID)
                }
        }
    }

    private func selectFallbackAccount() {
        if vm.accounts.contains(where: { $0.id == accountID }) { return }
        accountID = vm.accounts.first?.id ?? .init()
    }

    @ViewBuilder
    private var content: some View {
        if vm.accounts.isEmpty {
            ContentUnavailableView(
                "Chưa có tài khoản nào đăng nhập",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Hãy thêm tài khoản ở tab Tài khoản rồi quay lại đây để xem mục Đã mua.")
            )
        } else {
            List {
                accountSection
                if let lastError = store.lastError {
                    Section {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }
                if store.isSelecting, !store.selectedIDs.isEmpty {
                    Section {
                        AsyncButton {
                            let result = await store.downloadSelected(region: searchRegion)
                            batchHint = Hint(
                                message: result.failed == 0
                                    ? String(localized: "Đã đưa \(result.succeeded) app vào hàng đợi tải.")
                                    : String(localized: "Đã đưa \(result.succeeded) app vào hàng đợi tải, \(result.failed) app không tải được (đã gỡ khỏi App Store hoặc tra không ra)."),
                                color: result.failed == 0 ? .green : .orange
                            )
                        } label: {
                            Text("Tải các app đã chọn (\(store.selectedIDs.count))")
                        }
                        .disabledWhenLoading()
                        .nvdBorderBeam(shape: .rounded(10))
                    } footer: {
                        if let batchHint {
                            Text(batchHint.message)
                                .foregroundStyle(batchHint.color ?? .primary)
                        }
                    }
                }
                if store.items.isEmpty {
                    Section {
                        if store.isSyncing {
                            HStack {
                                ProgressView()
                                Text("Đang đồng bộ danh sách Đã mua…")
                            }
                        } else {
                            Text("Chưa có app nào trong mục Đã mua. Bấm Đồng bộ lại để tải danh sách từ Apple.")
                        }
                    }
                } else {
                    Section {
                        ForEach(filteredItems) { item in
                            PurchasedRow(
                                item: item,
                                artworkURL: store.artworkURLs[item.bundleID],
                                isSelecting: store.isSelecting,
                                isSelected: store.selectedIDs.contains(item.appID),
                                isResolving: resolvingID == item.appID,
                                onTap: { onTapItem(item) }
                            )
                            .onAppear {
                                Task { await store.enrich(item, region: searchRegion) }
                            }
                        }
                    } header: {
                        Text("\(filteredItems.count) app")
                    } footer: {
                        Text(dmapNote)
                    }
                }
            }
        }
    }

    private var dmapNote: String {
        var note = "Danh sách lấy qua DMAP (MZPurchaseDaap) của Apple."
        if let lastSyncDate = store.lastSyncDate {
            note += " Đồng bộ lần cuối: \(lastSyncDate.formatted(date: .abbreviated, time: .shortened))."
        }
        note += " Bước đồng bộ lịch sử mua đầy đủ (/commerce/account/purchases) chưa làm trong đợt này — một số app mua gần đây có thể chưa hiện."
        return note
    }

    private var accountSection: some View {
        Section {
            Picker("Tài khoản", selection: $accountID) {
                ForEach(vm.accounts) { account in
                    Text(account.account.email)
                        .id(account.id)
                }
            }
            .pickerStyle(.menu)
            .redacted(reason: .placeholder, isEnabled: vm.demoMode)
        } header: {
            Text("Tài khoản")
        } footer: {
            Text("Danh sách Đã mua của tài khoản này. Vùng tìm kiếm hiện tại: \(searchRegion) (\(StoreRegionCatalog.displayName(for: searchRegion))) — dùng để tra cứu thông tin app; việc tải vẫn theo vùng của tài khoản.")
        }
    }

    private func onTapItem(_ item: PurchasedApp) {
        if store.isSelecting {
            if store.selectedIDs.contains(item.appID) {
                store.selectedIDs.remove(item.appID)
            } else {
                store.selectedIDs.insert(item.appID)
            }
            return
        }
        guard resolvingID == nil else { return }
        resolvingID = item.appID
        Task {
            let package = await store.resolvePackage(for: item, region: searchRegion)
            await MainActor.run {
                resolvingID = nil
                if let package {
                    navigationPath.append(ProductDestination(archive: package, region: searchRegion))
                } else {
                    batchHint = Hint(
                        message: String(localized: "Không tra được app này trên App Store ở vùng \(searchRegion) — app có thể đã gỡ hẳn. Thử đổi vùng tìm kiếm trong Cài đặt."),
                        color: .red
                    )
                }
            }
        }
    }

    private func exportCSV() {
        guard let url = store.csvFileURL() else {
            batchHint = Hint(message: String(localized: "Không xuất được file CSV."), color: .red)
            return
        }
        if !AirDrop(items: [url]) {
            batchHint = Hint(message: String(localized: "Không mở được Share Sheet để xuất file CSV."), color: .red)
        }
    }
}

/// Hàng trong danh sách Đã mua: icon (tra qua Lookup, chưa có thì hiện
/// icon giữ chỗ), tên, Bundle ID, ngày mua + phiên bản lúc mua.
private struct PurchasedRow: View {
    let item: PurchasedApp
    let artworkURL: URL?
    let isSelecting: Bool
    let isSelected: Bool
    let isResolving: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .font(.title3)
                }
                if let artworkURL {
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
                    Text(item.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let purchaseDate = item.purchaseDate {
                            Text(purchaseDate.formatted(date: .abbreviated, time: .omitted))
                        } else {
                            Text("Không rõ ngày mua")
                        }
                        if !item.version.isEmpty {
                            Text("· v\(item.version)")
                        }
                        if !item.platforms.isEmpty {
                            Text("· \(item.platforms.joined(separator: ", "))")
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
    }
}
