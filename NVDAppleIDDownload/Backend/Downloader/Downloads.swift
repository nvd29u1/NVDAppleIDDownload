
//
//  Downloads.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
@preconcurrency import Digger
import Foundation
import Logging
#if canImport(UIKit)
    import UIKit
#endif

@Observable
@MainActor
class Downloads {
    static let this = Downloads()

    @ObservationIgnored
    private var _manifests = Persist<[PackageManifest]>(key: "DownloadRequests", defaultValue: [])

    @ObservationIgnored
    private var lastProgressUpdates: [UUID: CFAbsoluteTime] = [:]

    /// Manifest IDs whose Digger callbacks are already attached, so a
    /// pause/resume cycle does not register a second completion handler (which
    /// would run finalize() twice and destroy the downloaded bytes).
    @ObservationIgnored
    private var registeredCallbacks: Set<UUID> = []

    /// Installer đang giữ cho các lần "tải xong tự cài đặt" (đợt 4,
    /// build 9): Installer phải còn sống thì máy chủ Vapor mới còn phục
    /// vụ file IPA cho itms-services; xoá manifest thì huỷ kèm.
    @ObservationIgnored
    private var autoInstallers: [UUID: Installer] = [:]

    private static let speedFormatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = .useAll
        fmt.countStyle = .file
        return fmt
    }()

    var manifests: [PackageManifest] {
        get {
            access(keyPath: \.manifests)
            return _manifests.wrappedValue
        }
        set {
            withMutation(keyPath: \.manifests) {
                _manifests.wrappedValue = newValue
            }
        }
    }

    /// Stored, not computed: a computed property would read each manifest's
    /// `state`, so every download progress tick would invalidate the badge,
    /// sidebar, and AppDelegate observers and re-render the whole TabView.
    /// Refresh it only when a status actually transitions.
    private(set) var runningTaskCount: Int = 0

    private func refreshRunningTaskCount() {
        runningTaskCount = manifests.count(where: { $0.state.status == .downloading })
    }

    private init() {
        for idx in manifests.indices {
            manifests[idx].state.resetIfNotCompleted()
        }
        refreshRunningTaskCount()
        // Nối lại các task nền hệ thống vẫn giữ sau khi app bị tắt
        // (đợt 4, build 9): task nào còn chạy thì reattachBackgroundTask
        // đưa manifest về trạng thái đang tải; task nào đã xong thì hệ
        // thống giao file qua delegate ngay sau đó.
        BackgroundDownloadService.shared.reattach()
    }

    func saveManifests() {
        _manifests.save()
    }

    /// Bật/tắt "Giữ phiên bản này" cho 1 gói đã tải xong (đợt 3, build 8)
    /// rồi lưu manifest ngay để thoát app vẫn nhớ.
    func setPinned(_ manifest: PackageManifest, _ pinned: Bool) {
        manifest.pinned = pinned
        saveManifests()
    }

    func downloadRequest(forArchive archive: AppStore.AppPackage) -> PackageManifest? {
        manifests.first { $0.package.id == archive.id && $0.package.externalVersionID == archive.externalVersionID }
    }

    func add(request: PackageManifest) -> PackageManifest {
        logger.info("adding download request \(request.id) - \(request.package.software.name)")
        manifests.removeAll { $0.id == request.id }
        manifests.append(request)
        return request
    }

    /// Tạm dừng (đợt 4, build 9 — tải nền thật, không mất tiến độ):
    /// có task nền đang chạy thì cancel(byProducingResumeData:) để lấy
    /// resumeData, lần tiếp tục sẽ nối tiếp đúng chỗ đã dừng; không có
    /// task nền (đang chạy bằng Digger dự phòng) thì dừng theo đường
    /// Digger cũ — trường hợp này vẫn mất tiến độ như trước, xem ghi
    /// chú ở resume().
    func suspend(request: PackageManifest) {
        logger.info("suspending download request id: \(request.id)")
        BackgroundDownloadService.shared.suspendDownload(manifestID: request.id) { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData {
                    request.resumeData = resumeData
                    var newState = request.state
                    newState.status = .paused
                    newState.speed = ""
                    request.state = newState
                    logger.info("suspended download \(request.id) with resumeData (\(resumeData.count) bytes)")
                } else {
                    DiggerManager.shared.stopTask(for: request.url)
                    request.state.resetIfNotCompleted()
                }
                self.refreshRunningTaskCount()
                self.saveManifests()
            }
        }
    }

    /// Tiếp tục tải (đợt 4, build 9): ưu tiên nối tiếp bằng resumeData
    /// qua URLSession background; chưa từng tạm dừng thì tải mới cũng
    /// bằng background; chỉ khi không tạo được background task mới dùng
    /// Digger làm đường dự phòng (đường cũ, tạm dừng là mất tiến độ).
    func resume(request: PackageManifest) {
        logger.info("resuming download request id: \(request.id)")
        request.state.start()
        // Task nền vẫn còn sau khi mở lại app (reattach): chỉ cần đưa
        // trạng thái về đang tải, không tạo task mới.
        if BackgroundDownloadService.shared.hasTask(for: request.id) {
            var newState = request.state
            newState.status = .downloading
            request.state = newState
            refreshRunningTaskCount()
            saveManifests()
            return
        }
        if let resumeData = request.resumeData {
            if BackgroundDownloadService.shared.resumeWithResumeData(manifestID: request.id, resumeData: resumeData) {
                request.resumeData = nil
                var newState = request.state
                newState.status = .downloading
                request.state = newState
                refreshRunningTaskCount()
                saveManifests()
                return
            }
            // ResumeData hỏng: xoá rồi tải mới, không crash.
            request.resumeData = nil
        }
        if BackgroundDownloadService.shared.startDownload(manifestID: request.id, url: request.url) {
            var newState = request.state
            newState.status = .downloading
            request.state = newState
            refreshRunningTaskCount()
            saveManifests()
            return
        }
        resumeViaDigger(request: request)
    }

    /// Đường tải cũ bằng Digger — chỉ là dự phòng khi không tạo được
    /// background task. Tạm dừng ở đường này vẫn mất tiến độ (Digger
    /// không có resumeData), xem suspend().
    private func resumeViaDigger(request: PackageManifest) {
        logger.info("resuming download \(request.id) via Digger fallback")
        let seed = DiggerManager.shared.download(with: request.url)

        // Only attach callbacks once per manifest; a pause/resume cycle reuses
        // the existing Digger seed and must not stack a second completion.
        guard registeredCallbacks.insert(request.id).inserted else {
            DiggerManager.shared.startTask(for: request.url)
            saveManifests()
            return
        }

        seed
            .speed { speedBytes in
                Task { @MainActor in
                    guard request.state.status == .downloading || request.state.status == .pending else { return }
                    let wasDownloading = request.state.status == .downloading
                    var newState = request.state
                    newState.status = .downloading
                    newState.speed = Self.speedFormatter.string(fromByteCount: Int64(speedBytes))
                    request.state = newState
                    if !wasDownloading {
                        self.refreshRunningTaskCount()
                    }
                }
            }
            .progress { progress in
                Task { @MainActor in
                    guard request.state.status == .downloading || request.state.status == .pending else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    let fraction = progress.fractionCompleted
                    let last = self.lastProgressUpdates[request.id] ?? 0
                    guard fraction >= 1.0 || (now - last) >= 0.2 else { return }
                    self.lastProgressUpdates[request.id] = now

                    let wasDownloading = request.state.status == .downloading
                    var newState = request.state
                    newState.status = .downloading
                    newState.percent = fraction
                    request.state = newState
                    if !wasDownloading {
                        self.refreshRunningTaskCount()
                    }
                }
            }
            .completion { completion in
                Task { @MainActor in
                    self.registeredCallbacks.remove(request.id)
                    switch completion {
                    case let .success(url):
                        self.completeDownload(manifest: request, downloadedFile: url)
                    case let .failure(error):
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                            // User-initiated cancellation via cancelTask(), not an error
                        } else if error is CancellationError {
                            // Swift structured concurrency cancellation
                        } else {
                            request.state.error = error.localizedDescription
                            self.saveManifests()
                        }
                        self.refreshRunningTaskCount()
                    }
                }
            }
        DiggerManager.shared.startTask(for: request.url)
        saveManifests()
    }

    /// Chèn chữ ký vào file vừa tải xong rồi đánh dấu hoàn thành — dùng
    /// chung cho cả đường Digger lẫn đường background (tránh chạy
    /// finalize() 2 lần làm mất file).
    private func completeDownload(manifest: PackageManifest, downloadedFile: URL) {
        Task.detached {
            do {
                try await self.finalize(manifest: manifest, preparedContentAt: downloadedFile)
                await MainActor.run {
                    manifest.state.complete()
                    self.refreshRunningTaskCount()
                    self.saveManifests()
                    self.maybeAutoInstall(manifest: manifest)
                }
            } catch {
                await MainActor.run {
                    manifest.state.error = error.localizedDescription
                    self.refreshRunningTaskCount()
                    self.saveManifests()
                }
            }
        }
    }

    // MARK: - Sự kiện tải nền (BackgroundDownloadService gọi về)

    /// Task nền vẫn chạy sau khi mở lại app: đưa manifest về đang tải.
    func reattachBackgroundTask(manifestID: UUID) {
        guard let request = manifests.first(where: { $0.id == manifestID }) else { return }
        guard request.state.status != .completed else { return }
        var newState = request.state
        newState.status = .downloading
        request.state = newState
        refreshRunningTaskCount()
    }

    /// Tiến độ từ background task (đã chống spam 0,5 giây bên service).
    func backgroundDownloadProgress(manifestID: UUID, downloadedBytes: Int64, totalBytes: Int64) {
        guard let request = manifests.first(where: { $0.id == manifestID }) else { return }
        guard request.state.status == .downloading || request.state.status == .pending else { return }
        var newState = request.state
        newState.status = .downloading
        newState.downloadedBytes = downloadedBytes
        newState.totalBytes = totalBytes
        if totalBytes > 0 {
            newState.percent = Double(downloadedBytes) / Double(totalBytes)
        }
        request.state = newState
    }

    /// File tải nền đã về tới thư mục tạm của hệ thống: chèn chữ ký
    /// trong beginBackgroundTask (app có thể đang ở nền) rồi hoàn thành.
    func backgroundDownloadFinished(manifestID: UUID, location: URL) {
        guard let request = manifests.first(where: { $0.id == manifestID }) else { return }
        request.resumeData = nil
        #if canImport(UIKit)
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NVD-Finalize-Download") {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            Task.detached {
                do {
                    try await self.finalize(manifest: request, preparedContentAt: location)
                    await MainActor.run {
                        request.state.complete()
                        self.refreshRunningTaskCount()
                        self.saveManifests()
                        self.maybeAutoInstall(manifest: request)
                        if backgroundTask != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                        }
                    }
                } catch {
                    await MainActor.run {
                        request.state.error = error.localizedDescription
                        self.refreshRunningTaskCount()
                        self.saveManifests()
                        if backgroundTask != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                        }
                    }
                }
            }
        #else
            completeDownload(manifest: request, downloadedFile: location)
        #endif
    }

    /// Task nền lỗi (không phải huỷ tay). Link CDN hết hạn (403/410)
    /// thì lấy URL có chữ ký mới rồi tải lại; còn resumeData (vd mất
    /// mạng giữa chừng) thì giữ lại để lần bấm tiếp tục nối tiếp được.
    func backgroundDownloadFailed(manifestID: UUID, error: Error, httpStatus: Int, resumeData: Data?) {
        guard let request = manifests.first(where: { $0.id == manifestID }) else { return }
        if httpStatus == 403 || httpStatus == 410 {
            logger.info("background download \(manifestID) expired link (HTTP \(httpStatus)), refreshing signed URL")
            refreshExpiredLinkAndResume(manifestID: manifestID)
            return
        }
        if let resumeData {
            request.resumeData = resumeData
        }
        var newState = request.state
        newState.status = .paused
        newState.speed = ""
        newState.error = nil
        request.state = newState
        // Không đặt state.error: lỗi mạng giữa chừng không phải lỗi hẳn,
        // để trạng thái tạm dừng + giữ resumeData để bấm tiếp tục nối tiếp.
        logger.info("background download \(manifestID) paused on error: \(StoreDiagnostics.errorSummary(error))")
        refreshRunningTaskCount()
        saveManifests()
    }

    /// Link CDN hết hạn: lấy URL có chữ ký mới rồi tải lại từ đầu bằng
    /// URL mới. ResumeData cũ gắn chặt với URL cũ (URLSession ghi URL
    /// vào trong resumeData) nên không nối tiếp được — tải lại là lựa
    /// chọn duy nhất, xem ghi chú ở BackgroundDownloadService.
    private func refreshExpiredLinkAndResume(manifestID: UUID) {
        guard let request = manifests.first(where: { $0.id == manifestID }) else { return }
        Task {
            do {
                let output = try await AppStore.this.withAccount(id: request.account.id) { account in
                    try await StoreDownloadService.download(account: &account.account, package: request.package, region: nil)
                }
                try await MainActor.run {
                    try request.refreshDownloadOutput(output)
                    request.resumeData = nil
                    var newState = request.state
                    newState.downloadedBytes = 0
                    newState.totalBytes = 0
                    newState.percent = 0
                    request.state = newState
                    self.saveManifests()
                    self.resume(request: request)
                }
            } catch {
                await MainActor.run {
                    request.state.error = String(localized: "Link tải đã hết hạn và không lấy được link mới. Hãy bấm tải lại sau.")
                    self.refreshRunningTaskCount()
                    self.saveManifests()
                }
            }
        }
    }

    /// "Tải xong tự cài đặt" (đợt 4, build 9, mặc định TẮT): tải xong thì
    /// mở luôn đường cài đặt hiện có của iOS (Installer + itms-services
    /// qua máy chủ manifest trong Cài đặt). Chỉ chạy khi app đang mở
    /// (mở itms-services từ nền không có tác dụng); tắt thì không làm
    /// gì — tải xong vẫn phải bấm Cài đặt tay như trước.
    private func maybeAutoInstall(manifest: PackageManifest) {
        #if canImport(UIKit)
            guard AppStore.this.autoInstallAfterDownload else { return }
            guard FileManager.default.fileExists(atPath: manifest.targetLocation.path) else { return }
            guard UIApplication.shared.applicationState == .active else {
                logger.info("auto-install skipped for \(manifest.id): app is not active")
                return
            }
            Task {
                do {
                    let installer = try await Installer(
                        archive: manifest.package,
                        path: manifest.targetLocation,
                        manifestServerURL: AppStore.this.manifestServerURL
                    )
                    self.autoInstallers[manifest.id] = installer
                    installer.beginInstall()
                    _ = await UIApplication.shared.open(installer.iTunesLink)
                    logger.info("auto-install started for \(manifest.id)")
                } catch {
                    logger.error("auto-install failed for \(manifest.id): \(StoreDiagnostics.errorSummary(error))")
                }
            }
        #endif
    }

    private func finalize(manifest: PackageManifest, preparedContentAt downloadedFile: URL) async throws {
        // Verify the main bundle identity and platform before signature injection.
        try StorePackageValidator.validate(at: downloadedFile, package: manifest.package)
        try? FileManager.default.createDirectory(
            at: manifest.targetLocation.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? FileManager.default.removeItem(at: manifest.targetLocation)

        let tempFile = manifest.targetLocation
            .deletingLastPathComponent()
            .appendingPathComponent(".\(manifest.targetLocation.lastPathComponent).unsigned")
        try? FileManager.default.removeItem(at: tempFile)

        logger.info("preparing signature: \(manifest.id)")
        try FileManager.default.moveItem(at: downloadedFile, to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        logger.info("injecting signatures: \(manifest.id)")
        try await SignatureInjector.inject(
            sinfs: manifest.signatures,
            iTunesMetadata: manifest.iTunesMetadata,
            into: tempFile.path,
        )

        logger.info("moving finalized file: \(manifest.id)")
        try FileManager.default.moveItem(at: tempFile, to: manifest.targetLocation)
    }

    func delete(request: PackageManifest) {
        logger.info("deleting download request id: \(request.id)")
        BackgroundDownloadService.shared.cancelDownload(manifestID: request.id)
        DiggerManager.shared.cancelTask(for: request.url)
        registeredCallbacks.remove(request.id)
        #if canImport(UIKit)
            autoInstallers[request.id]?.destroy()
            autoInstallers.removeValue(forKey: request.id)
        #endif
        request.delete()
        manifests.removeAll(where: { $0.id == request.id })
        refreshRunningTaskCount()
    }

    func restart(request: PackageManifest) {
        logger.info("restarting download request id: \(request.id)")
        BackgroundDownloadService.shared.cancelDownload(manifestID: request.id)
        DiggerManager.shared.cancelTask(for: request.url)
        registeredCallbacks.remove(request.id)
        request.resumeData = nil
        request.delete()
        request.state = .init()
        resume(request: request)
    }

    func removeAll() {
        manifests.forEach {
            BackgroundDownloadService.shared.cancelDownload(manifestID: $0.id)
            $0.delete()
        }
        #if canImport(UIKit)
            autoInstallers.values.forEach { $0.destroy() }
            autoInstallers.removeAll()
        #endif
        manifests.removeAll()
        registeredCallbacks.removeAll()
        refreshRunningTaskCount()
    }
}
