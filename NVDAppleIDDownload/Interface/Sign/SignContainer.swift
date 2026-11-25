#if os(iOS)
import Foundation
import MachO
import ObjectiveC
import UIKit

/// Runs apps inside NVDAppleIDDownload's own process, the way LiveContainer does (experimental).
///
/// The app is signed with the same certificate as NVDAppleIDDownload and its main executable is turned
/// into a dylib at signing time (sayo_macho_make_dylib). "Run" leaves a one-shot launch
/// request and closes NVDAppleIDDownload; on the next start main.swift loads the app with dlopen, swaps
/// in its bundle and home folder, and jumps to its entry point instead of starting NVDAppleIDDownload.
/// The request is deleted before loading, so a crashing app never traps NVDAppleIDDownload.
enum Container {
    static var appsDir: URL { SignPaths.dir("ContainerApps") }
    static var dataDir: URL { SignPaths.dir("ContainerData", in: SignPaths.documents) }
    static var requestFile: URL {
        // Plain path math: this runs before anything else in the process.
        // Merged app (build 10): flat under the app's own support dir, not a
        // nested subfolder — SayoSign wrote ".../SayoSign/SayoSign/..." here,
        // whose parent never existed, so the write could fail silently.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NVDAppleIDDownload/container-launch.plist")
    }

    /// The unpacked .app for a signed app (unzipped from its IPA on first run).
    static func prepare(_ app: SignedApp, ipa: URL) throws -> URL {
        let dir = appsDir.appendingPathComponent(app.id.uuidString, isDirectory: true)
        let payload = dir.appendingPathComponent("Payload", isDirectory: true)
        if let existing = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) {
            return existing
        }
        try? FileManager.default.removeItem(at: dir)
        try SayoCore.unzip(ipa, to: dir) { _ in }
        guard let appDir = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw SayoError(L("The IPA has no app inside")) }
        return appDir
    }

    static func remove(_ app: SignedApp) {
        try? FileManager.default.removeItem(at: appsDir.appendingPathComponent(app.id.uuidString))
    }

    /// Leaves the launch request and closes NVDAppleIDDownload; the app starts when NVDAppleIDDownload is opened again.
    static func run(_ app: SignedApp, ipa: URL) throws {
        let appDir = try prepare(app, ipa: ipa)
        let home = dataDir.appendingPathComponent(app.bundleID, isDirectory: true)
        for sub in ["Documents", "Library/Preferences", "Library/Caches", "tmp"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let req: [String: Any] = ["app": appDir.path, "home": home.path, "name": app.name, "created": Date()]
        let data = try PropertyListSerialization.data(fromPropertyList: req, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: requestFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: requestFile, options: .atomic)
        // Close NVDAppleIDDownload; the next launch starts the app.
        UIControl().sendAction(#selector(NSXPCConnection.suspend), to: UIApplication.shared, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }

    // MARK: - launching (called from main.swift before UIKit starts)

    private static var guestBundle: Bundle?

    /// Starts the requested app and never returns, or returns false to start NVDAppleIDDownload normally.
    static func launchIfRequested() -> Bool {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: requestFile.path) else { return false }
        try? fm.removeItem(at: requestFile) // one shot: a crash must not loop
        guard let req = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let appPath = req["app"] as? String, let home = req["home"] as? String,
              let created = req["created"] as? Date, Date().timeIntervalSince(created) < 120,
              let bundle = Bundle(path: appPath), let exe = bundle.executablePath else { return false }

        setenv("HOME", home, 1)
        setenv("CFFIXED_USER_HOME", home, 1)
        setenv("TMPDIR", home + "/tmp/", 1)
        guestBundle = bundle
        swizzleMainBundle()

        guard let handle = dlopen(exe, RTLD_NOW | RTLD_GLOBAL) else {
            NSLog("NVDAppleIDDownload container: dlopen failed: %@", String(cString: dlerror()))
            return false
        }
        _ = handle
        guard let entry = entryPoint(ofImageAt: exe) else {
            NSLog("NVDAppleIDDownload container: no LC_MAIN in %@", exe)
            return false
        }
        typealias Main = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let main = unsafeBitCast(entry, to: Main.self)
        exit(main(CommandLine.argc, CommandLine.unsafeArgv))
    }

    /// +[NSBundle mainBundle] answers with the app's bundle, so it finds its Info.plist,
    /// resources and bundle ID.
    private static func swizzleMainBundle() {
        guard let cls = object_getClass(Bundle.self),
              let m = class_getClassMethod(Bundle.self, #selector(getter: Bundle.main)) else { return }
        let block: @convention(block) (AnyObject) -> Bundle = { _ in Container.guestBundle ?? Bundle(for: SignMarker.self) }
        let imp = imp_implementationWithBlock(block)
        class_replaceMethod(cls, #selector(getter: Bundle.main), imp, method_getTypeEncoding(m))
    }

    /// Address of the image's LC_MAIN entry point.
    private static func entryPoint(ofImageAt path: String) -> UnsafeRawPointer? {
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i),
                  URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path == wanted,
                  let header = _dyld_get_image_header(i) else { continue }
            let raw = UnsafeRawPointer(header)
            let ncmds = raw.load(fromByteOffset: 16, as: UInt32.self)
            var cmd = raw.advanced(by: 32)
            for _ in 0..<ncmds {
                let type = cmd.load(as: UInt32.self), size = cmd.load(fromByteOffset: 4, as: UInt32.self)
                if type == 0x8000_0028 { // LC_MAIN
                    let entryoff = cmd.load(fromByteOffset: 8, as: UInt64.self)
                    return raw.advanced(by: Int(entryoff))
                }
                cmd = cmd.advanced(by: Int(size))
            }
        }
        return nil
    }
}

/// Anchor for Bundle(for:) when no guest bundle is set.
final class SignMarker {}
#endif
