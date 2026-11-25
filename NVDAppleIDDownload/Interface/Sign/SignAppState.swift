#if os(iOS)
import UserNotifications
import Foundation
import Security
import SwiftUI
import UIKit

enum SignPaths {
    static let fm = FileManager.default
    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var support: URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NVDAppleIDDownload", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func dir(_ name: String, in base: URL = support) -> URL {
        let u = base.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var library: URL { dir("Library") }
    static var certificates: URL { dir("Certificates") }
    static var signed: URL { dir("Signed", in: documents) }
    static var work: URL { dir("Work", in: fm.temporaryDirectory) }
    static var tweaks: URL { dir("Tweaks") }
    static var stateFile: URL { support.appendingPathComponent("state.json") }
}

struct PersistedState: Codable {
    var library: [LibraryApp] = []
    var signed: [SignedApp] = []
    var certificates: [StoredCertificate] = []
    var sources: [RepoSource] = []
    var settings = AppSettings()
}

@MainActor
final class SignAppState: ObservableObject {
    static let shared = SignAppState()

    @Published var library: [LibraryApp] = []
    @Published var signed: [SignedApp] = []
    @Published var certificates: [StoredCertificate] = []
    @Published var sources: [RepoSource] = []
    @Published var settings = AppSettings() { didSet { if settings != oldValue { save() } } }
    @Published var downloads: [DownloadTask] = []
    @Published var toast: String?
    @Published var busy: String?
    @Published var pendingSign: LibraryApp?
    @Published var tab = 0

    private var loading = false

