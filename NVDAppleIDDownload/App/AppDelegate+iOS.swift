//
//  AppDelegate+iOS.swift
//  NVDAppleIDDownload
//

#if canImport(UIKit)
    import UIKit

    class AppDelegate: NSObject, UIApplicationDelegate {
        var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
        ) -> Bool {
            Task { @MainActor in
                self.observeDownloadCount()
            }
            return true
        }

        @MainActor
        private func observeDownloadCount() {
            withObservationTracking {
                let count = Downloads.this.runningTaskCount
                UIApplication.shared.isIdleTimerDisabled = count > 0
                BackgroundAudioPlayer.shared.setActive(count > 0)
            } onChange: {
                Task { @MainActor in
                    self.observeDownloadCount()
                }
            }
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
