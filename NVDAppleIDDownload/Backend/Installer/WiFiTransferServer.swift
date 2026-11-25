//  WiFiTransferServer.swift
//  NVDAppleIDDownload
//
//  Chia sẻ IPA qua Wi-Fi (đợt 3, build 8 — ý tưởng iPadn mục 10, viết
//  lại sạch, giữ MIT).
//
//  Tái dùng Vapor (thư viện máy chủ HTTP đã có sẵn trong app cho trình
//  cài đặt OTA): một máy chủ HTTP nhỏ chỉ phục vụ 2 đường — trang danh
//  sách "/" liệt kê các IPA đã tải xong, và "/ipa/<id>" cho trình duyệt
//  trên máy tính cùng Wi-Fi tải file về. Không có đăng nhập, không có
//  đường ghi/xoá: chỉ đọc đúng file IPA đã tải xong trong app, đúng
//  như nút "Tải IPA về máy" (Share Sheet) vẫn làm. Máy chủ chỉ chạy
//  khi người dùng bật trong Cài đặt VÀ đang ở màn Chia sẻ qua Wi-Fi;
//  rời màn là tắt ngay (xem WiFiTransferView).
//

import Foundation
import Vapor

#if canImport(Darwin)
    import Darwin
#endif

/// Địa chỉ IPv4 của máy trên mạng Wi-Fi (ưu tiên giao diện en0).
enum LocalNetworkAddress {
    static func currentIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback,
               let address = current.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               let name = current.pointee.ifa_name
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if String(cString: name) == "en0" {
                        return ip
                    }
                    if fallback == nil {
                        fallback = ip
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return fallback
    }
}

/// Máy chủ HTTP nhỏ phục vụ trang tải IPA qua Wi-Fi. Mỗi lần mở màn
/// Chia sẻ thì tạo mới + tắt khi rời màn — không chạy nền.
final class WiFiTransferServer: ObservableObject, @unchecked Sendable {
    private var app: Application?
    @Published private(set) var port: Int = 0
    @Published private(set) var isRunning = false

    /// Địa chỉ đầy đủ để gõ vào trình duyệt máy tính, vd
    /// "http://192.168.1.10:5432". Nil khi máy chủ chưa chạy hoặc máy
    /// chưa có địa chỉ IP (không nối Wi-Fi).
    var addressText: String? {
        guard isRunning, let ip = LocalNetworkAddress.currentIPv4() else { return nil }
        return "http://\(ip):\(port)"
    }

    func start() async throws {
        guard app == nil else { return }
        let port = Int.random(in: 4000 ... 8000)
        let app = try await Application.make()
        app.http.server.configuration.hostname = "0.0.0.0"
        app.http.server.configuration.port = port
        app.http.server.configuration.address = .hostname("0.0.0.0", port: port)

        app.get { _ async -> Response in
            let html = await MainActor.run { Self.indexHtml() }
            return Response(
                status: .ok,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: .init(string: html),
            )
        }

        app.get("ipa", ":id") { req async throws -> Response in
            guard let id = req.parameters.get("id"),
                  let uuid = UUID(uuidString: id)
            else {
                return Response(status: .notFound)
            }
            // Chỉ lấy đường dẫn file (String, Sendable) từ MainActor —
            // manifest là class ObservableObject, không trả thẳng ra khỏi
            // MainActor.run được.
            let filePath: String? = await MainActor.run {
                Downloads.this.manifests.first { $0.id == uuid && $0.completed }?.targetLocation.path
            }
            guard let filePath,
                  FileManager.default.fileExists(atPath: filePath)
            else {
                return Response(status: .notFound)
            }
            return try await req.fileio.asyncStreamFile(
                at: filePath,
                chunkSize: 64 * 1024,
            )
        }

        try app.server.start()
        self.app = app
        self.port = port
        isRunning = true
        logger.info("Wi-Fi transfer server started on port \(port)")
    }

    func stop() async {
        guard let app else { return }
        isRunning = false
        await app.server.shutdown()
        try? await app.asyncShutdown()
        self.app = nil
        logger.info("Wi-Fi transfer server stopped")
    }

    /// Trang danh sách IPA: tên app + phiên bản + dung lượng, mỗi dòng
    /// là link tải trực tiếp. Tên file do người dùng đặt / tên App
    /// Store nên escape HTML để khỏi vỡ trang.
    @MainActor
    private static func indexHtml() -> String {
        let completed = Downloads.this.manifests.filter(\.completed)
        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file
        var rows = ""
        for manifest in completed {
            let name = htmlEscape(manifest.package.software.name)
            let version = htmlEscape(manifest.package.software.version)
            let bundleID = htmlEscape(manifest.package.software.bundleID)
            let size = (try? FileManager.default.attributesOfItem(atPath: manifest.targetLocation.path)[.size] as? Int64)
                .map { sizeFormatter.string(fromByteCount: $0) } ?? ""
            let fileName = "\(bundleID)-\(version).ipa"
            rows += "<li><a href=\"/ipa/\(manifest.id.uuidString)\" download=\"\(htmlEscape(fileName))\">\(name) \(version)</a> — \(size)</li>"
        }
        if rows.isEmpty {
            rows = "<li>Chưa có file IPA nào tải xong.</li>"
        }
        return """
        <!DOCTYPE html>
        <html lang="vi"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>NVDAppleIDDownload — Chia sẻ qua Wi-Fi</title></head>
        <body><h1>File IPA đã tải xong</h1>
        <p>Bấm vào tên app để tải file IPA về máy tính. File vẫn mã hoá FairPlay, gắn với Apple ID đã mua.</p>
        <ul>\(rows)</ul>
        <p>Đóng màn hình này trên điện thoại là máy chủ tắt.</p>
        </body></html>
        """
    }

    private static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
