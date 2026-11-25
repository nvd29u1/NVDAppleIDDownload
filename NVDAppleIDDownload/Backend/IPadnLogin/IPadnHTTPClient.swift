#if os(iOS)
import Foundation

/// Recent failed requests for diagnostics: time, host, endpoint name and
/// status only. No query strings, headers, bodies or account details.
enum IPadnRequestFailureLog {
    private static let entries = IPadnLockedValue<[String]>([])
    static func record(_ url: URL?, status: Int? = nil, error: Error? = nil, stage: String? = nil) {
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var parts = [time]
        if let stage { parts.append("stage=" + stage) }
        if let host = url?.host { parts.append("host=" + host) }
        if let last = url?.lastPathComponent, endpointName(last) { parts.append("endpoint=" + last) }
        if let status { parts.append("http=\(status)") }
        if let error = error as NSError? { parts.append("error=\(error.domain)#\(error.code)") }
        let line = parts.joined(separator: "; ")
        entries.withLock { list in list.append(line); if list.count > 20 { list.removeFirst(list.count - 20) } }
    }
    /// Apple endpoint names (buyProduct, volumeStoreDownloadProduct); never
    /// file names or tokens.
    static func endpointName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.allSatisfy { $0.isLetter && $0.isASCII }
    }
    /// Strict ASCII allowlist for Apple plist diagnostic metadata (failureType,
    /// jingleDocType, metrics.dialogId). Kept <= 36 chars so safe metadata
    /// never trips DiagnosticRedactor's 40-char opaque-token filter and
    /// free-form server messages can never be logged.
    static func safeDiagnosticToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 36 else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            return nil
        }
        return trimmed
    }
    /// Strict signed integer validation for Apple `failureType` codes shown
    /// on unmapped fallback alerts (e.g. `-128`, `5005`).
    static func safeFailureCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return nil }
        let digits = trimmed.hasPrefix("-") ? trimmed.dropFirst() : trimmed[...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }
    /// Records redacted metadata for HTTP 200 Apple plist business failures
    /// (`failureType`, `jingleDocType`, `metrics.dialogId`, non-zero `status`).
    /// Never records `customerMessage`, URLs, headers, cookies, or account data.
    static func recordAppleFailure(_ url: URL?, response: [String: Any], stage: String? = nil) {
        let code = safeDiagnosticToken(ipadnPlistString(response["failureType"]))
        let doc = safeDiagnosticToken(ipadnPlistString(response["jingleDocType"]))
        let metrics = response["metrics"] as? [String: Any]
        let dialogID = metrics.flatMap { safeDiagnosticToken(ipadnPlistString($0["dialogId"])) }
        let statusVal = (response["status"] as? NSNumber)?.intValue
        let nonZeroStatus = statusVal.flatMap { $0 != 0 ? $0 : nil }
        guard code != nil || doc != nil || dialogID != nil || nonZeroStatus != nil else { return }
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var parts = [time]
        if let stage, let safeStage = safeDiagnosticToken(stage) { parts.append("stage=" + safeStage) }
        if let host = url?.host { parts.append("host=" + host) }
        if let last = url?.lastPathComponent, endpointName(last) { parts.append("endpoint=" + last) }
        if let code { parts.append("code=" + code) }
        if let doc { parts.append("doc=" + doc) }
        if let dialogID { parts.append("dialog=" + dialogID) }
        if let nonZeroStatus { parts.append("status=\(nonZeroStatus)") }
        let line = parts.joined(separator: "; ")
        entries.withLock { list in list.append(line); if list.count > 20 { list.removeFirst(list.count - 20) } }
    }
    static var text: String { entries.withLock { $0.isEmpty ? "(none)" : $0.joined(separator: "\n") } }
}

