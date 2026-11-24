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
    /// not a wrong-password or 2FA verdict. Since Nov 2026 Apple also gates
    /// App Store sign-in on device verification (Anisette/ADI provisioning),
    /// which ApplePackage 2.0.3 does not perform, so a 204 can be systematic
    /// rather than flaky. There is no newer ApplePackage that fixes this and
    /// upstream Asspp is archived, so the app retries a few times with a fresh
    /// SAP session (fresh bag + fresh handshake) and otherwise explains the
    /// failure plainly instead of showing a bare "HTTP 204".
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
    /// Anisette (24 Nov 2026): when the user has set an Anisette server URL
    /// in Settings, the app fetches fresh Anisette/ADI headers from that
    /// server first and attaches them to the authenticator
    /// (`Authenticator.anisetteHeaders`, fork nvd29u1/ApplePackage), so
    /// every sign-in and 2FA request carries them. If the server cannot be
    /// reached, sign-in stops here with a plain Vietnamese explanation —
    /// signing in without the headers just reproduces the 204/404 above.
    /// With the URL empty, the flow is unchanged.
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

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator) async throws -> UserAccount {
        logger.info("starting authentication for user")
        var currentSession = session
        var lastError: Error?
        // Anisette: when a server URL is set, fetch fresh headers first and
        // attach them to the session (and to every fresh retry session).
        // A failed fetch stops sign-in here with a plain explanation.
        let anisetteHeaders: [String: String]
        if !anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let serverURL = AnisetteService.normalizedServerURL(anisetteServerURL) else {
                throw AnisetteService.AnisetteError.invalidURL
            }
            logger.info("fetching Anisette headers from user server")
            anisetteHeaders = try await AnisetteService.fetchHeaders(from: serverURL)
            logger.info("fetched \(anisetteHeaders.count) Anisette headers")
            await currentSession.setAnisetteHeaders(anisetteHeaders)
        } else {
            anisetteHeaders = [:]
        }
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
                    // A fresh session loses the headers — attach them again
                    // so retries sign in with Anisette headers too.
                    await currentSession.setAnisetteHeaders(anisetteHeaders)
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
            // headers too when a server URL is set.
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
