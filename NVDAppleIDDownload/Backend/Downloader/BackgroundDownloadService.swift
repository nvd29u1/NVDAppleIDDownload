//  BackgroundDownloadService.swift
//  NVDAppleIDDownload
//
//  Tải nền thật (đợt 4, build 9 — ý tưởng iPadn mục 8, viết lại sạch).
//
//  Vấn đề cũ: Downloads dùng Digger; suspend() gọi stopTask +
//  resetIfNotCompleted() nên tạm dừng là mất tiến độ, resume() tải lại
//  từ đầu, không có resumeData. Đường tải mới dùng URLSession background
//  (identifier com.NVD.appleiddownload.downloads) + URLSessionDownloadTask:
//  - Tạm dừng: cancel(byProducingResumeData:) → resumeData lưu vào
//    PackageManifest (decodeIfPresent nên manifest cũ vẫn đọc được).
//  - Tiếp tục: downloadTask(withResumeData:) nếu có resumeData, không
//    thì tải mới. Resume data hỏng thì tải mới, không crash.
//  - App bị tắt / sang nền: hệ thống vẫn tải tiếp; mở lại app,
//    reattach() qua getAllTasks (nhận diện task bằng taskDescription =
//    UUID của manifest) rồi nối lại tiến độ.
//  - Số byte đã tải / tổng số ghi vào PackageState (downloadedBytes /
//    totalBytes) nên mở lại app vẫn hiện đúng.
//  - Link CDN hết hạn (403/410): service báo về Downloads, Downloads
//    gọi lại StoreDownloadService.download() lấy URL có chữ ký mới rồi
//    tải lại từ đầu bằng URL mới. Resume data gắn chặt với URL cũ nên
//    KHÔNG nối tiếp được bằng resumeData cũ — đây là giới hạn của
//    URLSession, xem refreshExpiredLinkAndResume trong Downloads.
//  - Khi app bị đánh thức dưới nền để nhận file xong, finalize() (chèn
//    chữ ký) chạy trong beginBackgroundTask để có thời gian xong việc.
//  - Digger KHÔNG bị xoá: resume() dùng Digger làm đường dự phòng khi
//    không tạo được background task (vd URL không hợp lệ).
//  - KHÔNG làm Live Activity (cần extension + 1 App ID mới).
//

import Foundation
import Logging

