#if os(iOS)
import Foundation

/// Tài nguyên local tối thiểu cho lõi iPadn port sang (thay
/// LocalResources của iPadn): chỉ còn cache file versions.json của
/// VersionService (nguồn phiên bản bên thứ ba — app chưa dùng tới nên
/// file này thường không bao giờ được tạo). Thư mục hỗ trợ dùng chung
/// Application Support/NVDAppleIDDownload của app.
enum IPadnLocalResources {
    static let versionsFilename = "versions.json"

    static let support: URL = prepared(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVDAppleIDDownload", isDirectory: true))

    private static func prepared(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, filename: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: support.appendingPathComponent(filename), options: .atomic)
    }
}
#endif
