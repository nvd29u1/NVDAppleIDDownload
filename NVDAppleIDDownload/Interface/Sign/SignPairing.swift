#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// iOS 27 on-device pairing and installs through the pairing tunnel (rust/sayoidev, built on
/// idevice). This is SideStore's install path: it works for free Apple ID profiles, which
/// over-the-air installs refuse. Needs LocalDevVPN (or another loopback VPN) connected.
enum DeviceLink {
    static var pairingFile: URL { SignPaths.support.appendingPathComponent("rp_pairing_file.plist") }
    static var isPaired: Bool { FileManager.default.fileExists(atPath: pairingFile.path) }
    static let hostName = "NVDAppleIDDownload"

    /// Saves an RPPairing file made elsewhere (StikDebug, PhonePair, idevice_pair).
    static func importPairing(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SayoError(L("This is not a pairing file"))
        }
        // Lockdown pairing files (.mobiledevicepairing) carry HostCertificate; RPPairing ones do not.
        if p["HostCertificate"] != nil && p["public_key"] == nil && p["publicKey"] == nil {
            throw SayoError(L("This is a lockdown pairing file. NVDAppleIDDownload needs an RPPairing file (iOS 27 pairing)."))
        }
        try? FileManager.default.removeItem(at: pairingFile)
        try data.write(to: pairingFile, options: .completeFileProtectionUntilFirstUserAuthentication)
    }

    static func forget() { try? FileManager.default.removeItem(at: pairingFile) }

    static func check(address: String, port: Int) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var out = [CChar](repeating: 0, count: 256)
            var err = [CChar](repeating: 0, count: 512)
            let rc = sayo_idev_check(DeviceLink.pairingFile.path, address, UInt16(clamping: port), &out, out.count, &err, err.count)
            if rc != 0 { throw SayoError(String(cString: err)) }
            return String(cString: out)
        }.value
    }

    final class ProgressBox {
        let fn: (Int, String) -> Void
        init(_ fn: @escaping (Int, String) -> Void) { self.fn = fn }
    }

    /// Uploads and installs the IPA through the tunnel; `progress` gets (percent, stage).
    static func install(ipa: URL, address: String, port: Int, progress: @escaping (Int, String) -> Void) async throws {
        guard isPaired else { throw SayoError(L("Pair this iPhone first: Settings → Installing → Pair this iPhone")) }
        let box = ProgressBox(progress)
        try await Task.detached(priority: .userInitiated) {
            let ctx = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
            var err = [CChar](repeating: 0, count: 512)
            let cb: sayo_idev_progress_cb = { pct, stage, ctx in
                guard let ctx = ctx else { return }
                let b = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                let s = stage.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async { b.fn(Int(pct), s) }
            }
            let rc = sayo_idev_install(DeviceLink.pairingFile.path, address, UInt16(clamping: port), ipa.path, cb, ctx, &err, err.count)
            if rc != 0 { throw SayoError(String(cString: err)) }
        }.value
    }
}

/// Runs the pairable host: advertises NVDAppleIDDownload over Bonjour and waits for the user to tap
/// "Pair with NVDAppleIDDownload" in Settings → Privacy & Security → Developer Mode.
final class PairingHost: NSObject, ObservableObject, NetServiceDelegate {
    @Published var pin: String?
    @Published var state = ""
    @Published var running = false
    @Published var error: String?
    @Published var done = false
    private var service: NetService?
    private var cancel: OpaquePointer?

    func start() {
        guard !running else { return }
        running = true
        error = nil
        pin = nil
        done = false
        state = L("Waiting for the iPhone…")
        // The user goes to Settings while pairing: keep NVDAppleIDDownload running in the background
        // and be allowed to show the PIN there as a notification.
        InstallServer.shared.keepAlive(true)
        let token = sayo_idev_cancel_new()
        cancel = token
        let ctx = Unmanaged.passRetained(self).toOpaque()
        let out = DeviceLink.pairingFile.path + ".new"
        Thread.detachNewThread { [weak self] in
            var err = [CChar](repeating: 0, count: 512)
            let ready: sayo_idev_ready_cb = { port, json, ctx in
                guard let ctx = ctx, let json = json else { return }
                let me = Unmanaged<PairingHost>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: json)
                DispatchQueue.main.async { me.advertise(port: Int(port), json: text) }
            }
            let pinCb: sayo_idev_pin_cb = { pin, ctx in
                guard let ctx = ctx, let pin = pin else { return }
                let me = Unmanaged<PairingHost>.fromOpaque(ctx).takeUnretainedValue()
                let p = String(cString: pin)
                DispatchQueue.main.async {
                    me.pin = p
                    me.state = L("Type this code on the iPhone")
                }
            }
            let rc = sayo_idev_pair_host(DeviceLink.hostName, nil, out, ready, pinCb, ctx, token, &err, err.count)
            let message = String(cString: err)
            DispatchQueue.main.async {
                Unmanaged<PairingHost>.fromOpaque(ctx).release()
                guard let self = self else { return }
                self.service?.stop()
                self.service = nil
                InstallServer.shared.keepAlive(false)
                sayo_idev_cancel_free(token)
                self.cancel = nil
                self.running = false
                if rc == 0 {
                    try? FileManager.default.removeItem(at: DeviceLink.pairingFile)
                    try? FileManager.default.moveItem(atPath: out, toPath: DeviceLink.pairingFile.path)
                    self.done = true
                    self.state = L("Paired")
                } else if rc == -2 {
                    self.state = ""
                } else {
                    self.error = message.isEmpty ? L("Pairing failed") : message
                    self.state = ""
                }
            }
        }
    }

    func stop() {
        if let c = cancel { sayo_idev_cancel_signal(c) }
        service?.stop()
    }

    private func advertise(port: Int, json: String) {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let name = o["name"] as? String else { return }
        let txt = (o["txt"] as? [String: String] ?? [:]).mapValues { Data($0.utf8) }
        let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.delegate = self
        s.publish()
        service = s
        state = L("Open Settings → Privacy & Security → Developer Mode and tap Pair with NVDAppleIDDownload")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        error = L("Could not advertise on the local network. Connect to Wi-Fi, allow Local Network for NVDAppleIDDownload (Settings → Privacy & Security → Local Network) and try again.")
            + " (\(code))"
        stop()
    }
}

