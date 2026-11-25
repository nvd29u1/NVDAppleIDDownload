//  VersionIconService.swift
//  NVDAppleIDDownload
//
//  Icon đúng từng phiên bản trong Lịch sử phiên bản (đợt 4, build 9 —
//  ý tưởng iPadn mục 6, viết lại sạch, KHÔNG copy code iPadn GPL-2.0).
//
//  Cách làm (không tải cả file IPA):
//  - Lấy URL tải có chữ ký của đúng version ID qua
//    StoreDownloadService.download() (đường tải sẵn có của app).
//  - Range-request 1: đọc 64 KB cuối file IPA → tìm End-of-Central-
//    Directory (PK\x05\x06) của ZIP → biết vị trí + kích thước Central
//    Directory.
//  - Range-request 2: đọc đúng Central Directory → tìm entry icon:
//    ưu tiên `AppIcon60x60@2x.png` ngay dưới `*.app/`, không có thì
//    `AppIcon*.png` lớn nhất ngay dưới `*.app/`.
//  - Range-request 3: đọc local header của entry đó → vị trí dữ liệu
//    nén; Range-request 4: đọc đúng dữ liệu nén rồi giải nén (stored
//    thì lấy thẳng, deflate thì inflate thuần Swift trong file này —
//    không thêm thư viện, không dùng `zlib` vì Swift trên Apple không
//    có module đó).
//  - Cache PNG theo version ID xuống đĩa (Documents/NVDAppleIDDownload/
//    VersionIcons/<versionID>.png); chỉ tải lười khi dòng hiện ra, 1
//    lần cho mỗi version ID trong 1 phiên chạy.
//  - Apple không phục vụ Range / không đọc được icon / giải nén lỗi thì
//    trả nil — màn Lịch sử hiện icon hiện tại, không crash, không bịa.
//  - Chỉ đọc PNG icon trong IPA đã tải về từ Apple, không giải mã
//    FairPlay, không trích gì khác.
//

import ApplePackage
import Foundation

