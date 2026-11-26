import ApplePackage
import Foundation

/// Download metadata transport. Keep Apple's raw bodies, cookies and signed
/// asset URLs out of both the Xcode console and the in-app log viewer.
enum StoreDownloadService {
    #if !os(iOS)
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }
    #endif

    /// `region` là mã vùng của gói đang xem (vd "VN"), khi caller biết
    /// (màn chi tiết app / Lịch sử phiên bản). Chỉ dùng để tự sửa lỗi
    /// -128 CountryMismatch: xem `product`.
    static func download(account: inout Account, package: AppStore.AppPackage, region: String? = nil) async throws -> DownloadOutput {
        let email = account.email
        return try await product(account: &account, package: package, version: package.externalVersionID, operation: "download", region: region) { item in
            try output(item: item, email: email)
        }
    }

    static func versions(account: inout Account, package: AppStore.AppPackage, region: String? = nil) async throws -> [String] {
        try await product(account: &account, package: package, version: nil, operation: "versions", region: region) { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
            else { throw StoreDownloadError.noVersions }
            let versions = identifiers.map { StoreProtocol.string($0) }.filter { !$0.isEmpty }
            guard !versions.isEmpty else { throw StoreDownloadError.noVersions }
            return versions
        }
    }

    /// Metadata của 1 phiên bản cũ + thông tin giàu thêm (dung lượng IPA
    /// + ghi chú cập nhật, đợt 3 build 8 — ý tưởng iPadn mục 6). Dung
    /// lượng/ghi chú đọc từ chính metadata tải của Apple khi có (xem
    /// versionExtra); Apple không trả thì để nil — AppPackageArchive sẽ
    /// tra thêm qua Lookup cho phiên bản mới nhất, còn bản cũ không có
    /// thì UI hiện "—" thay vì bịa số.
    static func versionMetadata(account: inout Account, package: AppStore.AppPackage, versionID: String, region: String? = nil) async throws -> (metadata: VersionMetadata, extra: VersionExtra) {
        try await product(account: &account, package: package, version: versionID, operation: "version-metadata", region: region) { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let version = metadata["bundleShortVersionString"] as? String,
                  let dateString = metadata["releaseDate"] as? String,
                  let releaseDate = ISO8601DateFormatter().date(from: dateString)
            else { throw StoreDownloadError.invalidPackage }
            return (VersionMetadata(displayVersion: version, releaseDate: releaseDate), versionExtra(from: metadata))
        }
    }

    /// Dung lượng + ghi chú cập nhật trong metadata tải của Apple. Các
    /// khoá lấy theo tên thường gặp trong phản hồi MZFinance; không có
    /// khoá nào thì trả extra rỗng (nil) — caller không được bịa số.
    static func versionExtra(from metadata: [String: Any]) -> VersionExtra {
        var fileSizeBytes: Int64?
        for key in ["fileSizeBytes", "fileSize", "size", "packageSize"] {
            if let number = metadata[key] as? NSNumber {
                fileSizeBytes = number.int64Value
                break
            }
            if let text = metadata[key] as? String, let value = Int64(text) {
                fileSizeBytes = value
                break
            }
        }
        let releaseNotes = (metadata["releaseNotes"] as? String)
            ?? (metadata["whatsNew"] as? String)
        let notes = releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VersionExtra(
            fileSizeBytes: fileSizeBytes,
            releaseNotes: (notes?.isEmpty == false) ? notes : nil,
        )
    }

    private static func product<Result>(account: inout Account, package: AppStore.AppPackage, version: String?, operation: String, region: String? = nil, parse: ([String: Any]) throws -> Result) async throws -> Result {
        let trace = String(UUID().uuidString.prefix(8))
        let app = package.software
        let version = version.flatMap { $0.isEmpty ? nil : $0 }
        let platform = package.entityType ?? .iPhone
        logger.info("Store download [\(trace)]: operation=\(operation) app=\(app.id) platform=\(platform.rawValue) store=\(account.store) version=\(version ?? "latest")")
        #if !os(iOS)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        #endif
        do {
            #if !os(iOS)
            var effectiveVersion = version
            #endif
            // Apple đôi khi trả về trống / lỗi tạm thời (204/403/404/5xx,
            // redirect không hợp lệ) rồi mới xét tài khoản — cùng họ lỗi
            // với đăng nhập. Thử lại tối đa 3 lần với phiên đã đăng nhập
            // như AuthenticationService làm cho login, thay vì báo lỗi ngay.
            // Một lần lấy metadata (fetch + kiểm tra failure + parse) được
            // gói lại để lỗi -128 bên dưới thử lại được với bản sao tài
            // khoản đã chỉnh vùng.
            func fetchAndParse(using requestAccount: inout Account) async throws -> Result {
                #if os(iOS)
                // Lõi iPadn (asset) thay cho fork fetchWithFallback: tự
                // xử lý versionTicket / kbsync / refresh phiên /
                // acquireFreeApp, không còn gọi ent/download/update của
                // fork. Lỗi -128 (lệch vùng) do cầu nối map từ lỗi
                // storefront của iPadn nên vòng retry -128 bên ngoài
                // vẫn chạy như cũ.
                var lastError: Error?
                for attempt in 1 ... 3 {
                    do {
                        let item = try await IPadnStoreBridge.shared.fetchProductItem(
                            account: &requestAccount, package: package, version: version,
                            operation: operation, region: region, trace: trace)
                        return try parse(item)
                    } catch {
                        lastError = error
                        guard Self.isTransientDownloadError(error), attempt < 3 else { throw error }
                        logger.info("Store download [\(trace)]: transient failure (attempt \(attempt)/3), retrying: \(StoreDiagnostics.errorSummary(error))")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
                throw lastError ?? StoreDownloadError.empty
                #else
                let region = Configuration.countryCode(for: requestAccount.store)
                let response: [String: Any]
                do {
                    var lastError: Error?
                    var fetched: [String: Any]?
                    for attempt in 1 ... 3 {
                        do {
                            fetched = try await StoreDownloadProtocol.fetchWithFallback(version: version) { endpoint, requestedVersion in
                                effectiveVersion = requestedVersion
                                return try await fetch(session: session, endpoint: endpoint, account: &requestAccount,
                                                       appID: app.id, version: requestedVersion, trace: trace)
                            } resolveVersion: {
                                // An unpinned redownload can return a tvOS build for an iOS app.
                                guard let region else { throw StoreDownloadError.catalogUnavailable }
                                let metadata: StoreDownloadProtocol.CatalogVersion
                                do {
                                    metadata = try await catalogVersion(session: session, appID: app.id, region: region, platform: platform, trace: trace)
                                } catch {
                                    try Task.checkCancellation()
                                    throw StoreDownloadError.catalogUnavailable
                                }
                                guard !metadata.externalVersionID.isEmpty,
                                      metadata.bundleID == nil || metadata.bundleID == app.bundleID
                                else { throw StoreDownloadError.catalogUnavailable }
                                logger.info("Store download [\(trace)]: catalog version=\(metadata.externalVersionID)")
                                return metadata.externalVersionID
                            } onFallback: { reason in
                                logger.info("Store download [\(trace)]: trying \(reason == "empty-redownload-http500" ? "update" : "redownload"), reason=\(reason)")
                            }
                            break
                        } catch {
                            lastError = error
                            guard Self.isTransientDownloadError(error), attempt < 3 else { throw error }
                            logger.info("Store download [\(trace)]: transient failure (attempt \(attempt)/3), retrying: \(StoreDiagnostics.errorSummary(error))")
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    }
                    guard let fetched else { throw lastError ?? StoreDownloadError.empty }
                    response = fetched
                }
                // Preserve the existing UI's explicit free-license acquisition flow.
                if StoreDownloadProtocol.failureCode(response) == "9610" {
                    throw ApplePackageError.licenseRequired
                }
                let item = try StoreDownloadProtocol.packageItem(response, bundleID: app.bundleID, version: effectiveVersion)
                return try parse(item)
                #endif
            }
            do {
                let result = try await fetchAndParse(using: &account)
                logger.info("Store download [\(trace)]: product metadata ready")
                return result
            } catch {
                // -128 CountryMismatch (ý tưởng iPadn v2.3.3 tự sửa):
                // vùng của tài khoản không khớp vùng của gói. Thử lại
                // đúng 1 lần với BẢN SAO của tài khoản đã chỉnh `store`
                // sang vùng của gói — bản sao chỉ sống trong lần thử lại,
                // không ghi về `account`, nên tài khoản đã lưu (mà
                // `withAccount` sẽ ghi đè lại sau khi body trả về) không
                // bị đổi vùng. Cookie mới gộp vào bản sao cũng bị bỏ,
                // chấp nhận được cho 1 lần thử. Nếu thử lại cũng lỗi thì
                // ném lỗi -128 gốc để UI chẩn đoán lệch vùng.
                let originalError = error
                guard let downloadError = error as? StoreDownloadError,
                      case let .rejected(code, _) = downloadError, code == "-128",
                      let region,
                      Configuration.countryCode(for: account.store) != region,
                      let adjustedStore = Configuration.storeId(for: region)
                else { throw originalError }
                logger.info("Store download [\(trace)]: CountryMismatch (-128), retrying once with request-local store for region=\(region)")
                var adjustedAccount = account
                adjustedAccount.store = adjustedStore
                do {
                    let result = try await fetchAndParse(using: &adjustedAccount)
                    logger.info("Store download [\(trace)]: product metadata ready (after -128 region fix)")
                    return result
                } catch {
                    logger.info("Store download [\(trace)]: -128 region-fix retry failed, reporting original error")
                    throw originalError
                }
            }
        } catch {
            // localizedDescription and NSError.userInfo can contain Apple messages
            // or a credential-bearing URL. Log only the error type and numeric code.
            logger.error("Store download [\(trace)]: failed, \(StoreDiagnostics.errorSummary(error))")
            throw error
        }
    }

    /// Lỗi tạm thời của Apple khi gọi dịch vụ tải: trả về trống hoặc lỗi
    /// HTTP 204/403/404/5xx, redirect không hợp lệ, hoặc catalog tạm thời
    /// không lấy được. Các lỗi này giống họ lỗi đăng nhập (xem
    /// AuthenticationService.isTransientAuthError) và đáng thử lại với
    /// cùng phiên đã đăng nhập. Lỗi phán quyết thật (vd. gói không hợp lệ,
    /// bị từ chối theo mã lỗi, hết license) thì không thử lại.
    private static func isTransientDownloadError(_ error: Error) -> Bool {
        if let downloadError = error as? StoreDownloadError {
            switch downloadError {
            case let .emptyResponse(status), let .response(status):
                return [204, 403, 404, 500, 502, 503, 504].contains(status)
            case .invalidRedirect, .catalogUnavailable:
                return true
            default:
                return false
            }
        }
        let message = error.localizedDescription
        return ["HTTP 204", "HTTP 403", "HTTP 404", "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504", "failed to retrieve redirect location", "redirect limit exceeded"].contains { message.contains($0) }
    }

    #if !os(iOS)
    private static func catalogVersion(session: URLSession, appID: Int64, region: String, platform: EntityType, trace: String) async throws -> StoreDownloadProtocol.CatalogVersion {
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: platform == .appleTV ? "atv9" : "enterprisestore"),
            URLQueryItem(name: "cc", value: region.lowercased()), URLQueryItem(name: "l", value: "en"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        // No credentials and no automatic redirects. Foundation verifies TLS in
        // Debug too (ApplePackage 1.2.7 disables verification in its Debug client).
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Store download [\(trace)]: catalog HTTP=\(status) bytes=\(data.count)")
        guard status == 200 else { throw StoreDownloadError.catalogUnavailable }
        return try StoreDownloadProtocol.catalogVersion(data, appID: appID)
    }

    private static func fetch(session: URLSession, endpoint: StoreDownloadProtocol.Endpoint,
                              account: inout Account, appID: Int64, version: String?, trace: String) async throws -> [String: Any]
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint == .volumeStore ? Configuration.storeAPIHost(pod: account.pod) : "downloaddispatch.itunes.apple.com"
        components.path = endpoint.path
        if endpoint == .update {
            let bag = try? await Bag.fetchBag()
            guard let update = bag?.updateEndpoint,
                  let advertised = URLComponents(url: update, resolvingAgainstBaseURL: false)
            else { throw StoreDownloadError.emptyResponse(500) }
            components = advertised
        }
        components.queryItems = [URLQueryItem(name: "guid", value: Configuration.deviceIdentifier)]
        guard var url = components.url else { throw StoreDownloadError.invalidRedirect }
        let body = try PropertyListSerialization.data(
            fromPropertyList: StoreDownloadProtocol.payload(endpoint: endpoint, appID: appID,
                                                            guid: Configuration.deviceIdentifier, version: version),
            format: .xml, options: 0,
        )
        for redirect in 0 ... 3 {
            try Task.checkCancellation()
            url = try StoreDownloadProtocol.validatedURL(url)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
            for (name, value) in account.cookie.buildCookieHeader(url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            logger.info("Store download [\(trace)]: endpoint=\(endpoint.rawValue) hop=\(redirect) sessionCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil)")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw StoreDownloadError.response(0) }
            mergeCookies(response: response, url: url, account: &account)
            logger.info("Store download [\(trace)]: endpoint=\(endpoint.rawValue) HTTP=\(response.statusCode) bytes=\(data.count)")
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirect < 3, let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL
                else { throw StoreDownloadError.invalidRedirect }
                url = try StoreDownloadProtocol.validatedURL(next)
                continue
            }
            let plist = StoreProtocol.plist(data)
            if let plist {
                logger.info("Store download [\(trace)]: \(StoreDownloadProtocol.summary(plist))")
            }
            guard response.statusCode == 200, let plist else {
                if data.isEmpty {
                    throw StoreDownloadError.emptyResponse(response.statusCode)
                }
                throw StoreDownloadError.response(response.statusCode)
            }
            return plist
        }
        throw StoreDownloadError.invalidRedirect
    }

    private static func mergeCookies(response: HTTPURLResponse, url: URL, account: inout Account) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String {
                result[name] = value
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProtocol.storeCookieDomain(cookie.domain)
            account.cookie.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
            if let expiry = cookie.expiresDate, expiry <= Date() {
                continue
            }
            account.cookie.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                         expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
        }
    }
    #endif

    /// ApplePackage's DownloadOutput format, also consumed by SignatureInjector.
    private static func output(item: [String: Any], email: String) throws -> DownloadOutput {
        guard let url = item["URL"] as? String, let asset = URL(string: url),
              ["https", "http"].contains(asset.scheme), asset.host != nil,
              var metadata = item["metadata"] as? [String: Any],
              let version = metadata["bundleShortVersionString"] as? String,
              let build = metadata["bundleVersion"] as? String,
              let signatures = item["sinfs"] as? [[String: Any]], !signatures.isEmpty
        else { throw StoreDownloadError.invalidPackage }
        let sinfs = try signatures.map { signature -> Sinf in
            guard let id = signature["id"] as? Int64, let data = signature["sinf"] as? Data else {
                throw StoreDownloadError.invalidPackage
            }
            return Sinf(id: id, sinf: data)
        }
        metadata["apple-id"] = email
        metadata["userName"] = email
        return try DownloadOutput(downloadURL: url, sinfs: sinfs, bundleShortVersionString: version,
                                  bundleVersion: build, iTunesMetadata: PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0))
    }
}