/// Tải nền bằng URLSession background. Singleton giữ đúng 1 session cho
/// cả app (tạo 2 session cùng identifier trong 1 tiến trình là sai).
final class BackgroundDownloadService: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloadService()

    static let sessionIdentifier = "com.NVD.appleiddownload.downloads"

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.NVD.appleiddownload.backgroundDownloads"
        return queue
    }()

    private let lock = NSLock()
    /// Task đang chạy theo UUID manifest (đồng bộ qua lock).
    private var tasksByManifest: [UUID: URLSessionDownloadTask] = [:]
    /// Lần cập nhật tiến độ cuối cho mỗi manifest (chống spam UI).
    private var lastProgressUpdates: [UUID: Date] = [:]
    /// Completion handler hệ thống đưa khi đánh thức app dưới nền.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private override init() {
        // Session thật tạo lười ở downloadSession (chỉ 1 session cho cả
        // app, delegate là self) — KHÔNG tạo URLSession background thứ
        // hai cùng identifier, hệ thống không cho.
        super.init()
    }

    /// Session thật dùng trong app — tạo lười 1 lần với delegate self.
    private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var activeSession: URLSession { downloadSession }

    // MARK: - API cho Downloads

    /// Còn task nền đang chạy cho manifest này không (đọc từ bảng
    /// trong bộ nhớ, không gọi getAllTasks bất đồng bộ).
    func hasTask(for manifestID: UUID) -> Bool {
        lock.locked { tasksByManifest[manifestID] != nil }
    }

    /// Bắt đầu tải mới bằng background task. Trả false khi URL không
    /// tạo được task (caller sẽ dùng đường dự phòng Digger).
    @discardableResult
    func startDownload(manifestID: UUID, url: URL) -> Bool {
        let task = activeSession.downloadTask(with: url)
        task.taskDescription = manifestID.uuidString
        lock.locked { tasksByManifest[manifestID] = task }
        task.resume()
        logger.info("Background download: started task for manifest \(manifestID)")
        return true
    }

    /// Tiếp tục bằng resumeData. Trả false khi resumeData hỏng (caller
    /// xoá resumeData rồi tải mới).
    @discardableResult
    func resumeWithResumeData(manifestID: UUID, resumeData: Data) -> Bool {
        do {
            let task = try activeSession.downloadTask(withResumeData: resumeData)
            task.taskDescription = manifestID.uuidString
            lock.locked { tasksByManifest[manifestID] = task }
            task.resume()
            logger.info("Background download: resumed task for manifest \(manifestID) from resumeData (\(resumeData.count) bytes)")
            return true
        } catch {
            logger.error("Background download: resumeData hỏng cho manifest \(manifestID): \(StoreDiagnostics.errorSummary(error))")
            return false
        }
    }

    /// Huỷ task nền KHÔNG lấy resumeData (dùng khi xoá / tải lại).
    func cancelDownload(manifestID: UUID) {
        lock.locked { tasksByManifest.removeValue(forKey: manifestID) }?.cancel()
        _ = lock.locked { lastProgressUpdates.removeValue(forKey: manifestID) }
    }

    /// Tạm dừng: cancel(byProducingResumeData:) rồi trả resumeData qua
    /// completion (nil khi không còn task nền nào — vd task đang chạy
    /// bằng Digger, caller sẽ dừng theo đường Digger).
    func suspendDownload(manifestID: UUID, completion: @escaping (Data?) -> Void) {
        let task: URLSessionDownloadTask? = lock.locked { tasksByManifest[manifestID] }
        guard let task else {
            completion(nil)
            return
        }
        task.cancel { resumeData in
            completion(resumeData)
        }
    }

    /// Nối lại các task nền hệ thống vẫn giữ sau khi app bị tắt / mở
    /// lại: task nào còn chạy thì đưa manifest về trạng thái đang tải,
    /// task nào đã xong mà app chưa nhận file thì delegate sẽ giao file
    /// ngay sau đó.
    func reattach() {
        activeSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks {
                guard let downloadTask = task as? URLSessionDownloadTask,
                      let description = downloadTask.taskDescription,
                      let manifestID = UUID(uuidString: description)
                else { continue }
                self.lock.locked { self.tasksByManifest[manifestID] = downloadTask }
                Task { @MainActor in
                    Downloads.this.reattachBackgroundTask(manifestID: manifestID)
                }
            }
        }
    }

    /// Hệ thống đánh thức app dưới nền khi 1 task xong: giữ completion
    /// handler, gọi lại khi urlSessionDidFinishEvents chạy xong.
    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        // Chạm vào session để chắc chắn nó đã tạo với đúng identifier
        // trước khi hệ thống giao sự kiện.
        _ = activeSession
        lock.locked { backgroundCompletionHandlers[identifier] = completionHandler }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let manifestID = manifestID(of: downloadTask) else { return }
        lock.locked {
            tasksByManifest.removeValue(forKey: manifestID)
            lastProgressUpdates.removeValue(forKey: manifestID)
        }
        // DỜI FILE TẠM VỀ STAGING NGAY TẠI ĐÂY, ĐỒNG BỘ (build 13):
        // file ở `location` là file tạm của URLSession — hệ thống được
        // phép dọn nó ngay khi delegate này trả về. Bản 12 chỉ chuyển
        // tiếp location qua Task @MainActor + Task.detached rồi mới
        // finalize() ở Downloads: tới lúc đó file tạm đã bị dọn là
        // moveItem trong finalize ném đúng lỗi anh thấy trên máy thật —
        // "Không có tệp hay thư mục nào như vậy" (ENOENT) — rồi gói
        // rơi vào trạng thái failed / "Gói chưa đầy đủ". File đã về
        // staging trong Documents thì không ai dọn nữa, finalize làm
        // việc với nó như file thường.
        let stagedLocation = Self.stageDownloadedFile(manifestID: manifestID, from: location)
        Task { @MainActor in
            Downloads.this.backgroundDownloadFinished(manifestID: manifestID, location: stagedLocation ?? location)
        }
    }

    /// Dời file tạm vừa tải xong về thư mục staging của app
    /// (`Documents/NVDAppleIDDownload/Packages/.staging/<uuid>.ipa`).
    /// Trả nil khi dời không được — caller giữ nguyên location cũ và
    /// finalize sẽ báo lỗi tiếng Việt rõ ràng thay vì văng/lỗi thô.
    private static func stageDownloadedFile(manifestID: UUID, from location: URL) -> URL? {
        let stagingDir = documentsDirectory
            .appendingPathComponent("Packages")
            .appendingPathComponent(".staging")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let staged = stagingDir.appendingPathComponent("\(manifestID.uuidString).ipa")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            return staged
        } catch {
            logger.error("Background download: không dời được file tạm về staging cho manifest \(manifestID): \(StoreDiagnostics.errorSummary(error))")
            return nil
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let manifestID = manifestID(of: downloadTask) else { return }
        let now = Date()
        let shouldReport = lock.locked { () -> Bool in
            let last = lastProgressUpdates[manifestID]
            guard last == nil || now.timeIntervalSince(last!) >= 0.5 || totalBytesWritten >= totalBytesExpectedToWrite else {
                return false
            }
            lastProgressUpdates[manifestID] = now
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor in
            Downloads.this.backgroundDownloadProgress(
                manifestID: manifestID,
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let manifestID = manifestID(of: task) else { return }
        guard let error else { return } // xong tốt: file đã giao ở didFinishDownloadingTo
        let nsError = error as NSError
        // Người dùng bấm tạm dừng (cancel có resumeData) hoặc xoá task:
        // không phải lỗi, trạng thái paused / xoá do Downloads đặt.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            lock.locked {
                tasksByManifest.removeValue(forKey: manifestID)
                lastProgressUpdates.removeValue(forKey: manifestID)
            }
            return
        }
        lock.locked {
            tasksByManifest.removeValue(forKey: manifestID)
            lastProgressUpdates.removeValue(forKey: manifestID)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            Downloads.this.backgroundDownloadFailed(
                manifestID: manifestID,
                error: error,
                httpStatus: status,
                resumeData: resumeData
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        let handler = lock.locked { backgroundCompletionHandlers.removeValue(forKey: identifier) }
        handler?()
    }

    // MARK: - Hỗ trợ

    private func manifestID(of task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription else { return nil }
        return UUID(uuidString: description)
    }
}

private extension NSLock {
    /// Chạy body trong lock rồi trả kết quả (tiện cho dict).
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
