#if os(iOS)
import Foundation
import Security

struct SayoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
    static func last(_ fallback: String = "Unknown error") -> SayoError {
        let s = String(cString: sayo_last_error())
        return SayoError(s.isEmpty ? fallback : s)
    }
}

final class ProgressBox {
    let handler: (Double, String) -> Void
    init(_ handler: @escaping (Double, String) -> Void) { self.handler = handler }
}

private let progressThunk: sayo_progress_fn = { ctx, fraction, stage in
    guard let ctx = ctx else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
    let s = stage.map { String(cString: $0) } ?? ""
    box.handler(fraction, s)
}

final class KeyBox {
    let key: SecKey
    init(_ key: SecKey) { self.key = key }
}

private let signThunk: sayo_rsa_sign_fn = { ctx, msg, len, out in
    guard let ctx = ctx, let msg = msg, let out = out else { return -1 }
    let box = Unmanaged<KeyBox>.fromOpaque(ctx).takeUnretainedValue()
    let data = Data(bytes: msg, count: len)
    var err: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(box.key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &err) as Data? else {
        return -1
    }
    sayo_buf_init(out)
    let rc = sig.withUnsafeBytes { raw -> Int32 in
        sayo_buf_append(out, raw.baseAddress, sig.count)
    }
    return rc
}

func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base)
    }
}

struct CertDetails: Codable, Hashable {
    var subject: String
    var team: String
    var organization: String
    var issuer: String
    var serial: String
    var notBefore: Date
    var notAfter: Date
}

struct ProfileDetails: Codable, Hashable {
    var name: String
    var teamName: String
    var teamID: String
    var appID: String
    var expiration: Date
    var creation: Date
    var devices: [String]
    var allDevices: Bool
    var getTaskAllow: Bool
    var entitlementKeys: [String]
    var isWildcard: Bool { appID.contains("*") }
    var bundleID: String {
        guard let dot = appID.firstIndex(of: ".") else { return appID }
        return String(appID[appID.index(after: dot)...])
    }
}

enum OCSPStatus: String, Codable {
    case good, revoked, unknown, unchecked
}

struct Identity {
    let key: SecKey
    let certificate: Data
    let details: CertDetails
}

enum SayoCore {
    static func certDetails(_ der: Data) -> CertDetails? {
        var info = sayo_cert_info()
        let rc = der.withUnsafeBytes { raw in
            sayo_cert_parse(raw.bindMemory(to: UInt8.self).baseAddress, der.count, &info)
        }
        if rc != 0 { return nil }
        return CertDetails(subject: cString(info.subject_cn), team: cString(info.subject_ou),
                           organization: cString(info.subject_o), issuer: cString(info.issuer_cn) + " " + cString(info.issuer_ou),
                           serial: cString(info.serial_hex),
                           notBefore: Date(timeIntervalSince1970: TimeInterval(info.not_before)),
                           notAfter: Date(timeIntervalSince1970: TimeInterval(info.not_after)))
    }

