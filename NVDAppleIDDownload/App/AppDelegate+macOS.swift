//
//  AppDelegate+macOS.swift
//  NVDAppleIDDownload
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import Combine

    class AppDelegate: NSObject, NSApplicationDelegate {
        var activityToken: NSObjectProtocol?
        private var downloadCountCancellable: AnyCancellable?

        func applicationWillFinishLaunching(_: Notification) {
            // Remove the "Show Tab Bar" / "Show All Tabs" items from the View
            // menu; this single-window app has no use for window tabbing.
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        func applicationDidFinishLaunching(_: Notification) {
            Task { @MainActor in
                self.observeDownloadCount()
            }
        }

        /// Như bản iOS: objectWillChange phát trước khi giá trị đổi nên
        /// đọc lại ở lượt MainActor sau. withObservationTracking không
        /// còn dùng được vì Downloads đã là ObservableObject (tracking
        /// cũ chỉ theo dõi @Observable, không phát nữa).
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
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            updateProcessActivity(isDownloading: count > 0)
        }

        private func updateProcessActivity(isDownloading: Bool) {
            if isDownloading, activityToken == nil {
                activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Downloading App Store packages",
                )
            } else if !isDownloading, let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
                activityToken = nil
            }
        }

        func applicationDidBecomeActive(_: Notification) {
            if let mainWindow = NSApplication.shared.windows.first(where: {
                $0.identifier?.rawValue == "main-window"
            }) {
                mainWindow.styleMask = [.titled, .closable, .fullSizeContentView, .fullScreen]
                mainWindow.toolbar?.allowsUserCustomization = false
                mainWindow.toolbar?.allowsExtensionItems = false
                mainWindow.toolbar?.allowsDisplayModeCustomization = false
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            Downloads.this.runningTaskCount == 0
        }
    }
#endif
