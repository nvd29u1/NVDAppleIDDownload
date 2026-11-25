#if os(iOS)
import ApplePackage
import Foundation

// MARK: - Đăng nhập theo iPadn (GPL-2.0-or-later, mengangs/iPadn)
//
// Luồng đăng nhập port từ iPadn v2.3.5 (AppleService.performLogin +
// AppleLoginResponse, đọc 25/11/2026): bag qua IPadnHTTPClient (URLSession),
// ký SAP bằng runtime WASM trên máy (IPadnSAPSigner), request authenticate
// đúng hình dạng iPadn (không header Anisette, attempt "1"/"2", UA 2.21).
// Kết quả trả về ApplePackage.Account của fork để các đường đang chạy
// (DMAP / tải / mua license) dùng tiếp không đổi.

/// Lỗi đăng nhập riêng của iPadn (port từ AppleService.AppleLoginError).
enum IPadnAppleLoginError: LocalizedError {
    case verificationRequired, verificationRejected
    var errorDescription: String? {
        switch self {
        case .verificationRequired: return "Hãy cho phép đăng nhập trên thiết bị tin cậy rồi nhập mã 6 số vừa nhận."
        case .verificationRejected: return "Apple chưa chấp nhận lần xác minh này. Hãy kiểm tra lại tài khoản/mật khẩu rồi nhập mã 6 số mới nhất."
        }
    }
}

