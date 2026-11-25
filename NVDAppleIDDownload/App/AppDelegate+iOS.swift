//
//  AppDelegate+iOS.swift
//  NVDAppleIDDownload
//

#if canImport(UIKit)
    import Combine
    import UIKit

    class AppDelegate: NSObject, UIApplicationDelegate {
        var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
        private var downloadCountCancellable: AnyCancellable?

        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
        ) -> Bool {
            Task { @MainActor in
                self.observeDownloadCount()
            }
            return true
        }

        /// Downloads là ObservableObject (iOS 16, bản 17): objectWillChange
        /// phát TRƯỚC khi giá trị đổi nên đọc lại số lượng ở lượt
        /// MainActor sau, thay cho withObservationTracking (iOS 17+).
        @MainActor
        private func observeDownloadCount() {
            applyDownloadCount()
            downloadCountCancellable = Downloads.this.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in self?.applyDownloadCount() }
                }
        }

        @MainActor
        private func applyDownloadCount() {
            let count = Downloads.this.runningTaskCount
            UIApplication.shared.isIdleTimerDisabled = count > 0
            BackgroundAudioPlayer.shared.setActive(count > 0)
        }

        func applicationWillResignActive(_: UIApplication) {
            guard Downloads.this.runningTaskCount > 0 else { return }
            let task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskIdentifier)
                self.backgroundTaskIdentifier = .invalid
            }
            backgroundTaskIdentifier = task
        }

        func applicationWillEnterForeground(_: UIApplication) {
            guard backgroundTaskIdentifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
            backgroundTaskIdentifier = .invalid
        }

        /// Hệ thống đánh thức app dưới nền khi 1 task tải nền xong:
        /// giao completion handler cho BackgroundDownloadService, nó sẽ
        /// gọi lại khi đã nhận xong mọi sự kiện (đợt 4, build 9).
        func application(
            _: UIApplication,
            handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void,
        ) {
            BackgroundDownloadService.shared.handleEventsForBackgroundURLSession(
                identifier: identifier,
                completionHandler: completionHandler,
            )
        }
    }
#endif
