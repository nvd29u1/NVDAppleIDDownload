//
//  AuthenticationService.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation
import Logging

extension AppStore {
    /// Lỗi này từng hiện ra màn hình dưới dạng "AuthenticationError 0" vì
    /// enum chỉ có 1 case và không có mô tả: đó là lỗi "không tìm thấy tài
    /// khoản theo id đã chọn" (vd. đăng xuất rồi đăng nhập lại bằng Apple ID
    /// khác, hoặc tài khoản đã bị xoá khỏi app, trong khi màn Lịch sử phiên
    /// bản vẫn giữ id cũ). Giờ có mô tả tiếng Việt rõ ràng.
    enum AuthenticationError: Error, LocalizedError {
        case accountNotFound

        var errorDescription: String? {
            String(localized: "Không tìm thấy tài khoản đã chọn trong app. Hãy chọn lại tài khoản ở màn chi tiết app, hoặc đăng nhập lại bằng Apple ID đó rồi thử lại.")
        }
    }

    /// Apple sometimes answers the MZFinance authenticate endpoint with an
    /// empty response (HTTP 204, occasionally 403/404/5xx) before judging the
    /// credentials at all — the request is dropped by Apple's edge, so it is
    /// not a wrong-password or 2FA verdict.
    ///
    /// Same family, second shape (24 Nov 2026): Apple answers with a redirect
    /// status (301/302/303/307/308) but no usable `Location` header, so
    /// ApplePackage `Authenticate.swift` `parseResponse` fails with
    /// "failed to retrieve redirect location" (or the resolve step in
    /// `authenticate()` fails the same way). A redirect with no destination
    /// means Apple refused the request before judging the account — it is
    /// not a wrong-password verdict and not a mistyped-email verdict either:
    /// a bad password or an unknown account comes back as HTTP 200 + plist
    /// with a failureType. The legacy endpoint is supposed to 302 to a pod
    /// URL (see ipatool #513); when the edge drops the client it answers
    /// with an empty 204 or a destination-less redirect instead.
    ///
    /// Sign-in shape (build 19, corrected 25/11): sign-in sends NO
    /// Anisette headers. Proof: iPadn v2.3.5 logs in fine on the same
    /// device/account/network at 22:30 25/11 (even as a LiveContainer
    /// guest) with only Content-Type + X-Apple-ActionSignature on the
    /// authenticate request (AppleService.performLogin +
    /// AppleLoginResponse.body + HTTPClient.userAgent, read 25/11), and
    /// our own build 5 logged in fine on 24/11 when no Anisette server
    /// was configured. The 20:32 25/11 "header-less still 204" test does
    /// NOT refute this: that request still carried attempt "4" + UA
    /// Configurator/2.17. Build 19 aligns the whole sign-in request with
    /// iPadn's proven shape: attempt "1" (fork makeRequest), UA
    /// Configurator/2.21 (below), no Anisette headers. Anisette headers
    /// are still used by store calls (rotate / DMAP / purchase) via
    /// `anisetteHeadersForStoreCall()`, which keep working as before.
    enum AuthenticationGateError: LocalizedError {
        case appleEmptyResponse
        case appleRedirectRefused

        var errorDescription: String? {
            switch self {
            case .appleEmptyResponse:
                return String(localized: "Apple đã từ chối yêu cầu đăng nhập (máy chủ trả về trống — HTTP 204). Đây không phải lỗi sai mật khẩu: hãy kiểm tra tài khoản trong App Store chính thức, thử lại sau hoặc trên mạng khác, hoặc dùng ipatool 2.8.1 trên máy tính.")
            case .appleRedirectRefused:
                return String(localized: "Apple đã từ chối yêu cầu đăng nhập (máy chủ trả về chuyển hướng nhưng không có địa chỉ chuyển tiếp). Đây không phải lỗi sai mật khẩu: hãy kiểm tra lại email Apple ID đã gõ đúng chưa, kiểm tra tài khoản trong App Store chính thức, thử lại sau hoặc trên mạng khác, hoặc dùng ipatool 2.8.1 trên máy tính.")
            }
        }
    }

