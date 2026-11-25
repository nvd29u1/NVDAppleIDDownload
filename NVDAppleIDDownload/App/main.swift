//
//  main.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Digger
import Logging
import SwiftUI

LoggingSystem.bootstrap { label in
    LogManagerHandler(label: label)
}

let logger = {
    var logger = Logger(label: "com.NVD.appleiddownload")
    logger.logLevel = .debug
    return logger
}()

APLogger.verbose = false
APLogger.logger = Logger(label: "com.NVD.appleiddownload.applepackage")

let version = [
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
]
.compactMap { $0 ?? "?" }
.joined(separator: " ")

let bundleIdentifier = Bundle.main.bundleIdentifier!
logger.info("NVDAppleIDDownload \(bundleIdentifier) \(version) starting up...")
logger.info("Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = availableDirectories[0]
    .appendingPathComponent("NVDAppleIDDownload")
let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent(bundleIdentifier)

// The directories must exist before module-scope singletons touch them, so
// these stay on the launch path.
try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

// Pruning empty leftover directories and warming up hostName are not needed
// before the first frame; keep the recursive scans off the launch path.
Task.detached(priority: .background) {
    for base in [documentsDirectory, temporaryDirectory] {
        let enumerator = FileManager.default.enumerator(atPath: base.path)
        while let file = enumerator?.nextObject() as? String {
            let path = base.appendingPathComponent(file)
            if let content = try? FileManager.default.contentsOfDirectory(atPath: path.path),
               content.isEmpty
            {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
    _ = ProcessInfo.processInfo.hostName
}

DiggerManager.shared.maxConcurrentTasksCount = 3
DiggerManager.shared.startDownloadImmediately = true

#if os(iOS)
    Task.detached {
        _ = try await Installer(certificateAtPath: Installer.ca.path)
    }
#endif

App.main()

private struct App: SwiftUI.App {
    #if canImport(UIKit)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    #if canImport(AppKit) && !canImport(UIKit)
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
            WindowGroup(id: "main-window") {
                // Khoá app (đợt 3, build 8): bọc màn chính để khi khoá
                // đang bật thì nội dung bị che bởi màn khoá.
                AppLockGate {
                    MainView()
                }
            }
            .windowResizability(.contentSize)
            .commands { SidebarMenuCommands() }
        #else
            WindowGroup(id: "main-window") {
                AppLockGate {
                    if #available(iOS 26.0, *) {
                        NewMainView()
                    } else {
                        MainView()
                    }
                }
            }
        #endif
    }
}
