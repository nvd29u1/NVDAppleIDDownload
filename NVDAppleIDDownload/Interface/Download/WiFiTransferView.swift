//  WiFiTransferView.swift
//  NVDAppleIDDownload
//
//  Màn "Chia sẻ qua Wi-Fi" (đợt 3, build 8 — ý tưởng iPadn mục 10,
//  viết lại sạch, giữ MIT).
//
//  Máy chủ HTTP (WiFiTransferServer, tái dùng Vapor đã có trong app)
//  chỉ chạy khi: (1) người dùng đã bật "Chia sẻ IPA qua Wi-Fi" trong
//  Cài đặt, và (2) đang ở màn này. Rời màn (bấm Back / chuyển tab) là
//  máy chủ tắt ngay — không chạy nền, không mở cổng khi không dùng.
//  Màn hình hiện rõ địa chỉ IP:cổng để gõ vào trình duyệt máy tính
//  cùng Wi-Fi; máy tính chỉ tải được file IPA đã tải xong, không xem
//  hay sửa gì khác trong app.
//

import SwiftUI

struct WiFiTransferView: View {
    @StateObject private var server = WiFiTransferServer()
    @StateObject private var store = AppStore.this
    @StateObject private var downloads = Downloads.this
    @State private var errorMessage: String?

    private var completedManifests: [PackageManifest] {
        downloads.manifests.filter(\.completed)
    }

    var body: some View {
        Form {
            if !store.wifiTransferEnabled {
                Section {
                    Text("Chia sẻ qua Wi-Fi đang tắt. Bật \"Chia sẻ IPA qua Wi-Fi\" trong Cài đặt rồi quay lại màn này — máy chủ chỉ chạy khi màn này đang mở.")
                } header: {
                    Text("Chưa bật")
                }
            } else if let address = server.addressText {
                Section {
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Sao chép địa chỉ") {
                        copyToClipboard(address)
                    }
                } header: {
                    Text("Địa chỉ trên Wi-Fi")
                } footer: {
                    Text("Mở địa chỉ này bằng trình duyệt trên máy tính cùng Wi-Fi để tải file IPA. Rời màn này là máy chủ tắt ngay.")
                }
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Đang mở máy chủ…")
                    }
                }
            }

            Section {
                if completedManifests.isEmpty {
                    Text("Chưa có file IPA nào tải xong.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(completedManifests, id: \.id) { manifest in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manifest.package.software.name)
                                    .lineLimit(1)
                                Text("\(manifest.package.software.bundleID) · v\(manifest.package.software.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let address = server.addressText {
                                Link("Tải", destination: URL(string: "\(address)/ipa/\(manifest.id.uuidString)")!)
                                    .font(.caption)
                            }
                        }
                    }
                }
            } header: {
                Text("File IPA đã tải xong (\(completedManifests.count))")
            } footer: {
                Text("Chỉ liệt kê file IPA đã tải xong trong app. File vẫn mã hoá FairPlay, gắn với Apple ID đã mua.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Chia sẻ qua Wi-Fi")
        .onAppear {
            guard store.wifiTransferEnabled else { return }
            Task {
                do {
                    try await server.start()
                } catch {
                    errorMessage = String(localized: "Không mở được máy chủ Wi-Fi: \(error.localizedDescription)")
                }
            }
        }
        .onDisappear {
            Task { await server.stop() }
        }
    }
}
