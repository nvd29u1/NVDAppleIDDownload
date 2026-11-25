#if os(iOS)
import Foundation
import Security
import UIKit

enum SignKeychain {
    static let service = "com.NVD.appleiddownload.sign"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, UIImage>()

    func icon(appDir: URL, key: String) -> UIImage? {
        if let c = cache.object(forKey: key as NSString) { return c }
        guard let img = IconCache.find(appDir) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }

    static func find(_ appDir: URL) -> UIImage? {
        let info = NSDictionary(contentsOf: appDir.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        var names: [String] = []
        for k in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[k] as? [String: Any], let prim = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += prim["CFBundleIconFiles"] as? [String] ?? []
                if let n = prim["CFBundleIconName"] as? String { names.append(n) }
            }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let f = info["CFBundleIconFile"] as? String { names.append(f) }
        names.append("AppIcon")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: appDir.path)) ?? []
        var best: (UIImage, CGFloat)?
        for n in names {
            let base = n.replacingOccurrences(of: ".png", with: "")
            for f in files where f.hasPrefix(base) && f.lowercased().hasSuffix(".png") {
                if let img = UIImage(contentsOfFile: appDir.appendingPathComponent(f).path) {
                    let s = img.size.width * img.scale
                    if best == nil || s > best!.1 { best = (img, s) }
                }
            }
        }
        return best?.0
    }
}

final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: (Double) -> Void
    private var session: URLSession!

    private init(progress: @escaping (Double) -> Void) {
        self.progress = progress
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    static func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            var req = URLRequest(url: url)
            req.setValue("NVDAppleIDDownload/2.0", forHTTPHeaderField: "User-Agent")
            d.session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: SayoError("HTTP \(http.statusCode)"))
            continuation = nil
            return
        }
        let dst = SignPaths.work.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            continuation?.resume(returning: dst)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            continuation?.resume(throwing: e)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}

enum RepoParser {
    static func fetch(_ url: URL, id: UUID) async throws -> RepoSource {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("NVDAppleIDDownload/2.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw SayoError("HTTP \(h.statusCode)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw SayoError(L("This source is not valid JSON")) }
        return parse(json, url: url, id: id)
    }

    static func str(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
        }
        return ""
    }

    static func int(_ d: [String: Any], _ keys: [String]) -> Int64 {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.int64Value }
            if let s = d[k] as? String, let v = Int64(s) { return v }
        }
        return 0
    }

    static func parse(_ json: Any, url: URL, id: UUID) -> RepoSource {
        var root: [String: Any] = [:]
        var appsRaw: [[String: Any]] = []
        if let d = json as? [String: Any] {
            root = d
            if let a = d["apps"] as? [[String: Any]] { appsRaw = a }
            else if let a = d["Apps"] as? [[String: Any]] { appsRaw = a }
            else {
                for (k, v) in d where k != "META" {
                    if let a = v as? [[String: Any]] { appsRaw += a }
                }
            }
        } else if let a = json as? [[String: Any]] {
            appsRaw = a
        }
        let meta = root["META"] as? [String: Any] ?? [:]
        let name = str(root, ["name", "Name"]).isEmpty ? (str(meta, ["repoName", "name"]).isEmpty ? (url.host ?? "Source") : str(meta, ["repoName", "name"])) : str(root, ["name", "Name"])
        var apps: [RepoApp] = []
        for a in appsRaw {
            let versions = a["versions"] as? [[String: Any]] ?? []
            let latest = versions.first ?? [:]
            var download = str(latest, ["downloadURL", "down"])
            if download.isEmpty { download = str(a, ["downloadURL", "down", "download", "url", "link"]) }
            if download.isEmpty { continue }
            var version = str(latest, ["version"])
            if version.isEmpty { version = str(a, ["version", "Version"]) }
            var date = str(latest, ["date"])
            if date.isEmpty { date = str(a, ["versionDate", "date"]) }
            var desc = str(a, ["localizedDescription", "description", "versionDescription", "subtitle"])
            if desc.isEmpty { desc = str(latest, ["localizedDescription"]) }
            var size = int(latest, ["size"])
            if size == 0 { size = int(a, ["size"]) }
            let shots = (a["screenshotURLs"] as? [String]) ?? ((a["screenshots"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["imageURL"] as? String) } ?? [])
            apps.append(RepoApp(sourceID: id, name: str(a, ["name", "Name"]),
                                bundleID: str(a, ["bundleIdentifier", "bundleID", "bundleId"]),
                                developer: str(a, ["developerName", "dev", "developer"]),
                                subtitle: str(a, ["subtitle"]), description: desc,
                                iconURL: str(a, ["iconURL", "icon", "iconUrl"]),
                                version: version, date: date, downloadURL: download, size: size,
                                tint: a["tintColor"] as? String, screenshots: shots))
        }
        return RepoSource(id: id, url: url.absoluteString, name: name, iconURL: str(root, ["iconURL", "icon"]),
                          lastRefresh: Date(), apps: apps)
    }
}

final class CertificateImportCoordinator: ObservableObject {
    static let shared = CertificateImportCoordinator()
    @Published var p12: URL?
    @Published var profile: URL?
    @Published var presented = false

    func receive(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let dst = SignPaths.work.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: url, to: dst)
        if scoped { url.stopAccessingSecurityScopedResource() }
        DispatchQueue.main.async {
            if url.pathExtension.lowercased() == "mobileprovision" { self.profile = dst } else { self.p12 = dst }
            self.presented = true
        }
    }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
#endif