    /// User-Agent iPadn v2.3.5 dùng cho request đăng nhập
    /// (`HTTPClient.userAgent`, đọc từ source 25/11) — Configurator/2.21
    /// kèm hậu tố AppleWebKit. Bản 19 gắn UA này cho request đăng nhập
    /// (qua fork `Authenticator.requestUserAgent`); UA tĩnh của fork
    /// (Configurator/2.17) vẫn dùng cho các lệnh store khác.
    private static let ipadnSignInUserAgent = "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator) async throws -> UserAccount {
        logger.info("starting authentication for user")
        var currentSession = session
        var lastError: Error?
        // Build 19: đăng nhập KHÔNG gắn header Anisette (xem ghi chú ở
        // AuthenticationGateError: iPadn đăng nhập ngon không cần header,
        // và bản 5 của app cũng vậy lúc 24/11). Chỉ gắn UA iPadn cho
        // session này (và mọi session retry mới tạo sau) để request khớp
        // hình dạng đã chứng minh được Apple chấp nhận.
        await currentSession.setRequestUserAgent(Self.ipadnSignInUserAgent)
        // Up to 3 attempts: the first with the session the UI created (so a
        // 2FA code flow keeps its authenticator), retries with a fresh
        // Authenticator (fresh bag endpoint + fresh SAP handshake).
        for attempt in 1...3 {
            do {
                let appleAccount = try await currentSession.authenticate(
                    email: email,
                    password: password,
                    code: code,
                )
                let userAccount = try save(email: email, account: appleAccount)
                logger.info("authentication successful for user")
                return userAccount
            } catch {
                lastError = error
                // 2FA required must surface immediately so the UI shows the
                // code field; it is not a transient failure.
                if case ApplePackage.AuthenticationError.verificationCodeRequired = error {
                    throw error
                }
                guard Self.isTransientAuthError(error), attempt < 3 else { break }
                logger.info("transient authentication failure (attempt \(attempt)/3): \(error.localizedDescription) — retrying with a fresh session")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    currentSession = try await ApplePackage.Authenticator()
                    // Session mới mất UA iPadn — gắn lại (đăng nhập vẫn
                    // không dùng header Anisette, xem ghi chú đầu hàm).
                    await currentSession.setRequestUserAgent(Self.ipadnSignInUserAgent)
                } catch {
                    // A fresh session could not even be created (bag/SAP
                    // handshake failed); keep the original error.
                    break
                }
            }
        }
        if let error = lastError, Self.isEmptyAppleResponse(error) {
            logger.error("authentication failed for user: \(error.localizedDescription)")
            throw AuthenticationGateError.appleEmptyResponse
        }
        if let error = lastError, Self.isRedirectRefused(error) {
            logger.error("authentication failed for user: \(error.localizedDescription)")
            throw AuthenticationGateError.appleRedirectRefused
        }
        logger.error("authentication failed for user: \(lastError?.localizedDescription ?? "?")")
        throw lastError ?? AuthenticationError.accountNotFound
    }

    /// HTTP statuses Apple has returned with an empty body for the
    /// authenticate endpoint when the request shape is refused before any
    /// credential is judged (see ipatool #513: 204/403/404/301/5xx fluctuate).
    /// A 200 response with a plist body is a real credential verdict and is
    /// never retried here.
    private static func isTransientAuthError(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return ["HTTP 204", "HTTP 403", "HTTP 404", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504", "failed to retrieve redirect location", "redirect limit exceeded"].contains { message.contains($0) }
    }

    private static func isEmptyAppleResponse(_ error: Error) -> Bool {
        error.localizedDescription.contains("HTTP 204")
    }

    private static func isRedirectRefused(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("failed to retrieve redirect location") || message.contains("redirect limit exceeded")
    }

    /// Đăng nhập bằng hệ iPadn (2.1 build 20, chỉ iOS): ký SAP bằng runtime
    /// WASM trên máy + request qua URLSession, đúng hình dạng iPadn đã đăng
    /// nhập được (không header Anisette, attempt "1"/"2", UA 2.21). Thay
    /// đường fork (AsyncHTTPClient) ở sign-in; rotate/DMAP/mua giữ fork.
    /// Lỗi cần mã 2FA được đổi sang lỗi của fork để UI hiện ô nhập mã.
#if os(iOS)
    @MainActor
    func authenticateIPadn(email: String, password: String, code: String) async throws -> UserAccount {
        logger.info("starting iPadn authentication for user")
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let appleAccount = try await IPadnLoginService().login(email: email, password: password, code: code)
                let userAccount = try save(email: email, account: appleAccount)
                logger.info("iPadn authentication successful for user")
                return userAccount
            } catch {
                lastError = error
                if let loginError = error as? IPadnAppleLoginError {
                    if loginError == .verificationRequired {
                        throw ApplePackage.AuthenticationError.verificationCodeRequired
                    }
                    throw error
                }
                if case ApplePackage.AuthenticationError.verificationCodeRequired = error {
                    throw error
                }
                guard Self.isTransientIPadnAuthError(error), attempt < 3 else { break }
                logger.info("transient iPadn authentication failure (attempt \(attempt)/3): \(error.localizedDescription) — retrying")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if let error = lastError, Self.isEmptyAppleResponse(error) {
            logger.error("iPadn authentication failed for user: \(error.localizedDescription)")
            throw AuthenticationGateError.appleEmptyResponse
        }
        if let error = lastError, Self.isRedirectRefused(error) {
            logger.error("iPadn authentication failed for user: \(error.localizedDescription)")
            throw AuthenticationGateError.appleRedirectRefused
        }
        logger.error("iPadn authentication failed for user: \(lastError?.localizedDescription ?? "?")")
        throw lastError ?? AuthenticationError.accountNotFound
    }

    /// Lỗi cửa Apple ở đường iPadn (đáng thử lại): mã HTTP 204/403/404/5xx
    /// hoặc câu lỗi cửa chung. Phán quyết tài khoản thật (sai mật khẩu,
    /// tài khoản bị vô hiệu, mã 2FA sai — qua IPadnAppleLoginError hoặc
    /// IPadnToolError của appleFailure) thì KHÔNG thử lại.
    private static func isTransientIPadnAuthError(_ error: Error) -> Bool {
        if let status = error as? IPadnHTTPStatusError {
            return [204, 403, 404, 500, 502, 503, 504].contains(status.code)
        }
        if let tool = error as? IPadnToolError, case .message(let text) = tool {
            return text.contains("chưa trả về dữ liệu đăng nhập")
                || text.contains("Đăng nhập Apple tạm thời không dùng được")
                || text.contains("Máy chủ trả về bất thường")
                || text.contains("Tạm thời chưa xác minh được")
        }
        return Self.isTransientAuthError(error)
    }
#endif

    /// Anisette headers cho một lệnh store (mua license / rotate token /
    /// DMAP). Nếu đã đặt URL máy chủ Anisette thì lấy header mới trước;
    /// lấy không được thì dừng lại với giải thích tiếng Việt thay vì gọi
    /// Apple thiếu header. URL trống nghĩa là không dùng header — hành vi
    /// cũ giữ nguyên. (Đăng nhập thì KHÔNG dùng hàm này nữa, xem ghi chú
    /// ở AuthenticationGateError.)
    @MainActor
    func anisetteHeadersForStoreCall() async throws -> [String: String] {
        guard !anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let serverURL = AnisetteService.normalizedServerURL(anisetteServerURL) else {
            throw AnisetteService.AnisetteError.invalidURL
        }
        logger.info("fetching Anisette headers from user server for store call")
        let headers = try await AnisetteService.fetchHeaders(from: serverURL)
        logger.info("fetched \(headers.count) Anisette headers for store call")
        return headers
    }

    @MainActor
    @discardableResult
    func rotate(id: UserAccount.ID) async throws -> UserAccount? {
        logger.info("starting account rotation for user id: \(id)")
        guard let account = accounts.first(where: { $0.id == id }) else {
            logger.error("account not found for rotation, id: \(id)")
            throw AuthenticationError.accountNotFound
        }
        do {
            // Token rotation signs in again, so it needs the Anisette
            // headers too when a server URL is set (giữ nguyên như bản
            // 18 — đường này đang chạy được: DMAP đồng bộ 368 app).
            var anisetteHeaders: [String: String] = [:]
            if !anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let serverURL = AnisetteService.normalizedServerURL(anisetteServerURL) else {
                    throw AnisetteService.AnisetteError.invalidURL
                }
                anisetteHeaders = try await AnisetteService.fetchHeaders(from: serverURL)
            }
            let newAppleAccount = try await ApplePackage.Authenticator.authenticate(
                email: account.account.email,
                password: account.account.password,
                code: "",
                cookies: account.account.cookie,
                anisetteHeaders: anisetteHeaders,
            )
            let updatedAccount = try save(email: account.account.email, account: newAppleAccount)
            logger.info("account rotation successful for user id: \(id)")
            return updatedAccount
        } catch {
            logger.error("account rotation failed for user id: \(id): \(error.localizedDescription)")
            throw error
        }
    }
}