/// Body + diễn giải response đăng nhập (port từ AppleService.AppleLoginResponse).
enum IPadnAppleLoginResponse {
    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        try IPadnHTTPClient.encodePlist(["appleId": email, "attempt": code.isEmpty ? "1" : "2",
            "guid": guid, "password": password + code, "rmp": "0", "why": "signIn"])
    }

    /// Apple ID dạng SỐ ĐIỆN THOẠI ở Trung Quốc / Ấn Độ chỉ đăng nhập được
    /// khi request nêu đúng store của số đó (ipatool). Apple ID thường trả nil.
    static func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        var international = false
        if number.hasPrefix("+") { international = true; number.removeFirst() }
        else if number.hasPrefix("00") { international = true; number.removeFirst(2) }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let china = "143465", india = "143467"
        if number.count == 13 && number.hasPrefix("861") { return china }
        if number.count == 12 && number.hasPrefix("91") { number.removeFirst(2) }
        else if international { return nil }
        if number.count == 11 && number.hasPrefix("1") { return china }
        if !international && number.count == 11 && number.hasPrefix("0") { number.removeFirst() }
        if number.count == 10, let first = number.first, ("6"..."9").contains(first) { return india }
        return nil
    }

    static func failure(_ response: [String: Any], submittedCode: Bool) -> Error? {
        if let failure = IPadnHTTPClient.appleFailure(response) { return failure }
        let message = ipadnPlistString(response["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" {
            return submittedCode ? IPadnAppleLoginError.verificationRejected : IPadnAppleLoginError.verificationRequired
        }
        if message.hasPrefix("AMD-Action") {
            return IPadnToolError.message("Xác minh thiết bị chưa xong, hãy thử lại sau.")
        }
        if let info = response["accountInfo"] as? [String: Any], !ipadnPlistString(info["appleId"]).isEmpty { return nil }
        if message.isEmpty, !ipadnPlistString(response["passwordToken"]).isEmpty { return nil }
        if message.hasPrefix("MZ") { return IPadnToolError.message("Apple tạm thời chưa hoàn thành đăng nhập, hãy thử lại sau.") }
        return IPadnToolError.message(message.isEmpty ? "Apple chưa trả về thông tin đăng nhập, hãy kiểm tra lại tài khoản rồi thử lại." : message)
    }
}

/// Đăng nhập Apple ID bằng hệ iPadn, trả về ApplePackage.Account của fork.
/// Chỉ chạy trên iOS (runtime SAP dùng WKWebView + UIKit).
@MainActor
final class IPadnLoginService {
    private let signer = IPadnSAPSigner()

    func login(email: String, password: String, code: String) async throws -> ApplePackage.Account {
        try await IPadnSAPSigner.$userInitiated.withValue(true) {
            try await performLogin(email: email, password: password, code: code)
        }
    }

    private func performLogin(email: String, password: String, code: String) async throws -> ApplePackage.Account {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw IPadnToolError.message("Hãy nhập Apple ID và mật khẩu.")
        }
        guard code.isEmpty || (code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else {
            throw IPadnToolError.message("Hãy nhập mã xác minh 6 số.")
        }
        // GUID thiết bị của app (AppStore đã cài từ Keychain lúc mở app,
        // cùng mã dùng cho các lệnh store của fork).
        let deviceID = ApplePackage.Configuration.deviceIdentifier
        guard ipadnNormalizedDeviceGUID(deviceID) != nil else {
            throw IPadnToolError.message("Mã thiết bị chưa sẵn sàng, hãy mở lại app rồi thử lại.")
        }
        let raw: [String: Any]
        let response: HTTPURLResponse
        do {
            let endpoint = try await IPadnAppleAuthentication.configuration(guid: deviceID,
                send: { try await IPadnHTTPClient.shared.request($0, headers: ["Accept": "application/xml"]) },
                report: { logger.info("ipadn login: \($0)") })
            let body = try IPadnAppleLoginResponse.body(email: email, password: password, code: code, guid: deviceID)
            let signature = try await signer.sign(body, guid: deviceID, useCache: true, cacheSignature: false)
            var headers = ["Content-Type": "application/x-apple-plist",
                           "X-Apple-ActionSignature": signature]
            if let storefront = IPadnAppleLoginResponse.phoneNumberStorefront(email) { headers["X-Apple-Store-Front"] = storefront }
            let result = try await IPadnAppleAuthentication.withStoreProof(
                endpoint: endpoint,
                baseHeaders: headers,
                loadProof: { try await self.signer.storeProofHeaders(guid: deviceID, useCache: true) },
                provisionProof: { challenge in
                    try await self.signer.provisionStoreProof(challenge: challenge, guid: deviceID, useCache: true)
                },
                resetProof: { self.signer.resetStoreProof(guid: deviceID) },
                execute: { headerProvider in
                    try await IPadnAppleAuthentication.authenticate(
                        endpoint: endpoint, body: body,
                        makeHeaders: { try await headerProvider(endpoint) },
                        send: { url, body, headers in
                            try await IPadnHTTPClient.shared.request(
                                url, method: "POST", body: body, headers: headers,
                                appleRedirects: true, authentication: true,
                                refreshHeaders: headerProvider
                            )
                        },
                        report: { logger.info("ipadn login: \($0)") }
                    )
                }
            )
            raw = result.0; response = result.1
        } catch is CancellationError {
            throw CancellationError()
        }
        if let failure = IPadnAppleLoginResponse.failure(raw, submittedCode: !code.isEmpty) {
            if (failure as? IPadnAppleLoginError) != .verificationRequired {
                IPadnRequestFailureLog.recordAppleFailure(response.url, response: raw, stage: "login")
            }
            throw failure
        }
        var cookieHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields { cookieHeaders[String(describing: key)] = String(describing: value) }
        let cookies = response.url.map { HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: $0) } ?? []
        let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        var resolvedDSID = ipadnPlistString(raw["dsPersonId"])
        if resolvedDSID.isEmpty,
           let headerDSID = response.value(forHTTPHeaderField: "X-Dsid")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headerDSID.isEmpty, headerDSID.allSatisfy({ $0.isASCII && $0.isNumber }) {
            resolvedDSID = headerDSID
        }
        if resolvedDSID.isEmpty {
            for item in cookies {
                for prefix in ["mz_at0-", "mz_at_ssl-"] where item.name.hasPrefix(prefix) {
                    let candidate = String(item.name.dropFirst(prefix.count))
                    if !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        resolvedDSID = candidate; break
                    }
                }
                if !resolvedDSID.isEmpty { break }
            }
        }
        let info = raw["accountInfo"] as? [String: Any] ?? [:]
        let reportedID = ipadnPlistString(info["appleId"])
        let passwordToken = ipadnPlistString(raw["passwordToken"])
        let id = reportedID.isEmpty && !resolvedDSID.isEmpty && !passwordToken.isEmpty ? email : reportedID
        guard !id.isEmpty else {
            throw IPadnToolError.message("Apple chưa trả về đầy đủ thông tin đăng nhập, hãy thử lại.")
        }
        guard !resolvedDSID.isEmpty, !passwordToken.isEmpty else {
            throw IPadnToolError.message("Apple trả về thông tin đăng nhập chưa đầy đủ, hãy đăng nhập lại.")
        }
        let address = info["address"] as? [String: Any] ?? [:]
        let firstName = ipadnPlistString(address["firstName"])
        let lastName = ipadnPlistString(address["lastName"])
        // Vùng cửa hàng: giống fork (phần đầu của X-Set-Apple-Store-Front,
        // vd "143467-1" → "143467"); không có thì lấy X-Apple-Request-Store-Front.
        let setStore = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestStore = response.value(forHTTPHeaderField: "X-Apple-Request-Store-Front")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let store = ipadnStorefrontIdentifier(setStore.isEmpty ? requestStore : setStore)
        guard !store.isEmpty else {
            throw IPadnToolError.message("Apple chưa trả về vùng cửa hàng của tài khoản, hãy thử lại.")
        }
        let pod = Self.capturePod(from: response)
        let forkCookies: [ApplePackage.Cookie] = cookies.map {
            ApplePackage.Cookie(name: $0.name, value: $0.value, path: $0.path,
                domain: $0.domain, expiresAt: $0.expiresDate?.timeIntervalSince1970,
                httpOnly: $0.isHTTPOnly, secure: $0.isSecure)
        }
        logger.info("ipadn login: success (dsid set, store \(store), cookies \(forkCookies.count), cookie header \(cookieString.isEmpty ? "empty" : "set"))")
        return ApplePackage.Account(
            email: email, password: password, appleId: id, store: store,
            firstName: firstName, lastName: lastName, passwordToken: passwordToken,
            directoryServicesIdentifier: resolvedDSID, cookie: forkCookies, pod: pod.isEmpty ? nil : pod)
    }

    /// Pod từ header `pod`, rồi từ host Location / URL (p<digits>-buy...).
    private static func capturePod(from response: HTTPURLResponse) -> String {
        if let headerPod = response.value(forHTTPHeaderField: "pod")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headerPod.isEmpty, headerPod.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return headerPod
        }
        if let location = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: response.url)?.absoluteURL,
           let host = url.host, let parsed = ipadnPodFromHost(host) {
            return parsed
        }
        if let host = response.url?.host, let parsed = ipadnPodFromHost(host) {
            return parsed
        }
        return ""
    }
}
#endif
