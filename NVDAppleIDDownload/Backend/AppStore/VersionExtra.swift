//  VersionExtra.swift
//  NVDAppleIDDownload
//
//  Thông tin giàu thêm cho một phiên bản trong Lịch sử phiên bản
//  (đợt 3, build 8 — ý tưởng iPadn mục 6, viết lại sạch).
//
//  ApplePackage.VersionMetadata chỉ có số version + ngày phát hành nên
//  dung lượng IPA + ghi chú cập nhật giữ ở đây, theo từng version ID,
//  lưu cùng kho Persist với danh sách phiên bản. Apple không phải lúc
//  nào cũng trả hai trường này trong metadata tải (xem
//  StoreDownloadService.versionExtra): có thì hiện, không có thì màn
//  Lịch sử hiện "—" thay vì bịa số. Riêng phiên bản mới nhất được tra
//  thêm qua iTunes Lookup công khai (không cần đăng nhập) để lấy
//  fileSizeBytes + releaseNotes của bản hiện tại.
//

import Foundation

/// Dung lượng + ghi chú cập nhật của một phiên bản (cả hai đều có thể
/// vắng — Apple không trả thì để nil, UI hiện "—").
struct VersionExtra: Codable, Hashable {
    var fileSizeBytes: Int64?
    var releaseNotes: String?

    var isEmpty: Bool {
        fileSizeBytes == nil && (releaseNotes ?? "").isEmpty
    }
}
