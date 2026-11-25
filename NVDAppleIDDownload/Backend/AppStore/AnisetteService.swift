//
//  AnisetteService.swift
//  NVDAppleIDDownload
//
//  Fetches Anisette/ADI device-verification headers from the user's own
//  Anisette server (e.g. http://192.168.1.10:6969) and hands them to the
//  ApplePackage authenticator. Since Nov 2026 Apple gates App Store
//  sign-in on these headers (X-Apple-I-MD, X-Apple-I-MD-M,
//  X-Apple-I-MD-RINFO, ...) and ApplePackage does not provision them
//  itself, the app asks the user's server for a fresh set before signing
//  in. The server only ever receives a plain GET for the headers — the
//  Apple ID email and password are never sent to it.
//

import Foundation

enum AnisetteService {
    /// Các máy chủ Anisette công cộng (Mac) cho đường store — cùng danh
    /// sách preset với tab Ký IPA (`Anisette.presets` trong
    /// SignAppleID.swift, giữ tên/URL giống hệt để 2 chỗ chọn giống
    /// nhau). Định nghĩa lại ở đây thay vì dùng chung vì code tab Ký
    /// chỉ biên dịch trên iOS (`#if os(iOS)`), còn đường store dùng
    /// chung cả macOS.
    static let storePresets: [(name: String, url: String)] = [
        ("iloader", "https://ani.iloader.app"),
        ("jkcoxson (Mac)", "https://mac-ani.jkcoxson.com"),
        ("SideStore (new)", "https://new.ani.sidestore.io"),
    ]

    /// Máy chủ mặc định của đường store khi chưa có giá trị lưu: jkcoxson
    /// (máy chủ anh đang dùng, đã kiểm chứng sống 25/11 — nút "Kiểm tra"
    /// trả "Kết nối OK — 10 header", DMAP login HTTP=200). KHÔNG dùng
    /// iloader (mặc định của tab Ký) cho đường store: iloader chỉ phục vụ
    /// giao thức v3 provisioning của tab Ký; GET / trần của nó trả
    /// HTTP 403 (đo bằng curl 25/11), trong khi đường store lấy header
    /// bằng GET / JSON — fetch sẽ lỗi ngay. Tab Ký giữ nguyên mặc định
    /// iloader của nó, không động.
    static let defaultServerURL = "https://mac-ani.jkcoxson.com"

    enum AnisetteError: LocalizedError {
        case invalidURL
        case unreachable(String)
        case invalidResponse
        case noHeaders

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "Địa chỉ máy chủ Anisette không hợp lệ. Nhập dạng http://192.168.1.10:6969 (địa chỉ IP trong mạng nhà của bạn).")
            case let .unreachable(detail):
                return String(localized: "Không kết nối được máy chủ Anisette (\(detail)). Kiểm tra máy chủ đã chạy chưa, iPhone và máy chủ có cùng mạng Wi-Fi không, và địa chỉ trong Cài đặt → Máy chủ Anisette có đúng không. Đăng nhập đã dừng lại — không thử đăng nhập thiếu header.")
            case .invalidResponse:
                return String(localized: "Máy chủ Anisette trả về dữ liệu không phải JSON header. Kiểm tra lại máy chủ Anisette của bạn. Đăng nhập đã dừng lại — không thử đăng nhập thiếu header.")
            case .noHeaders:
                return String(localized: "Máy chủ Anisette không trả về header nào. Kiểm tra lại máy chủ Anisette của bạn. Đăng nhập đã dừng lại — không thử đăng nhập thiếu header.")
            }
        }
    }

    /// Normalizes a user-typed server address. Accepts http:// or https://
    /// with a host; anything else is rejected so a typo fails loudly here
    /// instead of silently during sign-in.
    static func normalizedServerURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// GETs the header JSON from the Anisette server. Accepts every header
    /// key present in the JSON (X-Apple-I-MD, X-Apple-I-MD-M,
    /// X-Apple-I-MD-RINFO, X-Apple-I-MD-LU, X-Apple-I-TimeZone,
    /// X-Mme-Device-Id, X-MMe-Client-Info, ...); only string values are
    /// kept, empty values are dropped.
    static func fetchHeaders(from url: URL) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw AnisetteError.unreachable(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in json where !key.isEmpty {
            if let string = value as? String, !string.isEmpty {
                headers[key] = string
            }
        }
        guard !headers.isEmpty else { throw AnisetteError.noHeaders }
        return headers
    }

    /// One-line Vietnamese status for the "Kiểm tra" button in Settings:
    /// OK with the header count, or the reason it failed.
    static func check(urlString: String) async -> String {
        guard let url = normalizedServerURL(urlString) else {
            return String(localized: "Địa chỉ máy chủ không hợp lệ. Nhập dạng http://192.168.1.10:6969.")
        }
        do {
            let headers = try await fetchHeaders(from: url)
            return String(localized: "Kết nối OK — máy chủ đã trả \(headers.count) header Anisette.")
        } catch {
            return error.localizedDescription
        }
    }
}