struct PairingView: View {
    @EnvironmentObject var state: SignAppState
    @Environment(\.dismiss) var dismiss
    @StateObject private var host = PairingHost()
    @State private var importing = false
    @State private var checking = false
    @State private var checkResult: String?
    @State private var paired = DeviceLink.isPaired

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text(L("Pairing lets NVDAppleIDDownload install apps the way SideStore does, including apps signed with a free Apple ID. It needs iOS 27, Developer Mode and LocalDevVPN (free on the App Store) connected while installing."))) {
                    HStack {
                        Image(systemName: paired ? "checkmark.seal.fill" : "link.badge.plus")
                            .foregroundColor(paired ? .green : SignTheme.rose).font(.title2)
                        Text(paired ? L("This iPhone is paired") : L("Not paired yet")).font(.headline)
                    }
                }
                Section(header: Text(L("Pair on this iPhone (iOS 27)"))) {
                    if host.running {
                        if let p = host.pin {
                            Text(p).font(.system(size: 44, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity)
                                .textSelection(.enabled)
                            Button { UIPasteboard.general.string = p; state.show(L("Code copied")) } label: {
                                Label(L("Copy code"), systemImage: "doc.on.doc")
                            }
                            .nvdBorderBeam(shape: .rounded(10))
                        } else {
                            HStack { ProgressView(); Text(host.state).font(.subheadline) }
                        }
                        if host.pin != nil { Text(host.state).font(.caption).foregroundColor(.secondary) }
                        Button(L("Open Settings")) { if let u = URL(string: UIApplication.openSettingsURLString) { Task { @MainActor in _ = await UIApplication.shared.open(u) } } }.nvdBorderBeam(shape: .rounded(10))
                        Button(L("Cancel"), role: .destructive) { host.stop() }.nvdBorderBeam(shape: .rounded(10))
                    } else {
                        Button { host.start() } label: { Label(L("Pair this iPhone"), systemImage: "iphone.and.arrow.forward") }.nvdBorderBeam(shape: .rounded(10))
                        Text(L("Tap Pair, then open Settings → Privacy & Security → Developer Mode → Pair with NVDAppleIDDownload and type the code shown here."))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let e = host.error { Text(e).foregroundColor(.red).font(.caption) }
                }
                Section(header: Text(L("Or import a pairing file")), footer: Text(L("An RPPairing file from StikDebug or PhonePair works too."))) {
                    Button { pick() } label: { Label(L("Import pairing file"), systemImage: "doc.badge.plus") }.nvdBorderBeam(shape: .rounded(10))
                }
                if paired {
                    Section(header: Text(L("Connection")), footer: Text(L("Turn LocalDevVPN on, then check."))) {
                        HStack {
                            Text(L("Address"))
                            Spacer()
                            TextField("10.7.0.1", text: $state.settings.tunnelAddress).multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation).autocapitalization(.none).disableAutocorrection(true)
                        }
                        Button { Task { await check() } } label: {
                            HStack { Label(L("Check connection"), systemImage: "bolt.horizontal"); Spacer(); if checking { ProgressView() } }
                        }
                        .disabled(checking)
                        .nvdBorderBeam(shape: .rounded(10))
                        if let r = checkResult { Text(r).font(.caption).foregroundColor(.secondary) }
                        if let u = URL(string: "https://apps.apple.com/search?term=LocalDevVPN") {
                            Link(destination: u) { Label(L("Get LocalDevVPN"), systemImage: "lock.shield") }
                        }
                        Button(L("Forget pairing"), role: .destructive) { DeviceLink.forget(); paired = false; checkResult = nil }.nvdBorderBeam(shape: .rounded(10))
                    }
                }
            }
            .navigationTitle(L("Pairing"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { host.stop(); dismiss() }.nvdBorderBeam(shape: .rounded(10)) } }
            .onChange(of: host.done) { d in if d { paired = true; state.show(L("This iPhone is paired")) } }
        }
    }

    func pick() {
        FilePicker.shared.pick([.item], multiple: false) { urls in
            guard let u = urls.first else { return }
            do {
                try DeviceLink.importPairing(u)
                try? FileManager.default.removeItem(at: u)
                paired = true
                state.show(L("Pairing file imported"))
            } catch {
                host.error = error.localizedDescription
            }
        }
    }

    func check() async {
        checking = true
        defer { checking = false }
        do {
            checkResult = "✓ " + (try await DeviceLink.check(address: state.settings.tunnelAddress, port: 49152))
        } catch {
            checkResult = "✗ " + error.localizedDescription
        }
    }
}
#endif
