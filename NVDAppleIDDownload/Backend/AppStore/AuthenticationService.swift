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
    enum AuthenticationError: Error {
        case accountNotFound
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
    enum AuthenticationGateError: LocalizedError {
        case appleEmptyResponse

        var errorDescription: String? {
            String(localized: "Apple đã từ chối yêu cầu đăng nhập (máy chủ trả về trống — HTTP 204). Đây không phải lỗi sai mật khẩu: hãy kiểm tra tài khoản trong App Store chính thức, thử lại sau hoặc trên mạng khác, hoặc dùng ipatool 2.8.1 trên máy tính.")
        }
    }

    @MainActor
    func authenticate(email: String, password: String, code: String, using session: ApplePackage.Authenticator) async throws -> UserAccount {
        logger.info("starting authentication for user")
        var currentSession = session
        var lastError: Error?
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
        return ["HTTP 204", "HTTP 403", "HTTP 404", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504"].contains { message.contains($0) }
    }

    private static func isEmptyAppleResponse(_ error: Error) -> Bool {
        error.localizedDescription.contains("HTTP 204")
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
            let newAppleAccount = try await ApplePackage.Authenticator.authenticate(
                email: account.account.email,
                password: account.account.password,
                code: "",
                cookies: account.account.cookie,
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
