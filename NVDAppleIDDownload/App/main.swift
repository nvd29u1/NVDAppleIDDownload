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

#if os(iOS)
    // Chạy app trong NVDAppleIDDownload (tính năng ký "Run inside", kiểu
    // LiveContainer, gộp từ NVDsign): có yêu cầu chạy app khách thì nhảy
    // vào app đó và không bao giờ trở lại đây.
    _ = Container.launchIfRequested()
#endif

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

/// Đầu trên của khoảng iOS hỗ trợ hiển thị ở mục Giới thiệu (Cài đặt
/// chính). Mốc ổn định anh chốt 19/11/2026: trên 27.2 là ngoài vùng ổn
/// định đã biết (Apple bắt đầu vá từ 27.2 beta 3 với Airlift, 27.3
/// beta 2 với worse_query). Đầu dưới lấy từ MinimumOSVersion của
/// binary — đổi min ở Base.xcconfig thì About tự cập nhật theo.
let maxSupportedIOSVersion = "27.2"
/// iOS cao nhất đã kiểm chứng thật trên máy anh (iOS 27.0) — dòng ghi
/// chú nhỏ ở mục Giới thiệu, KHÔNG phải đầu trên của khoảng hỗ trợ.
let testedIOSVersion = "27.0"

/// Đầu dưới của khoảng iOS hỗ trợ, đọc từ MinimumOSVersion của binary.
let minSupportedIOSVersion =
    Bundle.main.infoDictionary?["MinimumOSVersion"] as? String ?? "16.0"

#if os(iOS)
/// true khi iOS của máy đang chạy nằm trong khoảng hỗ trợ
/// [minSupportedIOSVersion, maxSupportedIOSVersion] (so theo
/// major.minor, bỏ patch — "27.0.1" vẫn là 27.0).
let isCurrentIOSSupported: Bool = {
    func majorMinor(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }
    func atLeast(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        a.0 > b.0 || (a.0 == b.0 && a.1 >= b.1)
    }
    func atMost(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        a.0 < b.0 || (a.0 == b.0 && a.1 <= b.1)
    }
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let current = (v.majorVersion, v.minorVersion)
    return atLeast(current, majorMinor(minSupportedIOSVersion))
        && atMost(current, majorMinor(maxSupportedIOSVersion))
}()
#endif

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
                    Group {
                        if #available(iOS 26.0, *) {
                            NewMainView()
                        } else {
                            MainView()
                        }
                    }
                    // Tính năng ký (gộp từ NVDsign, build 10): trạng thái ký
                    // dùng chung cả app; file mở bằng app (.ipa/.p12/...)
                    // đi vào thư viện ký.
                    .environmentObject(SignAppState.shared)
                    .environmentObject(CertificateImportCoordinator.shared)
                    .onOpenURL { url in
                        Task { @MainActor in SignAppState.shared.handleOpen(url) }
                    }
                }
            }
        #endif
    }
}