enum VersionIconService {
    /// Thư mục cache icon theo version ID.
    private static var cacheDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("VersionIcons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let lock = NSLock()
    /// Version ID đang tải dở (để không tải trùng khi nhiều dòng hiện).
    private static var inFlight: Set<String> = []
    /// Version ID đã thử mà không lấy được icon trong phiên chạy này
    /// (để không tải lại mỗi lần cuộn).
    private static var failed: Set<String> = []

    /// PNG icon của 1 version ID (Data), hoặc nil khi không lấy được.
    /// Đọc cache đĩa trước; chưa có thì tải lười bằng Range-request.
    static func iconData(for versionID: String, package: AppStore.AppPackage, accountID: String, region: String) async -> Data? {
        let cacheFile = cacheDirectory.appendingPathComponent("\(versionID).png")
        if let cached = try? Data(contentsOf: cacheFile), isPNG(cached) {
            return cached
        }
        let shouldFetch = lock.locked { () -> Bool in
            guard !failed.contains(versionID) else { return false }
            guard inFlight.insert(versionID).inserted else { return false }
            return true
        }
        guard shouldFetch else { return nil }
        defer {
            _ = lock.locked { inFlight.remove(versionID) }
        }
        do {
            let signedURL = try await AppStore.this.withAccount(id: accountID) { account in
                let output = try await StoreDownloadService.download(account: &account.account, package: package, region: region)
                guard let url = URL(string: output.downloadURL) else {
                    throw NSError(domain: "NVDAppleIDDownload.VersionIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
                }
                return url
            }
            guard let png = try await fetchIconPNG(signedURL: signedURL) else {
                _ = lock.locked { failed.insert(versionID) }
                return nil
            }
            try? png.write(to: cacheFile, options: .atomic)
            logger.info("Version icon: cached icon for version \(versionID) (\(png.count) bytes)")
            return png
        } catch {
            logger.info("Version icon: no icon for version \(versionID): \(StoreDiagnostics.errorSummary(error))")
            _ = lock.locked { failed.insert(versionID) }
            return nil
        }
    }

    /// Đọc PNG icon từ file IPA qua các Range-request (xem ghi chú đầu
    /// file). Trả nil khi bất kỳ bước nào không làm được.
    private static func fetchIconPNG(signedURL: URL) async throws -> Data? {
        // 1. 64 KB cuối file → EOCD → vị trí Central Directory.
        guard let (tail, totalLength) = try await rangeData(url: signedURL, range: "-65536"),
              let totalLength,
              let eocd = findEndOfCentralDirectory(in: tail, totalLength: totalLength)
        else { return nil }
        // 2. Central Directory → entry icon.
        let cdStart = Int64(eocd.centralDirectoryOffset)
        let cdEnd = cdStart + Int64(eocd.centralDirectorySize) - 1
        guard cdEnd >= cdStart,
              let (cdData, _) = try await rangeData(url: signedURL, range: "\(cdStart)-\(cdEnd)"),
              let entry = pickIconEntry(in: cdData)
        else { return nil }
        // 3. Local header → vị trí dữ liệu nén của entry.
        guard let (localHeader, _) = try await rangeData(url: signedURL, range: "\(entry.localHeaderOffset)-\(entry.localHeaderOffset + 29)"),
              localHeader.count >= 30,
              le32(localHeader, 0) == 0x0403_4B50 // "PK\x03\x04"
        else { return nil }
        let fileNameLength = Int(le16(localHeader, 26))
        let extraLength = Int(le16(localHeader, 28))
        let dataStart = Int64(entry.localHeaderOffset) + 30 + Int64(fileNameLength) + Int64(extraLength)
        // 4. Dữ liệu nén → giải nén → PNG.
        guard entry.compressedSize > 0,
              let (compressed, _) = try await rangeData(url: signedURL, range: "\(dataStart)-\(dataStart + Int64(entry.compressedSize) - 1)"),
              compressed.count == Int(entry.compressedSize)
        else { return nil }
        let png: Data?
        switch entry.method {
        case 0: // stored — dữ liệu đã là PNG
            png = compressed
        case 8: // deflate — inflate thuần Swift
            png = ZipInflate.inflate(compressed)
        default:
            png = nil
        }
        guard let png, isPNG(png) else { return nil }
        return png
    }

    // MARK: - Range-request

    /// GET với header Range. Chỉ chấp nhận 206 (máy chủ hỗ trợ Range);
    /// 200 / lỗi khác thì trả nil — không tải cả file IPA về.
    /// Trả về (dữ liệu, tổng độ dài file từ Content-Range nếu có).
    private static func rangeData(url: URL, range: String) async throws -> (Data, Int64?)? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        request.setValue(ApplePackage.Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            logger.info("Version icon: Range request không được 206 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            return nil
        }
        var totalLength: Int64?
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/"),
           let total = Int64(contentRange[contentRange.index(after: slash)...])
        {
            totalLength = total
        }
        return (data, totalLength)
    }

    // MARK: - Parse ZIP

    private struct EndOfCentralDirectory {
        let centralDirectoryOffset: UInt32
        let centralDirectorySize: UInt32
    }

    private struct ZipEntry {
        let fileName: String
        let method: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    /// Tìm EOCD (PK\x05\x06) trong 64 KB cuối file. Lấy lần xuất hiện
    /// cuối cùng (comment trong ZIP có thể chứa dãy byte này).
    private static func findEndOfCentralDirectory(in tail: Data, totalLength: Int64) -> EndOfCentralDirectory? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if tail[tail.startIndex + index] == signature[0],
               tail[tail.startIndex + index + 1] == signature[1],
               tail[tail.startIndex + index + 2] == signature[2],
               tail[tail.startIndex + index + 3] == signature[3],
               index + 22 <= tail.count
            {
                let cdSize = le32(tail, index + 12)
                let cdOffset = le32(tail, index + 16)
                guard cdSize > 0, Int64(cdOffset) + Int64(cdSize) <= totalLength else { return nil }
                return EndOfCentralDirectory(centralDirectoryOffset: cdOffset, centralDirectorySize: cdSize)
            }
            index -= 1
        }
        return nil
    }

    /// Chọn entry icon trong Central Directory: file `AppIcon*.png`
    /// nằm ngay dưới 1 thư mục `*.app/` (không nằm trong PlugIns hay
    /// framework con). Ưu tiên `AppIcon60x60@2x.png`, không có thì
    /// `AppIcon*.png` có dung lượng chưa nén lớn nhất.
    private static func pickIconEntry(in centralDirectory: Data) -> ZipEntry? {
        var offset = 0
        var best: ZipEntry?
        var bestIsPreferred = false
        while offset + 46 <= centralDirectory.count {
            guard le32(centralDirectory, offset) == 0x0201_4B50 else { break }
            let method = le16(centralDirectory, offset + 10)
            let compressedSize = le32(centralDirectory, offset + 20)
            let uncompressedSize = le32(centralDirectory, offset + 24)
            let fileNameLength = Int(le16(centralDirectory, offset + 28))
            let extraLength = Int(le16(centralDirectory, offset + 30))
            let commentLength = Int(le16(centralDirectory, offset + 32))
            let localHeaderOffset = le32(centralDirectory, offset + 42)
            let nameStart = offset + 46
            guard nameStart + fileNameLength <= centralDirectory.count else { break }
            let fileName = String(data: centralDirectory[nameStart ..< nameStart + fileNameLength], encoding: .utf8) ?? ""
            offset = nameStart + fileNameLength + extraLength + commentLength
            guard isAppIconPath(fileName) else { continue }
            let entry = ZipEntry(
                fileName: fileName,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            let isPreferred = fileName.hasSuffix("AppIcon60x60@2x.png")
            if isPreferred {
                // Ưu tiên tuyệt đối: gặp là lấy luôn.
                return entry
            }
            if !bestIsPreferred, (best == nil || entry.uncompressedSize > best!.uncompressedSize) {
                best = entry
            }
        }
        return best
    }

    /// `Payload/Tên.app/AppIcon60x60@2x.png` → đúng; còn
    /// `Payload/Tên.app/PlugIns/X.appex/AppIcon.png` → sai (nằm sâu
    /// hơn 1 cấp dưới .app).
    private static func isAppIconPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "Payload" else { return false }
        guard parts[1].hasSuffix(".app") else { return false }
        guard parts.count == 3 else { return false }
        let fileName = String(parts[2])
        return fileName.hasPrefix("AppIcon") && fileName.hasSuffix(".png")
    }

    private static func isPNG(_ data: Data) -> Bool {
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= magic.count else { return false }
        return magic.enumerated().allSatisfy { data[data.startIndex + $0.offset] == $0.element }
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}

private extension NSLock {
    /// Chạy body trong lock rồi trả kết quả (tiện cho Set).
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Inflate thuần Swift (RFC 1951, DEFLATE)

// Giải nén dữ liệu deflate (không có wrapper zlib/gzip — dữ liệu trong
// ZIP là deflate trần). Tự viết từ mô tả format, ~200 dòng, không thêm
// thư viện: Swift trên Apple không có module `zlib`, còn Compression
// framework chỉ giải được zlib có header, không giải được deflate trần.
// Giới hạn đầu ra 4 MB (icon PNG không bao giờ lớn hơn thế) để chống
// zip bomb; lỗi ở bất kỳ đâu thì trả nil — caller hiện icon hiện tại.

private enum ZipInflate {
    private static let maxOutputSize = 4_000_000

    static func inflate(_ data: Data) -> Data? {
        var reader = BitReader(data: data)
        var output = Data()
        while true {
            guard let bfinal = reader.readBits(1), let btype = reader.readBits(2) else { return nil }
            switch btype {
            case 0:
                guard inflateStoredBlock(&reader, &output) else { return nil }
            case 1:
                guard inflateBlock(&reader, &output, literal: Huffman(lengths: fixedLiteralLengths), distance: Huffman(lengths: fixedDistanceLengths)) else { return nil }
            case 2:
                guard let tables = readDynamicTables(&reader) else { return nil }
                guard inflateBlock(&reader, &output, literal: tables.literal, distance: tables.distance) else { return nil }
            default:
                return nil
            }
            if output.count > maxOutputSize { return nil }
            if bfinal == 1 { return output }
        }
    }

    // MARK: Khối stored (không nén)

    private static func inflateStoredBlock(_ reader: inout BitReader, _ output: inout Data) -> Bool {
        reader.alignToByte()
        guard let header = reader.readBytes(4) else { return false }
        let length = Int(header[header.startIndex]) | (Int(header[header.startIndex + 1]) << 8)
        guard let chunk = reader.readBytes(length) else { return false }
        output.append(chunk)
        return true
    }

    // MARK: Khối nén (fixed / dynamic)

    private static func inflateBlock(_ reader: inout BitReader, _ output: inout Data, literal: Huffman, distance: Huffman) -> Bool {
        while true {
            guard let symbol = literal.decode(&reader) else { return false }
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return true
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < lengthBase.count else { return false }
                guard let extra = reader.readBits(lengthExtra[lengthIndex]) else { return false }
                let length = lengthBase[lengthIndex] + extra
                guard let distanceSymbol = distance.decode(&reader) else { return false }
                guard distanceSymbol < distanceBase.count else { return false }
                guard let distanceExtra = reader.readBits(distanceExtra[distanceSymbol]) else { return false }
                let distance = distanceBase[distanceSymbol] + distanceExtra
                guard distance > 0, distance <= output.count else { return false }
                guard output.count + length <= maxOutputSize else { return false }
                // Copy từng byte (cho phép trùng lặp — LZ77 copy có thể
                // đọc lại byte vừa ghi).
                for _ in 0 ..< length {
                    output.append(output[output.count - distance])
                }
            }
            if output.count > maxOutputSize { return false }
        }
    }

    // MARK: Bảng dynamic Huffman

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func readDynamicTables(_ reader: inout BitReader) -> (literal: Huffman, distance: Huffman)? {
        guard let hlit = reader.readBits(5),
              let hdist = reader.readBits(5),
              let hclen = reader.readBits(4)
        else { return nil }
        let literalCount = hlit + 257
        let distanceCount = hdist + 1
        let codeLengthCount = hclen + 4
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0 ..< codeLengthCount {
            guard let length = reader.readBits(3) else { return nil }
            codeLengths[codeLengthOrder[i]] = length
        }
        guard codeLengths.contains(where: { $0 > 0 }) else { return nil }
        let codeHuffman = Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            guard let symbol = codeHuffman.decode(&reader) else { return nil }
            switch symbol {
            case 0 ... 15:
                lengths.append(symbol)
            case 16:
                // Lặp lại độ dài trước đó 3–6 lần.
                guard let previous = lengths.last,
                      let extra = reader.readBits(2)
                else { return nil }
                lengths.append(contentsOf: [Int](repeating: previous, count: 3 + extra))
            case 17:
                guard let extra = reader.readBits(3) else { return nil }
                lengths.append(contentsOf: [Int](repeating: 0, count: 3 + extra))
            case 18:
                guard let extra = reader.readBits(7) else { return nil }
                lengths.append(contentsOf: [Int](repeating: 0, count: 11 + extra))
            default:
                return nil
            }
            guard lengths.count <= literalCount + distanceCount else { return nil }
        }
        let literalLengths = Array(lengths[0 ..< literalCount])
        var distanceLengths = Array(lengths[literalCount ..< literalCount + distanceCount])
        // Luồng chỉ có 1 mã distance (hoặc không có mã nào dùng được):
        // cho 1 mã giả độ dài 1 để bảng giải mã không rỗng — khối đó
        // không bao giờ dùng tới mã distance này.
        if distanceLengths.allSatisfy({ $0 == 0 }) {
            distanceLengths = [1] + [Int](repeating: 0, count: max(0, distanceCount - 1))
        }
        return (Huffman(lengths: literalLengths), Huffman(lengths: distanceLengths))
    }

    // MARK: Bảng cố định (RFC 1951 §3.2.6)

    private static var fixedLiteralLengths: [Int] {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0 ..< 144 { lengths[i] = 8 }
        for i in 144 ..< 256 { lengths[i] = 9 }
        for i in 256 ..< 280 { lengths[i] = 7 }
        for i in 280 ..< 288 { lengths[i] = 8 }
        return lengths
    }

    private static var fixedDistanceLengths: [Int] {
        [Int](repeating: 5, count: 30)
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 157, 183, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
}

/// Đọc bit LSB-first (DEFLATE đọc bit từ thấp tới cao trong mỗi byte).
private struct BitReader {
    let data: Data
    var bitPos: Int = 0

    mutating func readBit() -> Int? {
        guard bitPos / 8 < data.count else { return nil }
        let byte = data[data.startIndex + bitPos / 8]
        let bit = (byte >> (bitPos % 8)) & 1
        bitPos += 1
        return Int(bit)
    }

    mutating func readBits(_ count: Int) -> Int? {
        var value = 0
        for i in 0 ..< count {
            guard let bit = readBit() else { return nil }
            value |= bit << i
        }
        return value
    }

    mutating func alignToByte() {
        bitPos = ((bitPos + 7) / 8) * 8
    }

    mutating func readBytes(_ count: Int) -> Data? {
        alignToByte()
        let start = bitPos / 8
        guard count >= 0, start + count <= data.count else { return nil }
        let sub = data[data.startIndex + start ..< data.startIndex + start + count]
        bitPos += count * 8
        return Data(sub)
    }
}

/// Mã Huffman chuẩn (canonical) theo độ dài mã: giải mã bằng cách đọc
/// từng bit rồi tra bảng đếm theo độ dài (thuật toán trong RFC 1951).
private struct Huffman {
    /// counts[len] = số mã có độ dài len (len 1...15).
    let counts: [Int]
    /// Các ký tự xếp theo (độ dài mã, thứ tự ký tự).
    let symbols: [Int]

    init(lengths: [Int]) {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 {
            counts[length] += 1
        }
        self.counts = counts
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1 ..< 16 {
            offsets[length] = offsets[length - 1] + counts[length - 1]
        }
        var symbols = [Int](repeating: 0, count: lengths.filter { $0 > 0 }.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
        self.symbols = symbols
    }

    func decode(_ reader: inout BitReader) -> Int? {
        var code = 0
        var first = 0
        var index = 0
        for length in 1 ..< 16 {
            guard let bit = reader.readBit() else { return nil }
            code |= bit
            let count = counts[length]
            if code - count < first {
                return symbols[index + (code - first)]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        return nil
    }
}
