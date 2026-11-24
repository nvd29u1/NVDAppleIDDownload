//
//  Downloads+UI.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import Foundation
import SwiftUI

enum DownloadAction: Hashable {
    case suspend
    case resume
    case restart
    case delete
    case exportIPA
}

@MainActor
extension Downloads {
    func performDownloadAction(for request: PackageManifest, action: DownloadAction) {
        switch action {
        case .suspend:
            suspend(request: request)
        case .resume:
            resume(request: request)
        case .restart:
            restart(request: request)
        case .delete:
            delete(request: request)
        case .exportIPA:
            // Chỉ mở Share Sheet khi file IPA còn trên máy; nếu file đã mất
            // thì nút này đã không được đưa vào danh sách hành động.
            _ = IPAExport.share(manifest: request)
        }
    }

    func getAvailableActions(for request: PackageManifest) -> [DownloadAction] {
        switch request.state.status {
        case .pending, .downloading:
            [.suspend, .delete]
        case .paused:
            [.resume, .delete]
        case .failed:
            [.restart, .delete]
        case .completed:
            // Không còn file IPA trên máy thì chỉ còn Xoá — nút xuất file
            // mờ đi / không hiện thay vì mở Share Sheet rồi lỗi.
            IPAExport.isAvailable(for: request) ? [.exportIPA, .delete] : [.delete]
        }
    }

    func getActionLabel(for action: DownloadAction) -> (title: String, systemImage: String, isDestructive: Bool) {
        switch action {
        case .suspend:
            (String(localized: "Pause"), "stop.fill", false)
        case .resume:
            (String(localized: "Resume"), "play.fill", false)
        case .restart:
            (String(localized: "Restart Download"), "arrow.clockwise", false)
        case .delete:
            (String(localized: "Delete"), "trash", true)
        case .exportIPA:
            (String(localized: "Tải IPA về máy"), "square.and.arrow.down", false)
        }
    }
}

extension Downloads {
    func startDownload(for package: AppStore.AppPackage, accountID: String) async throws {
        try await AppStore.this.withAccount(id: accountID) { account in
            let downloadOutput = try await StoreDownloadService.download(account: &account.account, package: package)
            let request = try Downloads.this.add(request: .init(
                account: account,
                package: package,
                downloadOutput: downloadOutput,
            ))
            Downloads.this.resume(request: request)
        }
    }
}
