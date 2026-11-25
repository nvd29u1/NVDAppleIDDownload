//
//  ExportIPAButton.swift
//  NVDAppleIDDownload
//
//  Nút "Tải IPA về máy": mở Share Sheet để lưu file .ipa đã tải vào Tệp
//  hoặc chia sẻ qua AirDrop / ứng dụng khác. Nút mờ đi khi file chưa tải
//  xong hoặc không còn trên máy; nếu mở Share Sheet thất bại thì báo rõ
//  bằng tiếng Việt thay vì crash.
//

import SwiftUI

struct ExportIPAButton: View {
    @ObservedObject var manifest: PackageManifest

    @State private var showError = false

    var body: some View {
        Button {
            if !IPAExport.share(manifest: manifest) {
                showError = true
            }
        } label: {
            Label(String(localized: "Tải IPA về máy"), systemImage: "square.and.arrow.down")
        }
        .disabled(!IPAExport.isAvailable(for: manifest))
        .nvdBorderBeam(shape: .rounded(10))
        .alert(
            String(localized: "Không thể xuất file IPA"),
            isPresented: $showError,
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(localized: "Không tìm thấy file IPA trên máy. File có thể đã bị xoá — hãy tải lại app."))
        }
    }
}
