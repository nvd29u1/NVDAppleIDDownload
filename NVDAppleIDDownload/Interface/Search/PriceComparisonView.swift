//  PriceComparisonView.swift
//  NVDAppleIDDownload
//
//  Mục "So giá các vùng" trong màn chi tiết app (đợt 3, build 8 — ý
//  tưởng iPadn mục 9, viết lại sạch, giữ MIT).
//
//  Bấm "So sánh giá" thì tra giá app ở từng vùng ưa thích đã chọn
//  trong Cài đặt (đợt 2) qua iTunes Lookup công khai — không cần đăng
//  nhập, không dùng tài khoản nào. Kết quả xếp từ rẻ đến đắt; mỗi vùng
//  hiện giá theo đúng tiền tệ của vùng đó (formattedPrice của Apple),
//  chưa quy đổi sang VNĐ vì app không có tỉ giá.
//

import SwiftUI

struct PriceComparisonView: View {
    let bundleID: String

    @State private var store = AppStore.this
    @State private var rows: [RegionPrice] = []
    @State private var isLoading = false
    @State private var didLoad = false

    var body: some View {
        Section {
            if !didLoad, !isLoading {
                Button("So sánh giá ở các vùng ưa thích") {
                    Task { await load() }
                }
                .disabled(store.searchFavoriteRegions.isEmpty)
                Text("Tra giá app ở \(store.searchFavoriteRegions.count) vùng ưa thích đã chọn trong Cài đặt, xếp từ rẻ đến đắt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isLoading {
                HStack {
                    ProgressView()
                    Text("Đang tra giá các vùng…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(StoreRegionCatalog.pickerLabel(for: row.region))
                        Spacer()
                        if let formattedPrice = row.formattedPrice {
                            Text(formattedPrice)
                                .bold(row.region == rows.first?.region)
                        } else {
                            Text("Không có giá")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Tra lại") {
                    Task { await load() }
                }
                .font(.footnote)
            }
        } header: {
            Text("So giá các vùng")
        } footer: {
            Text("Giá lấy từ iTunes Lookup công khai, không cần đăng nhập. Mỗi vùng hiện theo tiền tệ của vùng đó, chưa quy đổi sang VNĐ. Vùng nào không bán app thì hiện \"Không có giá\".")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        rows = await PriceComparisonService.compare(bundleID: bundleID, regions: store.searchFavoriteRegions)
        didLoad = true
    }
}
