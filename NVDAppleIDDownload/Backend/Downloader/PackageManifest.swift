//
//  PackageManifest.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import Foundation

private let packagesDir = {
    let ret = documentsDirectory.appendingPathComponent("Packages")
    try? FileManager.default.createDirectory(at: ret, withIntermediateDirectories: true)
    return ret
}()

class PackageManifest: Identifiable, Codable, Hashable, Equatable, ObservableObject {
    private(set) var id: UUID = .init()

    private(set) var account: AppStore.UserAccount
    private(set) var package: AppStore.AppPackage

    private(set) var url: URL
    private(set) var signatures: [ApplePackage.Sinf]
    private(set) var iTunesMetadata: Data

    private(set) var creation: Date

    @Published var state: PackageState = .init()

    /// "Giữ phiên bản này" (đợt 3, build 8 — ý tưởng iPadn mục 6): app
    /// đã tải xong mà người dùng giữ phiên bản này thì tab Lượt tải
    /// không nhắc "Có bản mới" nữa, kể cả khi Store đã có bản mới hơn.
    /// Bật/tắt ở màn chi tiết gói đã tải và ở từng dòng trong tab Lượt
    /// tải; lưu cùng manifest nên thoát app vẫn nhớ.
    @Published var pinned: Bool = false

    /// Dữ liệu nối tiếp tải nền (đợt 4, build 9 — URLSession background):
    /// tạm dừng bằng cancel(byProducingResumeData:) thì hệ thống trả
    /// resumeData, lưu ở đây để lần tiếp tục dùng
    /// downloadTask(withResumeData:). Nil = chưa từng tạm dừng / đã tải
    /// xong / resumeData hỏng đã bị xoá. Manifest cũ không có trường
    /// này thì mặc định nil.
    @Published var resumeData: Data? = nil

    var targetLocation: URL {
        packagesDir
            .appendingPathComponent(package.software.bundleID)
            .appendingPathComponent(package.software.version)
            .appendingPathComponent("\(id.uuidString)")
            .appendingPathExtension("ipa")
    }

    var completed: Bool {
        state.status == .completed
    }

    func waitForCompletion(timeout: TimeInterval? = nil) async {
        let start = Date().timeIntervalSince1970
        while true {
            if let timeout, Date().timeIntervalSince1970 - start > timeout {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(5e8))
            // .paused is terminal for waiters: a user-paused download will not
            // progress on its own, so the update flow must not spin forever.
            if [.failed, .completed, .paused].contains(state.status) {
                return
            }
        }
    }

    init(account: AppStore.UserAccount, package: AppStore.AppPackage, downloadOutput: ApplePackage.DownloadOutput) throws {
        self.account = account
        self.package = package
        guard let url = URL(string: downloadOutput.downloadURL) else {
            throw NSError(
                domain: "NVDAppleIDDownload.Download",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid download URL: \(downloadOutput.downloadURL)"],
            )
        }
        self.url = url
        signatures = downloadOutput.sinfs
        iTunesMetadata = downloadOutput.iTunesMetadata
        creation = .init()
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        account = try container.decode(AppStore.UserAccount.self, forKey: .account)
        package = try container.decode(AppStore.AppPackage.self, forKey: .package)
        url = try container.decode(URL.self, forKey: .url)
        signatures = try container.decode([ApplePackage.Sinf].self, forKey: .signatures)
        iTunesMetadata = try container.decodeIfPresent(Data.self, forKey: .iTunesMetadata) ?? Data()
        creation = try container.decode(Date.self, forKey: .creation)
        state = try container.decode(PackageState.self, forKey: .runtime)
        // Manifest cũ (trước build 8) chưa có cờ này — mặc định không giữ.
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // Manifest cũ (trước build 9) chưa có resumeData — mặc định nil.
        resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
    }

    /// Link CDN hết hạn (403/410, đợt 4 build 9): lấy URL có chữ ký mới
    /// + SINF/metadata mới từ StoreDownloadService rồi thay vào
    /// manifest để tải lại bằng URL mới. ResumeData cũ gắn với URL cũ
    /// nên phải xoá cùng lúc (caller tự xoá).
    func refreshDownloadOutput(_ output: ApplePackage.DownloadOutput) throws {
        guard let newURL = URL(string: output.downloadURL) else {
            throw NSError(
                domain: "NVDAppleIDDownload.Download",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid download URL: \(output.downloadURL)"],
            )
        }
        url = newURL
        signatures = output.sinfs
        iTunesMetadata = output.iTunesMetadata
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(account, forKey: .account)
        try container.encode(package, forKey: .package)
        try container.encode(url, forKey: .url)
        try container.encode(signatures, forKey: .signatures)
        try container.encode(iTunesMetadata, forKey: .iTunesMetadata)
        try container.encode(creation, forKey: .creation)
        try container.encode(state, forKey: .runtime)
        try container.encode(pinned, forKey: .pinned)
        try container.encodeIfPresent(resumeData, forKey: .resumeData)
    }

    private enum CodingKeys: String, CodingKey {
        case id, account, package, url, signatures, iTunesMetadata, creation, runtime, pinned, resumeData
    }

    /// Identity is the immutable UUID; hashing mutable fields like `state` would
    /// change a manifest's hash mid-download and break Set/Dictionary lookups.
    static func == (lhs: PackageManifest, rhs: PackageManifest) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension PackageManifest {
    func delete() {
        try? FileManager.default.removeItem(at: targetLocation)
        var cleanUpDir = targetLocation.deletingLastPathComponent()
        do {
            while FileManager.default.fileExists(atPath: cleanUpDir.path),
                  try FileManager.default.contentsOfDirectory(atPath: cleanUpDir.path).isEmpty,
                  cleanUpDir.path != packagesDir.path,
                  cleanUpDir.path.count > packagesDir.path.count,
                  cleanUpDir.path.contains(packagesDir.path)
            {
                try? FileManager.default.removeItem(at: cleanUpDir)
                cleanUpDir.deleteLastPathComponent()
            }
        } catch {}
    }
}
