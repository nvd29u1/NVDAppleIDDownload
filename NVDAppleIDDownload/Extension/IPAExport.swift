//
//  IPAExport.swift
//  NVDAppleIDDownload
//
//  Xuất file IPA đã tải ra khỏi app (Lưu vào Tệp / AirDrop / chia sẻ).
//  File IPA tải về vẫn mã hoá FairPlay và gắn với Apple ID đã mua — chỉ xuất
//  đúng file đã tải, không giải mã, không đổi tên bundle, không sửa nội dung.
//

import Foundation

enum IPAExport {
    /// Tên file khi xuất: "<bundleID>-<version>.ipa", giống nút "Cài qua AirDrop".
    static func exportedFileName(for manifest: PackageManifest) -> String {
        "\(manifest.package.software.bundleID)-\(manifest.package.software.version).ipa"
    }

    /// File IPA gốc đã tải xong còn trên máy không.
    static func isAvailable(for manifest: PackageManifest) -> Bool {
        guard manifest.completed else { return false }
        return FileManager.default.fileExists(atPath: manifest.targetLocation.path)
    }

    /// Sao chép file IPA gốc sang thư mục tạm với tên file thân thiện rồi trả
    /// về URL đó. Trả về nil nếu file gốc không còn trên máy.
    static func exportedURL(for manifest: PackageManifest) -> URL? {
        guard FileManager.default.fileExists(atPath: manifest.targetLocation.path) else {
            logger.warning("IPA export: file not found at \(manifest.targetLocation.path)")
            return nil
        }
        let destination = temporaryDirectory
            .appendingPathComponent(exportedFileName(for: manifest))
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: manifest.targetLocation, to: destination)
            return destination
        } catch {
            logger.error("IPA export: copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Mở Share Sheet của iOS/macOS (Lưu vào Tệp, AirDrop, chia sẻ qua app
    /// khác) với file IPA đã xuất. Trả về false nếu không lấy được file hoặc
    /// không mở được Share Sheet — người gọi hiển thị lỗi bằng tiếng Việt.
    @discardableResult
    static func share(manifest: PackageManifest) -> Bool {
        guard let url = exportedURL(for: manifest) else { return false }
        return AirDrop(items: [url])
    }
}
