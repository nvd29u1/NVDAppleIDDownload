#if os(iOS)
import Foundation
import SwiftUI

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

struct LibraryApp: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minOS: String
    var size: Int64
    var added: Date
    var source: String
    var appFolder: String
    var hasPlugins: Bool
    var encrypted: Bool
}

struct SignedApp: Codable, Identifiable, Hashable {
    var id: UUID
    var libraryID: UUID?
    var name: String
    var bundleID: String
    var version: String
    var certificateName: String
    var signedAt: Date
    var ipaFile: String
    var size: Int64
    var tweaks: [String]
    /// Signed with an Apple ID certificate (free profiles need the pairing install path).
    var viaAppleID: Bool? = nil
    /// Prepared to run inside NVDAppleIDDownload (LiveContainer-style), not to be installed.
    var container: Bool? = nil
}

struct StoredCertificate: Codable, Identifiable, Hashable {
    var id: UUID
    var nickname: String
    var details: CertDetails
    var profile: ProfileDetails
    var p12File: String
    var profileFile: String
    var added: Date
    var ocsp: OCSPStatus
    var ocspChecked: Date?
    var revokedAt: Date?
    var fromAppleID: Bool

    var expires: Date { min(details.notAfter, profile.expiration) }
    var daysLeft: Int { max(0, Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0) }
    var isExpired: Bool { expires < Date() }
}

struct RepoSource: Codable, Identifiable, Hashable {
    var id: UUID
    var url: String
    var name: String
    var iconURL: String?
    var lastRefresh: Date?
    var apps: [RepoApp]
}

struct RepoApp: Codable, Identifiable, Hashable {
    var id: String { sourceID.uuidString + "|" + bundleID + "|" + version + "|" + downloadURL }
    var sourceID: UUID
    var name: String
    var bundleID: String
    var developer: String
    var subtitle: String
    var description: String
    var iconURL: String
    var version: String
    var date: String
    var downloadURL: String
    var size: Int64
    var tint: String?
    var screenshots: [String]
}

struct AppSettings: Codable, Equatable {
    var selectedCertificate: UUID?
    var compressionLevel: Int = 1
    var autoRemovePlugins = false
    var removeWatchApps = true
    var deleteAfterInstall = false
    var serverPort: Int = 47616
    var anisetteURL = Anisette.defaultServer
    var bundleSuffix = ""
    var keepAliveAudio = true
    var udid = ""
    var appleIDTeam = ""
    /// 0 = follow the system, 1 = light, 2 = black.
    var appearance = 0
    /// No manifest service here on purpose (merged app, build 10): the sign
    /// installer uses the app's own setting AppStore.manifestServerURL, so
    /// there is exactly one manifest server setting (Cài đặt → Install App).
    /// 0 = automatic (pairing for Apple ID apps when paired), 1 = over the air, 2 = pairing.
    var installMethod = 0
    /// LocalDevVPN's address of this iPhone.
    var tunnelAddress = "10.7.0.1"

    init() {}

    // Decoding field by field keeps older saved settings (and the whole library) readable
    // when new fields are added, instead of failing and resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedCertificate = (try? c.decodeIfPresent(UUID.self, forKey: .selectedCertificate)) ?? nil
        compressionLevel = (try? c.decodeIfPresent(Int.self, forKey: .compressionLevel)) ?? d.compressionLevel
        autoRemovePlugins = (try? c.decodeIfPresent(Bool.self, forKey: .autoRemovePlugins)) ?? d.autoRemovePlugins
        removeWatchApps = (try? c.decodeIfPresent(Bool.self, forKey: .removeWatchApps)) ?? d.removeWatchApps
        deleteAfterInstall = (try? c.decodeIfPresent(Bool.self, forKey: .deleteAfterInstall)) ?? d.deleteAfterInstall
        serverPort = (try? c.decodeIfPresent(Int.self, forKey: .serverPort)) ?? d.serverPort
        anisetteURL = (try? c.decodeIfPresent(String.self, forKey: .anisetteURL)) ?? d.anisetteURL
        bundleSuffix = (try? c.decodeIfPresent(String.self, forKey: .bundleSuffix)) ?? d.bundleSuffix
        keepAliveAudio = (try? c.decodeIfPresent(Bool.self, forKey: .keepAliveAudio)) ?? d.keepAliveAudio
        udid = (try? c.decodeIfPresent(String.self, forKey: .udid)) ?? d.udid
        appleIDTeam = (try? c.decodeIfPresent(String.self, forKey: .appleIDTeam)) ?? d.appleIDTeam
        appearance = (try? c.decodeIfPresent(Int.self, forKey: .appearance)) ?? d.appearance
        installMethod = (try? c.decodeIfPresent(Int.self, forKey: .installMethod)) ?? d.installMethod
        tunnelAddress = (try? c.decodeIfPresent(String.self, forKey: .tunnelAddress)) ?? d.tunnelAddress
        // Servers Apple now rejects are switched to a working one.
        if Anisette.rejectedServers.contains(anisetteURL) || anisetteURL.trimmingCharacters(in: .whitespaces).isEmpty {
            anisetteURL = Anisette.defaultServer
        }
    }
}

struct DownloadTask: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var progress: Double
    var status: String
}
#endif
