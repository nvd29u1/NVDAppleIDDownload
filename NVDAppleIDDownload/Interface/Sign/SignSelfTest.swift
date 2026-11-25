#if os(iOS)
import Foundation
import Security

final class PinnedTrust: NSObject, URLSessionDelegate {
    let anchor: SecCertificate
    init(anchor: SecCertificate) { self.anchor = anchor }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

enum Diagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["NVD_SIGN_SELFTEST"] == "1" }

    @MainActor
    static func run(_ state: SignAppState) async {
        let dir = SignPaths.documents.appendingPathComponent("selftest", isDirectory: true)
        let logURL = SignPaths.documents.appendingPathComponent("selftest.log")
        var lines: [String] = []
        func log(_ s: String) {
            lines.append("[\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] " + s)
            try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
        log("selftest start, iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let fm = FileManager.default
        do {
            let p12 = try Data(contentsOf: dir.appendingPathComponent("cert.p12"))
            let prof = try Data(contentsOf: dir.appendingPathComponent("profile.mobileprovision"))
            let pass = (try? String(contentsOf: dir.appendingPathComponent("pass.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identity = try SayoCore.importP12(p12, password: pass)
            log("p12 ok: \(identity.details.subject) team=\(identity.details.team) until=\(identity.details.notAfter)")
            let chain = SayoCore.appleChain(identity.certificate)
            log("apple chain: \(chain.count) certs")
            let (status, _) = await SayoCore.checkOCSP(identity.certificate)
            log("ocsp: \(status.rawValue)")
            let cert: StoredCertificate
            if let existing = state.certificates.first(where: { $0.details.serial == identity.details.serial }) {
                cert = existing
                log("certificate already stored")
            } else {
                cert = try state.addCertificate(p12: p12, profile: prof, password: pass, nickname: "Selftest")
                log("certificate stored: \(cert.profile.appID) wildcard=\(cert.profile.isWildcard)")
            }

            let ipaSrc = dir.appendingPathComponent("app.ipa")
            let ipa = SignPaths.work.appendingPathComponent("selftest.ipa")
            try? fm.removeItem(at: ipa)
            try fm.copyItem(at: ipaSrc, to: ipa)
            let before = state.library.count
            await state.importIPA(ipa)
            guard state.library.count > before, let app = state.library.first else { throw SayoError("import failed: \(state.toast ?? "")") }
            log("imported: \(app.name) \(app.bundleID) v\(app.version) encrypted=\(app.encrypted)")

            var tweaks: [URL] = []
            for name in ["tweak.dylib", "tweak.deb"] {
                let t = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: t.path) {
                    let dst = SignPaths.tweaks.appendingPathComponent(name)
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: t, to: dst)
                    tweaks.append(dst)
                }
            }
            log("tweaks: \(tweaks.map { $0.lastPathComponent })")
            var opts = SayoCore.SignOptions()
            opts.displayName = "NVDTest+"
            let t0 = Date()
            let signed = try await state.performSign(app: app, cert: cert, options: opts, tweaks: tweaks) { _, _ in }
            log("signed in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(signed.ipaFile) bundle=\(signed.bundleID) size=\(signed.size)")

            try InstallServer.shared.start(port: state.settings.serverPort)
            log("server started on \(state.settings.serverPort)")
            InstallServer.shared.serve(Served(ipa: state.ipaURL(signed), bundleID: signed.bundleID, version: signed.version,
                                              title: signed.name, icon: nil, token: "selftest"))
            guard let caDER = try? Data(contentsOf: LocalCA.caFile), let ca = SecCertificateCreateWithData(nil, caDER as CFData) else {
                throw SayoError("no local CA")
            }
            let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust(anchor: ca), delegateQueue: nil)
            for path in ["/ping", "/manifest.plist", "/app.ipa"] {
                let u = URL(string: "https://localhost:\(state.settings.serverPort)\(path)")!
                do {
                    let (d, r) = try await session.data(from: u)
                    let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                    var note = ""
                    if path == "/manifest.plist" { note = String(decoding: d, as: UTF8.self).contains(signed.bundleID) ? "has bundle id" : "MISSING bundle id" }
                    if path == "/app.ipa" { note = d.count == Int(signed.size) ? "size matches" : "SIZE MISMATCH \(d.count) vs \(signed.size)" }
                    log("https \(path): \(code) \(d.count) bytes \(note)")
                } catch {
                    log("https \(path): FAILED \(error.localizedDescription)")
                }
            }
            let trusted = await SignInstaller.trusted(port: state.settings.serverPort)
            log("system trust of local CA: \(trusted)")
            if let cfg = LocalCA.mobileconfig() { log("mobileconfig: \(cfg.count) bytes") }
            log("RESULT: OK")
        } catch {
            log("RESULT: FAIL \(error.localizedDescription)")
        }
    }
}
#endif