    init() { load() }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: SignPaths.stateFile),
              let s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        library = s.library.filter { SignPaths.fm.fileExists(atPath: appURL($0).path) }
        signed = s.signed.filter { SignPaths.fm.fileExists(atPath: ipaURL($0).path) }
        certificates = s.certificates
        sources = s.sources
        settings = s.settings
    }

    func save() {
        if loading { return }
        let s = PersistedState(library: library, signed: signed, certificates: certificates, sources: sources, settings: settings)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: SignPaths.stateFile, options: .atomic)
        }
    }

    func show(_ message: String) {
        toast = message
        let m = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == m { self?.toast = nil }
        }
    }

    func appURL(_ app: LibraryApp) -> URL {
        SignPaths.library.appendingPathComponent(app.id.uuidString).appendingPathComponent("Payload").appendingPathComponent(app.appFolder)
    }

    /// Puts an imported IPA among the signed apps exactly as it is, so an IPA signed
    /// elsewhere can go through NVDAppleIDDownload's installer without being re-signed.
    func addUnsigned(_ app: LibraryApp) async {
        let root = SignPaths.library.appendingPathComponent(app.id.uuidString)
        let appDir = appURL(app)
        let level = Int32(settings.compressionLevel)
        busy = L("Preparing")
        defer { busy = nil }
        do {
            let result: SignedApp = try await Task.detached(priority: .userInitiated) {
                let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
                let bid = info["CFBundleIdentifier"] as? String ?? app.bundleID
                let ver = info["CFBundleShortVersionString"] as? String ?? app.version
                let name = (info["CFBundleDisplayName"] as? String) ?? app.name
                let safe = name.replacingOccurrences(of: "/", with: "-")
                let fileName = "\(safe)_\(ver)_asis_\(UUID().uuidString.prefix(6)).ipa"
                let out = SignPaths.signed.appendingPathComponent(fileName)
                try SayoCore.zip(root, to: out, level: level)
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
                return SignedApp(id: UUID(), libraryID: app.id, name: name, bundleID: bid, version: ver,
                                 certificateName: L("Original signature"), signedAt: Date(), ipaFile: fileName, size: size, tweaks: [])
            }.value
            signed.insert(result, at: 0)
            save()
            show(L("Ready to install, see Signed apps"))
        } catch {
            show(error.localizedDescription)
        }
    }

    /// Free Apple ID signatures last 7 days: remind a day before, so the app can be re-signed in time.
    static func remindBeforeExpiry(_ app: SignedApp) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = LF("%@ expires tomorrow", app.name)
            content.body = L("Re-sign it in NVDAppleIDDownload with your Apple ID to keep it working.")
            content.sound = .default
            let fire = app.signedAt.addingTimeInterval(6 * 24 * 3600).timeIntervalSinceNow
            guard fire > 60 else { return }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false)
            center.add(UNNotificationRequest(identifier: "expiry." + app.id.uuidString, content: content, trigger: trigger))
        }
    }

    func ipaURL(_ app: SignedApp) -> URL {
        SignPaths.signed.appendingPathComponent(app.ipaFile)
    }

    var selectedCertificate: StoredCertificate? {
        if let id = settings.selectedCertificate, let c = certificates.first(where: { $0.id == id }) { return c }
        return certificates.first
    }

    func icon(for app: LibraryApp) -> UIImage? {
        IconCache.shared.icon(appDir: appURL(app), key: app.id.uuidString)
    }

    func importIPA(_ url: URL, source: String = "file") async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let dest = SignPaths.library.appendingPathComponent(id.uuidString, isDirectory: true)
        let task = DownloadTask(name: url.lastPathComponent, progress: 0, status: L("Importing"))
        downloads.append(task)
        defer { downloads.removeAll { $0.id == task.id } }
        do {
            let app: LibraryApp = try await Task.detached(priority: .userInitiated) {
                try SayoCore.unzip(url, to: dest) { f in
                    Task { @MainActor in
                        if let i = SignAppState.shared.downloads.firstIndex(where: { $0.id == task.id }) {
                            SignAppState.shared.downloads[i].progress = f
                        }
                    }
                }
                return try SignAppState.describe(dir: dest, id: id, source: source)
            }.value
            library.insert(app, at: 0)
            save()
            show(LF("Imported %@", app.name))
        } catch {
            try? SignPaths.fm.removeItem(at: dest)
            show(error.localizedDescription)
        }
    }

    nonisolated static func describe(dir: URL, id: UUID, source: String) throws -> LibraryApp {
        let fm = FileManager.default
        let payload = dir.appendingPathComponent("Payload")
        guard let appName = (try? fm.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }) else {
            throw SayoError(L("This file is not a valid IPA"))
        }
        let appDir = payload.appendingPathComponent(appName)
        let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? appName.replacingOccurrences(of: ".app", with: "")
        let size = folderSize(dir)
        let plugins = fm.fileExists(atPath: appDir.appendingPathComponent("PlugIns").path)
        var encrypted = false
        if let exe = info["CFBundleExecutable"] as? String {
            encrypted = isEncrypted(appDir.appendingPathComponent(exe))
        }
        return LibraryApp(id: id, name: name, bundleID: info["CFBundleIdentifier"] as? String ?? "",
                          version: info["CFBundleShortVersionString"] as? String ?? "1.0",
                          build: info["CFBundleVersion"] as? String ?? "",
                          minOS: info["MinimumOSVersion"] as? String ?? "",
                          size: size, added: Date(), source: source, appFolder: appName,
                          hasPlugins: plugins, encrypted: encrypted)
    }

    nonisolated static func isEncrypted(_ exe: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 65536), head.count > 32 else { return false }
        return head.withUnsafeBytes { raw -> Bool in
            let p = raw.bindMemory(to: UInt8.self)
            func u32(_ o: Int) -> UInt32 {
                guard o + 4 <= p.count else { return 0 }
                return UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
            }
            func be32(_ o: Int) -> UInt32 {
                guard o + 4 <= p.count else { return 0 }
                return UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3])
            }
            var base = 0
            if be32(0) == 0xcafebabe {
                let n = Int(be32(4))
                var off = 0
                for i in 0..<min(n, 8) {
                    let a = 8 + i * 20
                    if be32(a) == 0x0100000c { off = Int(be32(a + 8)) }
                }
                if off == 0 && n > 0 { off = Int(be32(16)) }
                return off == 0 ? false : SignAppState.encryptedAt(exe, offset: off)
            }
            guard u32(base) == 0xfeedfacf else { return false }
            let ncmds = Int(u32(16))
            base = 32
            for _ in 0..<ncmds {
                let cmd = u32(base), size = Int(u32(base + 4))
                if size <= 0 { break }
                if cmd == 0x2c || cmd == 0x21 { return u32(base + 16) != 0 }
                base += size
            }
            return false
        }
    }

    nonisolated static func encryptedAt(_ exe: URL, offset: Int) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(offset))
        guard let head = try? h.read(upToCount: 65536) else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? head.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return isEncrypted(tmp)
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    func deleteLibrary(_ app: LibraryApp) {
        try? SignPaths.fm.removeItem(at: SignPaths.library.appendingPathComponent(app.id.uuidString))
        library.removeAll { $0.id == app.id }
        save()
    }

    func deleteSigned(_ app: SignedApp) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["expiry." + app.id.uuidString])
        try? SignPaths.fm.removeItem(at: ipaURL(app))
        Container.remove(app)
        signed.removeAll { $0.id == app.id }
        save()
    }

    func download(_ url: URL, name: String) async {
        let task = DownloadTask(name: name, progress: 0, status: L("Downloading"))
        downloads.append(task)
        let tid = task.id
        do {
            let file = try await Downloader.download(url) { f in
                Task { @MainActor in
                    if let i = SignAppState.shared.downloads.firstIndex(where: { $0.id == tid }) {
                        SignAppState.shared.downloads[i].progress = f
                    }
                }
            }
            downloads.removeAll { $0.id == tid }
            let ext = url.pathExtension.lowercased()
            let renamed = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + (ext == "tipa" ? "tipa" : "ipa"))
            try? SignPaths.fm.moveItem(at: file, to: renamed)
            await importIPA(renamed, source: url.host ?? "web")
            try? SignPaths.fm.removeItem(at: renamed)
        } catch {
            downloads.removeAll { $0.id == tid }
            show(error.localizedDescription)
        }
    }

    func handleOpen(_ url: URL) {
        if url.scheme == "nvdappleiddownload" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems ?? []
            if url.host == "udid", let v = q.first(where: { $0.name == "value" })?.value,
               v.range(of: "^[0-9A-Fa-f-]{20,50}$", options: .regularExpression) != nil {
                settings.udid = v.uppercased()
                NotificationCenter.default.post(name: .sayoUDID, object: settings.udid)
                show(L("UDID detected") + ": " + settings.udid)
            } else if url.host == "anisette", let s = q.first(where: { $0.name == "server" || $0.name == "url" })?.value, !s.isEmpty {
                settings.anisetteURL = s
                tab = 3
                show(L("Anisette server set") + ": " + s)
            } else if url.host == "source", let s = q.first(where: { $0.name == "url" })?.value {
                tab = 2
                Task { await self.addSource(s) }
            } else if url.host == "install", let s = q.first(where: { $0.name == "url" })?.value, let u = URL(string: s) {
                tab = 0
                Task { await self.download(u, name: u.lastPathComponent) }
            }
            return
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ipa", "tipa":
            tab = 0
            Task { await self.importIPA(url) }
        case "p12", "pfx", "mobileprovision":
            tab = 1
            CertificateImportCoordinator.shared.receive(url)
        case "deb", "dylib":
            let dst = SignPaths.tweaks.appendingPathComponent(url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            try? SignPaths.fm.removeItem(at: dst)
            try? SignPaths.fm.copyItem(at: url, to: dst)
            if scoped { url.stopAccessingSecurityScopedResource() }
            show(LF("Saved tweak %@", url.lastPathComponent))
        default:
            show(L("Unsupported file"))
        }
    }

    func addCertificate(p12: Data, profile: Data, password: String, nickname: String, fromAppleID: Bool = false) throws -> StoredCertificate {
        let identity = try SayoCore.importP12(p12, password: password)
        guard let pd = SayoCore.profileDetails(profile) else { throw SayoError(L("Invalid provisioning profile")) }
        let devCerts = SayoCore.profileCertificates(profile)
        if !devCerts.isEmpty && !devCerts.contains(identity.certificate) {
            throw SayoError(L("This profile was not made for this certificate"))
        }
        let id = UUID()
        let dir = SignPaths.certificates.appendingPathComponent(id.uuidString, isDirectory: true)
        try SignPaths.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try p12.write(to: dir.appendingPathComponent("cert.p12"))
        try profile.write(to: dir.appendingPathComponent("profile.mobileprovision"))
        SignKeychain.set(password, for: "p12." + id.uuidString)
        let cert = StoredCertificate(id: id, nickname: nickname.isEmpty ? identity.details.organization : nickname,
                                     details: identity.details, profile: pd, p12File: "cert.p12",
                                     profileFile: "profile.mobileprovision", added: Date(), ocsp: .unchecked,
                                     ocspChecked: nil, revokedAt: nil, fromAppleID: fromAppleID)
        certificates.append(cert)
        if settings.selectedCertificate == nil { settings.selectedCertificate = id }
        save()
        Task { await self.refreshOCSP(cert) }
        return cert
    }

    func deleteCertificate(_ c: StoredCertificate) {
        try? SignPaths.fm.removeItem(at: SignPaths.certificates.appendingPathComponent(c.id.uuidString))
        SignKeychain.delete("p12." + c.id.uuidString)
        SignKeychain.delete("appleid.session." + c.id.uuidString)
        SignKeychain.delete("appleid.password." + c.id.uuidString)
        if c.fromAppleID {
            if SignKeychain.get("appleid.keytag." + c.id.uuidString) != nil {
                // The Apple ID's shared key stays for the next sign-in (iLoader-style reuse).
                SignKeychain.delete("appleid.keytag." + c.id.uuidString)
            } else {
                SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: AppleAccount.keyTag(c.id)] as CFDictionary)
            }
        }
        certificates.removeAll { $0.id == c.id }
        if settings.selectedCertificate == c.id { settings.selectedCertificate = certificates.first?.id }
        save()
    }

    func certificateFiles(_ c: StoredCertificate) -> (p12: Data, profile: Data, password: String)? {
        let dir = SignPaths.certificates.appendingPathComponent(c.id.uuidString)
        guard let p = try? Data(contentsOf: dir.appendingPathComponent(c.p12File)),
              let m = try? Data(contentsOf: dir.appendingPathComponent(c.profileFile)) else { return nil }
        return (p, m, SignKeychain.get("p12." + c.id.uuidString) ?? "")
    }

    func identity(for c: StoredCertificate) throws -> Identity {
        if c.fromAppleID {
            let dir = SignPaths.certificates.appendingPathComponent(c.id.uuidString)
            guard let der = try? Data(contentsOf: dir.appendingPathComponent("cert.der")),
                  let key = LocalCA.key(tag: AppleAccount.keyTag(c.id)),
                  let details = SayoCore.certDetails(der) else { throw SayoError(L("Certificate files are missing")) }
            return Identity(key: key, certificate: der, details: details)
        }
        guard let files = certificateFiles(c) else { throw SayoError(L("Certificate files are missing")) }
        return try SayoCore.importP12(files.p12, password: files.password)
    }

    func refreshOCSP(_ c: StoredCertificate) async {
        guard let identity = try? identity(for: c) else { return }
        let (status, when) = await SayoCore.checkOCSP(identity.certificate)
        if let i = certificates.firstIndex(where: { $0.id == c.id }) {
            certificates[i].ocsp = status
            certificates[i].revokedAt = when
            certificates[i].ocspChecked = Date()
            save()
        }
    }

    func refreshAllOCSP() async {
        for c in certificates { await refreshOCSP(c) }
    }

    func addSource(_ raw: String) async {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { show(L("Invalid URL")); return }
        if sources.contains(where: { $0.url == url.absoluteString }) { show(L("Source already added")); return }
        busy = L("Loading source")
        defer { busy = nil }
        do {
            let src = try await RepoParser.fetch(url, id: UUID())
            sources.append(src)
            save()
            show(LF("Added %@", src.name))
        } catch {
            show(error.localizedDescription)
        }
    }

    func refreshSources() async {
        await withTaskGroup(of: RepoSource?.self) { group in
            for s in sources {
                group.addTask {
                    guard let u = URL(string: s.url) else { return nil }
                    return try? await RepoParser.fetch(u, id: s.id)
                }
            }
            for await r in group {
                if let r = r, let i = sources.firstIndex(where: { $0.id == r.id }) { sources[i] = r }
            }
        }
        save()
    }

    func performSign(app: LibraryApp, cert c: StoredCertificate, options: SayoCore.SignOptions, tweaks: [URL],
                     progress: @escaping @MainActor (Double, String) -> Void) async throws -> SignedApp {
        let src = appURL(app)
        let workRoot = SignPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = workRoot.appendingPathComponent("Payload", isDirectory: true)
        let appCopy = payload.appendingPathComponent(app.appFolder)
        var opts = options
        opts.compression = Int32(settings.compressionLevel)
        let compression = Int32(settings.compressionLevel)
        let appName = opts.displayName.isEmpty ? app.name : opts.displayName
        let certName = c.nickname
        let viaAppleID = c.fromAppleID
        let container = options.container
        let libID = app.id
        let ident = try self.identity(for: c)
        var profile: Data
        if c.fromAppleID {
            progress(0.02, L("Requesting profile from Apple"))
            let wanted = opts.bundleID.isEmpty ? app.bundleID : opts.bundleID
            let (p, finalID) = try await AppleAccount.profile(for: c, bundleID: wanted, name: appName, anisetteURL: settings.anisetteURL)
            profile = p
            opts.bundleID = finalID
            // A profile without this iPhone installs as "Unable to install, try later".
            let udid = settings.udid.trimmingCharacters(in: .whitespaces).uppercased()
            if let pd = SayoCore.profileDetails(p), !pd.allDevices, !udid.isEmpty,
               !pd.devices.contains(where: { $0.uppercased() == udid }) {
                throw SayoError(LF("Apple's profile does not include the UDID %@. Check the UDID in Certificates → Manage Apple ID account and sign in again with the right one.", udid))
            }
        } else {
            guard let files = certificateFiles(c) else { throw SayoError(L("Certificate files are missing")) }
            profile = files.profile
        }
        let finalOpts = opts
        let profileData = profile
        do {
            let result: SignedApp = try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: payload, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: appCopy)
                var o = finalOpts
                var temp: [URL] = []
                for t in tweaks {
                    if t.pathExtension.lowercased() == "deb" {
                        let d = workRoot.appendingPathComponent("deb-\(UUID().uuidString)")
                        temp.append(d)
                        o.injections += try SayoCore.extractDeb(t, to: d)
                    } else {
                        o.injections.append(t)
                    }
                }
                if !o.injections.isEmpty, let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("CydiaSubstrate.framework"),
                   fm.fileExists(atPath: fw.path) {
                    o.hookFramework = fw
                }
                if o.container {
                    // LiveContainer-style: the main executable becomes a dylib NVDAppleIDDownload can load.
                    let info = NSDictionary(contentsOf: appCopy.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
                    guard let exe = info["CFBundleExecutable"] as? String,
                          sayo_macho_make_dylib(appCopy.appendingPathComponent(exe).path) == 0 else {
                        throw SayoError.last("Cannot prepare the app to run inside NVDAppleIDDownload")
                    }
                }
                try SayoCore.signApp(app: appCopy, profile: profileData, identity: ident, options: o) { f, s in
                    Task { @MainActor in progress(f * 0.92, s) }
                }
                Task { @MainActor in progress(0.93, "zip") }
                let info = NSDictionary(contentsOf: appCopy.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
                let finalID = info["CFBundleIdentifier"] as? String ?? ""
                let finalVersion = info["CFBundleShortVersionString"] as? String ?? ""
                let finalName = (info["CFBundleDisplayName"] as? String) ?? appName
                let safe = finalName.replacingOccurrences(of: "/", with: "-")
                let fileName = "\(safe)_\(finalVersion)_\(UUID().uuidString.prefix(6)).ipa"
                let out = SignPaths.signed.appendingPathComponent(fileName)
                for t in temp { try? fm.removeItem(at: t) }
                try SayoCore.zip(workRoot, to: out, level: compression)
                try? fm.removeItem(at: workRoot)
                let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
                return SignedApp(id: UUID(), libraryID: libID, name: finalName, bundleID: finalID, version: finalVersion,
                                 certificateName: certName, signedAt: Date(), ipaFile: fileName, size: size,
                                 tweaks: tweaks.map { $0.lastPathComponent }, viaAppleID: viaAppleID,
                                 container: container ? true : nil)
            }.value
            signed.insert(result, at: 0)
            save()
            if result.viaAppleID == true { SignAppState.remindBeforeExpiry(result) }
            return result
        } catch {
            try? FileManager.default.removeItem(at: workRoot)
            throw error
        }
    }

    func scanInbox() async {
        let fm = SignPaths.fm
        let docs = SignPaths.documents
        guard let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else { return }
        var p12: URL?
        var profile: URL?
        for u in items {
            switch u.pathExtension.lowercased() {
            case "ipa", "tipa":
                let moved = SignPaths.work.appendingPathComponent(UUID().uuidString + "." + u.pathExtension)
                guard (try? fm.moveItem(at: u, to: moved)) != nil else { continue }
                await importIPA(moved, source: "Files")
                try? fm.removeItem(at: moved)
            case "deb", "dylib":
                let dst = SignPaths.tweaks.appendingPathComponent(u.lastPathComponent)
                try? fm.removeItem(at: dst)
                if (try? fm.moveItem(at: u, to: dst)) != nil { show(LF("Saved tweak %@", u.lastPathComponent)) }
            case "p12", "pfx":
                p12 = u
            case "mobileprovision":
                profile = u
            default:
                break
            }
        }
        if p12 != nil || profile != nil {
            let c = CertificateImportCoordinator.shared
            if let p = p12 {
                let dst = SignPaths.work.appendingPathComponent(p.lastPathComponent)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: p, to: dst)
                c.p12 = dst
            }
            if let m = profile {
                let dst = SignPaths.work.appendingPathComponent(m.lastPathComponent)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: m, to: dst)
                c.profile = dst
            }
            tab = 1
            c.presented = true
        }
    }

    func removeSource(_ s: RepoSource) {
        sources.removeAll { $0.id == s.id }
        save()
    }
}
#endif
