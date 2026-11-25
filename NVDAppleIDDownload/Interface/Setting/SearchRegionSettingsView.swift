//  SearchRegionSettingsView.swift
//  NVDAppleIDDownload
//
//  Màn chọn vùng tìm kiếm trong Cài đặt (đợt 2, build 7 — ý tưởng iPadn
//  mục 4, viết lại sạch): toàn bộ 177 vùng, tìm theo tên tiếng Việt /
//  tên tiếng Anh / mã ISO-2, tick chọn vùng ưa thích, kéo sắp xếp, khôi
//  phục mặc định.
//
//  Vùng tìm kiếm CHỈ dùng để tìm app và tra cứu catalog. Vùng của tài
//  khoản (để mua license / tải IPA) vẫn theo từng tài khoản — Apple chỉ
//  cho mua theo đúng cửa hàng của tài khoản.
//

import SwiftUI

struct SearchRegionSettingsView: View {
    @AppStorage("searchRegion") private var searchRegion = StoreRegionCatalog.defaultSearchRegion
    @State private var vm = AppStore.this
    @State private var query = ""
#if os(iOS)
    @State private var editMode: EditMode = .inactive
#endif

    /// Vùng ưa thích theo thứ tự người dùng đã sắp xếp.
    var favoriteRegions: [StoreRegion] {
        vm.searchFavoriteRegions.compactMap { StoreRegionCatalog.region(for: $0) }
    }

    var favoriteCodes: Set<String> {
        Set(vm.searchFavoriteRegions)
    }

    var filteredAllRegions: [StoreRegion] {
        StoreRegionCatalog.all.filter { StoreRegionCatalog.matches($0, query: query) }
    }

    /// Vùng của các tài khoản đã đăng nhập (để người dùng biết vùng nào
    /// đã có tài khoản mua/tải được).
    var accountRegions: [String] {
        Array(vm.possibleRegions).sorted()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Vùng đang tìm")
                    Spacer()
                    Text(StoreRegionCatalog.pickerLabel(for: searchRegion))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Vùng tìm kiếm hiện tại")
            } footer: {
                Text("Vùng này dùng để tìm app, tra cứu thông tin app và xem lịch sử phiên bản. Vùng của tài khoản (để mua và tải) vẫn theo từng tài khoản, không đổi theo vùng này.")
            }

            Section {
                if favoriteRegions.isEmpty {
                    Text("Chưa có vùng ưa thích nào. Bấm ngôi sao ở danh sách bên dưới để thêm.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(favoriteRegions) { region in
                        favoriteRow(region)
                    }
                    .onMove { offsets, destination in
                        var codes = vm.searchFavoriteRegions
                        codes.move(fromOffsets: offsets, toOffset: destination)
                        vm.searchFavoriteRegions = codes
                    }
                    .onDelete { offsets in
                        var codes = vm.searchFavoriteRegions
                        codes.remove(atOffsets: offsets)
                        vm.searchFavoriteRegions = codes
                    }
                }
                Button("Khôi phục mặc định", role: .destructive) {
                    vm.resetSearchFavoriteRegions()
                    searchRegion = StoreRegionCatalog.defaultSearchRegion
                }
            } header: {
                Text("Vùng ưa thích")
            } footer: {
#if os(iOS)
                Text("Bấm Sửa để kéo sắp xếp hoặc xoá. Vùng ưa thích hiện đầu tiên trong menu chọn vùng ở tab Tìm kiếm.")
#else
                Text("Kéo để sắp xếp lại thứ tự. Vùng ưa thích hiện đầu tiên trong menu chọn vùng ở tab Tìm kiếm.")
#endif
            }

            Section {
                ForEach(filteredAllRegions) { region in
                    regionRow(region)
                }
            } header: {
                Text("Tất cả vùng (\(StoreRegionCatalog.all.count))")
            } footer: {
                if !accountRegions.isEmpty {
                    Text("Vùng của tài khoản đã đăng nhập: \(accountRegions.joined(separator: ", ")) — mua và tải app ở các vùng này thì dùng đúng tài khoản đó.")
                }
            }
        }
        .searchable(text: $query, prompt: "Tìm theo tên hoặc mã vùng (vd VN, US, Nhật Bản)")
        .navigationTitle("Vùng tìm kiếm")
#if os(iOS)
        .toolbar {
            EditButton()
        }
        .environment(\.editMode, $editMode)
#endif
    }

    /// Hàng trong mục ưa thích: bấm vào thì chọn làm vùng đang tìm.
    private func favoriteRow(_ region: StoreRegion) -> some View {
        Button {
            searchRegion = region.code
        } label: {
            HStack {
                Text(StoreRegionCatalog.pickerLabel(for: region.code))
                Spacer()
                if searchRegion == region.code {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Hàng trong danh sách tất cả vùng: bấm vào thì chọn làm vùng đang
    /// tìm; nút ngôi sao thì thêm/bỏ vùng ưa thích.
    private func regionRow(_ region: StoreRegion) -> some View {
        HStack {
            Button {
                searchRegion = region.code
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(region.code) — \(region.vietnameseName)")
                        Text(region.englishName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if searchRegion == region.code {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Button {
                vm.toggleSearchFavoriteRegion(region.code)
            } label: {
                Image(systemName: favoriteCodes.contains(region.code) ? "star.fill" : "star")
                    .foregroundStyle(favoriteCodes.contains(region.code) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