final class IPadnHTTPClient: Sendable {
    static let shared = IPadnHTTPClient()
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private let session: URLSession
    private let sessionDelegate: SessionDelegate

    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let delegate = SessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private final class RangeTransfer: @unchecked Sendable {
        let limit: Int
        let lock = NSLock()
        var data = Data()
        var httpResponse: HTTPURLResponse?
        var failure: Error?
        var completed = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?

        init(limit: Int) {
            self.limit = limit
        }

        func snapshot() -> (response: HTTPURLResponse?, failure: Error?, data: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (httpResponse, failure, data)
        }
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var transfers: [Int: RangeTransfer] = [:]

        func attach(_ transfer: RangeTransfer, to task: URLSessionDataTask,
                    continuation: CheckedContinuation<Void, Never>) {
            let alreadyDone: Bool
            lock.lock()
            transfer.lock.lock()
            alreadyDone = transfer.completed || transfer.cancelled
            if alreadyDone {
                transfer.completed = true
            } else {
                transfers[task.taskIdentifier] = transfer
                transfer.continuation = continuation
            }
            transfer.lock.unlock()
            lock.unlock()
            if alreadyDone {
                continuation.resume()
            } else {
                task.resume()
            }
        }

        func cancel(_ transfer: RangeTransfer, task: URLSessionDataTask) {
            let continuation: CheckedContinuation<Void, Never>?
            lock.lock()
            transfers.removeValue(forKey: task.taskIdentifier)
            transfer.lock.lock()
            transfer.cancelled = true
            if transfer.completed {
                continuation = nil
            } else {
                transfer.completed = true
                continuation = transfer.continuation
                transfer.continuation = nil
            }
            transfer.lock.unlock()
            lock.unlock()
            task.cancel()
            continuation?.resume()
        }

        private func transfer(for taskIdentifier: Int) -> RangeTransfer? {
            lock.lock()
            defer { lock.unlock() }
            return transfers[taskIdentifier]
        }

        private func popTransfer(for taskIdentifier: Int) -> RangeTransfer? {
            lock.lock()
            defer { lock.unlock() }
            return transfers.removeValue(forKey: taskIdentifier)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let transfer = transfer(for: dataTask.taskIdentifier) else {
                completionHandler(.allow)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                transfer.lock.lock()
                transfer.failure = IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            transfer.lock.lock()
            transfer.httpResponse = http
            let status = http.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            guard status == 206, http.value(forHTTPHeaderField: "Content-Range") != nil else {
                transfer.failure = IPadnHTTPStatusError(code: status)
                transfer.lock.unlock()
                IPadnRequestFailureLog.record(http.url, status: status, stage: "range")
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(transfer.limit) {
                transfer.failure = IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > 0 {
                transfer.data.reserveCapacity(min(transfer.limit, Int(http.expectedContentLength)))
            }
            transfer.lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard let transfer = transfer(for: dataTask.taskIdentifier) else { return }
            transfer.lock.lock()
            if transfer.data.count + chunk.count > transfer.limit {
                transfer.failure = IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                transfer.lock.unlock()
                dataTask.cancel()
                return
            }
            transfer.data.append(chunk)
            transfer.lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let transfer = popTransfer(for: task.taskIdentifier) else { return }
            transfer.lock.lock()
            if transfer.failure == nil, let error {
                transfer.failure = error
            }
            transfer.completed = true
            let continuation = transfer.continuation
            transfer.continuation = nil
            transfer.lock.unlock()
            continuation?.resume()
        }
    }

    /// Failures that say nothing about the request itself: a busy Apple
    /// server or a pooled connection the system dropped while the app was
    /// in the background. Worth one or two quiet retries.
    static func isTransient(_ error: Error) -> Bool {
        if let status = error as? IPadnHTTPStatusError { return [408, 429, 500, 502, 503, 504].contains(status.code) }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed].contains(ns.code)
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil,
                 headers: [String: String] = [:], appleRedirects: Bool = false,
                 authentication: Bool = false, allowRedirects: Bool = true,
                 retryTransient: Bool? = nil, timeoutInterval: TimeInterval? = nil,
                 refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> (Data, HTTPURLResponse) {
        let retries = (retryTransient ?? (method == "GET")) ? 2 : 0
        var attempt = 0
        var currentHeaders = headers
        while true {
            do {
                return try await requestOnce(url, method: method, body: body, headers: currentHeaders, appleRedirects: appleRedirects,
                                             authentication: authentication, allowRedirects: allowRedirects,
                                             timeoutInterval: timeoutInterval, refreshHeaders: refreshHeaders)
            } catch {
                guard attempt < retries, Self.isTransient(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                if let refreshHeaders {
                    currentHeaders = try await refreshHeaders(url)
                }
            }
        }
    }

    private func requestOnce(_ url: URL, method: String, body: Data?,
                             headers: [String: String], appleRedirects: Bool,
                             authentication: Bool, allowRedirects: Bool,
                             timeoutInterval: TimeInterval?,
                             refreshHeaders: ((URL) async throws -> [String: String])?) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw IPadnToolError.message("Liên kết không hợp lệ.")
        }
        var current = url
        var activeMethod = method
        var activeBody = body
        var activeHeaders = headers
        let initialHost = url.host?.lowercased()
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            if let timeoutInterval { request.timeoutInterval = timeoutInterval }
            request.httpMethod = activeMethod; request.httpBody = activeBody
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            activeHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.") }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard allowRedirects else { throw IPadnHTTPStatusError(code: response.statusCode) }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let rawNext = URL(string: location, relativeTo: current)?.absoluteURL,
                      rawNext.scheme?.lowercased() == "https", let host = rawNext.host?.lowercased(),
                      rawNext.user == nil, rawNext.password == nil else {
                    throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                }
                let next: URL
                if authentication {
                    guard [301, 302, 307, 308].contains(response.statusCode),
                          let normalized = IPadnAppleAuthentication.normalizedEndpoint(rawNext) else {
                        throw IPadnToolError.message("Địa chỉ đăng nhập Apple mà máy chủ trả về không hợp lệ, hãy thử lại sau")
                    }
                    next = normalized
                } else if appleRedirects {
                    guard host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                        throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                    }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                } else {
                    guard host == initialHost else { throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.") }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                }
                if let refreshHeaders {
                    activeHeaders = try await refreshHeaders(next)
                } else if !IPadnAppleAuthentication.needsStoreProof(next, method: activeMethod) {
                    activeHeaders = activeHeaders.filter {
                        !["x-apple-amd", "x-apple-amd-m"].contains($0.key.lowercased())
                    }
                }
                current = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                IPadnRequestFailureLog.record(current, status: response.statusCode)
                throw IPadnHTTPStatusError(code: response.statusCode)
            }
            return (data, response)
        }
        throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
    }

    /// Executes a single HTTPS request without automatic redirect following or status-code
    /// throwing, so callers that need `Location`, `pod`, or `Set-Cookie` on 302 hops
    /// (such as Apple's commerce purchase history endpoint) can drive redirects directly.
    func rawRequest(_ url: URL, method: String = "GET",
                    headers: [String: String] = [:],
                    timeoutInterval: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw IPadnToolError.message("Liên kết không hợp lệ.")
        }
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
        }
        return (data, http)
    }

    /// One byte range (`"0-99"` or `"-100"`) and its Content-Range. The body
    /// is streamed in chunks via `URLSessionDataDelegate` so a server that
    /// ignores Range or exceeds `limit` is aborted without byte-by-byte overhead.
    func range(_ url: URL, _ value: String, limit: Int, timeoutInterval: TimeInterval = 15) async throws -> (Data, String) {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw IPadnToolError.message("Liên kết không hợp lệ.") }
        var current = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.timeoutInterval = timeoutInterval
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=" + value, forHTTPHeaderField: "Range")
            let transfer = RangeTransfer(limit: limit)
            let task = session.dataTask(with: request)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    sessionDelegate.attach(transfer, to: task, continuation: continuation)
                }
            } onCancel: {
                sessionDelegate.cancel(transfer, task: task)
            }
            try Task.checkCancellation()
            let (response, failure, body) = transfer.snapshot()
            if let response, [301, 302, 303, 307, 308].contains(response.statusCode) {
                // Package downloads may hop between Apple's own CDN hosts.
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      next.scheme == "https", let host = next.host?.lowercased(), next.user == nil, next.password == nil,
                      host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else {
                    throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
                }
                current = next
                continue
            }
            if let failure { throw failure }
            guard let response, response.statusCode == 206, let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
                throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
            }
            return (body, contentRange)
        }
        throw IPadnToolError.message("Máy chủ trả về bất thường, hãy thử lại sau.")
    }

    func json(_ url: URL, timeoutInterval: TimeInterval? = nil, retryTransient: Bool? = nil) async throws -> Any {
        let (data, _) = try await request(url, retryTransient: retryTransient, timeoutInterval: timeoutInterval)
        return try JSONSerialization.jsonObject(with: data)
    }

    func plist(_ url: URL, body: Data, headers: [String: String], allowRedirects: Bool = true,
               retryTransient: Bool = false,
               refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(url, method: "POST", body: body, headers: headers,
                                                 appleRedirects: allowRedirects, allowRedirects: allowRedirects,
                                                 retryTransient: retryTransient, refreshHeaders: refreshHeaders)
        do {
            let dictionary = try IPadnApplePropertyList.dictionary(data)
            return (dictionary, response)
        } catch {
            if response.statusCode == 200, IPadnAppleAuthentication.storeMachineAction(raw: [:], response: response) != nil {
                return ([:], response)
            }
            throw error
        }
    }

    static func encodePlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    static func appleFailure(_ response: [String: Any]) -> IPadnToolError? {
        let code = ipadnPlistString(response["failureType"])
        let customerMessage = ipadnPlistString(response["customerMessage"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if customerMessage == "Your account is disabled." {
            return .message("Tài khoản Apple này đã bị vô hiệu hoá, hãy khôi phục trên trang Apple hoặc trong Cài đặt hệ thống rồi thử lại.")
        }
        if customerMessage == "Your password has changed." {
            return .message("Mật khẩu tài khoản Apple đã đổi, hãy đăng nhập lại.")
        }
        guard !code.isEmpty else { return nil }
        let messages = [
            "1008": "Phiên đăng nhập Apple đã hết hạn, hãy đăng nhập lại.",
            "2002": "Tài khoản Apple cần đăng nhập lại, hãy kiểm tra lại mật khẩu.",
            "5002": "Dịch vụ Apple tạm thời không dùng được, hãy thử lại sau.",
            "5020": "Tài khoản, mật khẩu hoặc mã xác minh chưa đúng; nếu đã chắc chắn đúng, hãy kiểm tra trạng thái tài khoản trong App Store hệ thống rồi thử lại.",
            "2040": "App này hiện không tải được từ Apple.",
            "-5000": "Tài khoản hoặc mật khẩu Apple chưa đúng.",
            "2059": "App này tạm thời chưa tải được, hãy thử lại sau.",
            "1010": "App này chưa có ở vùng của tài khoản này.",
            "2034": "Phiên đăng nhập Apple đã hết hạn, hãy đăng nhập lại.",
            "2042": "Phiên đăng nhập Apple đã hết hạn, hãy đăng nhập lại.",
            "2019": "App trả phí thì mua trước qua App Store.",
            "9610": "Tài khoản hiện tại chưa có quyền tải app này. Hãy lấy app trong App Store trước."
        ]
        if let mapped = messages[code] {
            return .message(mapped)
        }
        // Raw customerMessage often contains internal localization keys,
        // response codes, or English diagnostic text; never show it in the UI.
        // For unmapped failures, surface only a strictly validated numeric code
        // so reports identify the Apple rejection without leaking server text.
        if let numericCode = IPadnRequestFailureLog.safeFailureCode(code) {
            return .message("Apple tạm thời chưa hoàn thành được thao tác này, hãy thử lại sau (mã \(numericCode)).")
        }
        return .message("Apple tạm thời chưa hoàn thành được thao tác này, hãy thử lại sau.")
    }
}
#endif