    static func importP12(_ data: Data, password: String) throws -> Identity {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw SayoError(L("Wrong certificate password")) }
        guard status == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            // iOS refuses .p12 files made by OpenSSL 3 (AES + PBKDF2, SHA-256 MAC) with
            // errSecDecode (-26275); the engine reads those itself.
            return try importP12Engine(data, password: password, systemStatus: status)
        }
        let identity = identityRef as! SecIdentity
        var key: SecKey?
        var cert: SecCertificate?
        SecIdentityCopyPrivateKey(identity, &key)
        SecIdentityCopyCertificate(identity, &cert)
        guard let k = key, let c = cert else { throw SayoError(L("The .p12 has no private key")) }
        let der = SecCertificateCopyData(c) as Data
        guard let details = certDetails(der) else { throw SayoError(L("Invalid certificate")) }
        return Identity(key: k, certificate: der, details: details)
    }

    private static func importP12Engine(_ data: Data, password: String, systemStatus: OSStatus) throws -> Identity {
        var cert = sayo_buf(), key = sayo_buf()
        let rc = data.withUnsafeBytes { raw in
            sayo_p12_parse(raw.bindMemory(to: UInt8.self).baseAddress, data.count, password, &cert, &key)
        }
        defer {
            if let k = key.data { memset(k, 0, key.len) }
            sayo_buf_free(&cert)
            sayo_buf_free(&key)
        }
        if rc == -2 { throw SayoError(L("Wrong certificate password")) }
        guard rc == 0, let cp = cert.data, let kp = key.data else {
            throw SayoError(L("Cannot read the .p12 file") + " (\(systemStatus)): " + String(cString: sayo_last_error()))
        }
        let der = Data(bytes: cp, count: cert.len)
        let pkcs1 = Data(bytes: kp, count: key.len)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else {
            throw SayoError(L("The .p12 has no private key"))
        }
        guard let details = certDetails(der) else { throw SayoError(L("Invalid certificate")) }
        return Identity(key: k, certificate: der, details: details)
    }

    static func profilePlist(_ data: Data) -> [String: Any]? {
        var buf = sayo_buf()
        let rc = data.withUnsafeBytes { raw in
            sayo_provision_plist_xml(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &buf)
        }
        defer { sayo_buf_free(&buf) }
        guard rc == 0, let p = buf.data else { return nil }
        let xml = Data(bytes: p, count: buf.len)
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }

    static func profileDetails(_ data: Data) -> ProfileDetails? {
        guard let p = profilePlist(data) else { return nil }
        let ents = p["Entitlements"] as? [String: Any] ?? [:]
        let teams = p["TeamIdentifier"] as? [String] ?? []
        return ProfileDetails(name: p["Name"] as? String ?? "",
                              teamName: p["TeamName"] as? String ?? "",
                              teamID: teams.first ?? "",
                              appID: ents["application-identifier"] as? String ?? "",
                              expiration: p["ExpirationDate"] as? Date ?? Date.distantPast,
                              creation: p["CreationDate"] as? Date ?? Date.distantPast,
                              devices: p["ProvisionedDevices"] as? [String] ?? [],
                              allDevices: p["ProvisionsAllDevices"] as? Bool ?? false,
                              getTaskAllow: ents["get-task-allow"] as? Bool ?? false,
                              entitlementKeys: ents.keys.sorted())
    }

    static func profileCertificates(_ data: Data) -> [Data] {
        guard let p = profilePlist(data) else { return [] }
        return p["DeveloperCertificates"] as? [Data] ?? []
    }

    static func appleChain(_ leaf: Data) -> [Data] {
        var ptrs = [UnsafePointer<UInt8>?](repeating: nil, count: 8)
        var lens = [Int](repeating: 0, count: 8)
        let n = leaf.withUnsafeBytes { raw in
            sayo_apple_chain(raw.bindMemory(to: UInt8.self).baseAddress, leaf.count, &ptrs, &lens, 8)
        }
        return (0..<n).compactMap { i in
            guard let p = ptrs[i] else { return nil }
            return Data(bytes: p, count: lens[i])
        }
    }

    static func checkOCSP(_ leaf: Data) async -> (OCSPStatus, Date?) {
        guard let issuer = appleChain(leaf).first else { return (.unknown, nil) }
        var req = sayo_buf()
        var url = [CChar](repeating: 0, count: 512)
        let rc = leaf.withUnsafeBytes { l in
            issuer.withUnsafeBytes { i in
                sayo_ocsp_request(l.bindMemory(to: UInt8.self).baseAddress, leaf.count,
                                  i.bindMemory(to: UInt8.self).baseAddress, issuer.count, &req, &url, 512)
            }
        }
        guard rc == 0, let p = req.data else { sayo_buf_free(&req); return (.unknown, nil) }
        let body = Data(bytes: p, count: req.len)
        sayo_buf_free(&req)
        guard let u = URL(string: String(cString: url)) else { return (.unknown, nil) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/ocsp-request", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        guard let (resp, _) = try? await URLSession.shared.data(for: r) else { return (.unknown, nil) }
        var status: Int32 = 2
        var when: Int64 = 0
        let prc = resp.withUnsafeBytes { raw in
            sayo_ocsp_parse(raw.bindMemory(to: UInt8.self).baseAddress, resp.count, &status, &when)
        }
        if prc != 0 { return (.unknown, nil) }
        switch status {
        case 0: return (.good, nil)
        case 1: return (.revoked, when > 0 ? Date(timeIntervalSince1970: TimeInterval(when)) : nil)
        default: return (.unknown, nil)
        }
    }

    static func unzip(_ zip: URL, to dir: URL, progress: ((Double) -> Void)? = nil) throws {
        let box = ProgressBox { f, _ in progress?(f) }
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
        if sayo_unzip(zip.path, dir.path, progressThunk, ctx) != 0 { throw SayoError.last("Unzip failed") }
    }

    static func zip(_ dir: URL, to file: URL, level: Int32) throws {
        if sayo_zip_dir(dir.path, file.path, level, nil, nil) != 0 { throw SayoError.last("Zip failed") }
    }

    static func extractDeb(_ deb: URL, to dir: URL) throws -> [URL] {
        if sayo_extract_deb(deb.path, dir.path) != 0 { throw SayoError.last("Cannot extract .deb") }
        var paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        if sayo_collect_tweak_dylibs(dir.path, &paths, &count) != 0 { throw SayoError.last() }
        var out: [URL] = []
        if let paths = paths {
            for i in 0..<count {
                if let p = paths[i] { out.append(URL(fileURLWithPath: String(cString: p))) }
            }
        }
        sayo_free_paths(paths, count)
        return out
    }

    struct SignOptions {
        var bundleID = ""
        var displayName = ""
        var version = ""
        var shortVersion = ""
        var iconPNG: URL?
        var entitlements: URL?
        var injections: [URL] = []
        var hookFramework: URL?
        var removePlugins = false
        var removeWatch = false
        var removeURLSchemes = false
        var fileSharing = false
        var minIOS = ""
        var compression: Int32 = 1
        /// Prepare the app to run inside NVDAppleIDDownload (LiveContainer-style) instead of installing it.
        var container = false
    }

    static func signApp(app: URL, profile: Data, identity: Identity, options o: SignOptions,
                        progress: @escaping (Double, String) -> Void) throws {
        let chain = appleChain(identity.certificate)
        let keyBox = KeyBox(identity.key)
        let keyCtx = Unmanaged.passRetained(keyBox).toOpaque()
        defer { Unmanaged<KeyBox>.fromOpaque(keyCtx).release() }
        let pbox = ProgressBox(progress)
        let pctx = Unmanaged.passRetained(pbox).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(pctx).release() }

        var owned: [UnsafeMutablePointer<CChar>] = []
        func cstr(_ s: String) -> UnsafePointer<CChar>? {
            if s.isEmpty { return nil }
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        let certPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: max(identity.certificate.count, 1))
        identity.certificate.copyBytes(to: certPtr, count: identity.certificate.count)
        defer { certPtr.deallocate() }
        let chainPtrs = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: max(chain.count, 1))
        let chainLens = UnsafeMutablePointer<Int>.allocate(capacity: max(chain.count, 1))
        var chainBufs: [UnsafeMutablePointer<UInt8>] = []
        for (i, c) in chain.enumerated() {
            let b = UnsafeMutablePointer<UInt8>.allocate(capacity: c.count)
            c.copyBytes(to: b, count: c.count)
            chainBufs.append(b)
            chainPtrs[i] = UnsafePointer(b)
            chainLens[i] = c.count
        }
        defer {
            chainBufs.forEach { $0.deallocate() }
            chainPtrs.deallocate()
            chainLens.deallocate()
        }

        var id = sayo_identity(cert_der: UnsafePointer(certPtr), cert_len: identity.certificate.count,
                               chain_der: chainPtrs, chain_len: UnsafePointer(chainLens), chain_count: chain.count,
                               sign: signThunk, sign_ctx: keyCtx)

        let injectPtrs = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(o.injections.count, 1))
        defer { injectPtrs.deallocate() }
        for (i, u) in o.injections.enumerated() { injectPtrs[i] = cstr(u.path) }

        var opts = sayo_sign_options()
        opts.bundle_id = cstr(o.bundleID)
        opts.display_name = cstr(o.displayName)
        opts.version = cstr(o.version)
        opts.short_version = cstr(o.shortVersion)
        opts.icon_png_path = o.iconPNG.flatMap { cstr($0.path) }
        opts.entitlements_xml_path = o.entitlements.flatMap { cstr($0.path) }
        opts.inject_paths = injectPtrs
        opts.inject_count = o.injections.count
        opts.hook_framework_path = o.hookFramework.flatMap { cstr($0.path) }
        opts.remove_plugins = o.removePlugins ? 1 : 0
        opts.remove_watch = o.removeWatch ? 1 : 0
        opts.remove_url_schemes = o.removeURLSchemes ? 1 : 0
        opts.file_sharing = o.fileSharing ? 1 : 0
        opts.min_ios = cstr(o.minIOS)
        opts.compression_level = o.compression

        let rc = profile.withUnsafeBytes { raw in
            sayo_sign_app(app.path, raw.bindMemory(to: UInt8.self).baseAddress, profile.count, &id, &opts, progressThunk, pctx)
        }
        if rc != 0 { throw SayoError.last("Signing failed") }
    }
}
#endif
