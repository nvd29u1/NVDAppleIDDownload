#if os(iOS)
import SwiftUI

struct SignSettingsView: View {
    @EnvironmentObject var state: SignAppState
    // The manifest server is the app's own single setting (Cài đặt →
    // Install App); this view only edits it, it does not own a second one.
    @State private var store = AppStore.this
    @State private var setup = false
    @State private var confirmReset = false
    @State private var cacheSize: Int64 = 0
    @State private var installLog: [String] = []
    @State private var pairing = false
    @State private var checking = false
    @State private var anisetteInfo: [(String, String)]?
    @State private var anisetteError: String?
    @State private var customServer = false

    var serverChoice: Binding<String> {
        Binding(get: {
            if customServer { return "custom" }
            return Anisette.presets.contains(where: { $0.url == state.settings.anisetteURL }) ? state.settings.anisetteURL : "custom"
        }, set: { v in
            anisetteInfo = nil
            anisetteError = nil
            if v == "custom" { customServer = true } else { customServer = false; state.settings.anisetteURL = v }
        })
    }

    func checkAnisette() async {
        checking = true
        anisetteError = nil
        defer { checking = false }
        do {
            let a = try await Anisette.fetch(state.settings.anisetteURL)
            var rows: [(String, String)] = [
                (L("Protocol"), a.version),
                (L("Status"), a.isProvisioned ? L("Provisioned") : L("Not provisioned")),
                (L("Client"), a.isMacClient ? "Mac ✓" : (a.isLegacyClient ? L("Legacy (rejected by Apple)") : L("Non-Mac"))),
                ("Client info", a.clientInfo),
                ("User-Agent", a.userAgent),
                (L("Device ID"), a.deviceID),
            ]
            if !a.isMacClient { rows.append((L("Warning"), L("Apple may reject this server. Prefer a Mac-based one."))) }
            anisetteInfo = rows
        } catch {
            anisetteInfo = nil
            anisetteError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("Install method")),
                        footer: Text(L("Free Apple ID apps can only be installed through pairing (like SideStore): iOS 27, Developer Mode and LocalDevVPN. Certificates (.p12) install over the air."))) {
                    Picker(L("Method"), selection: $state.settings.installMethod) {
                        Text(L("Automatic")).tag(0)
                        Text(L("Over the air")).tag(1)
                        Text(L("Pairing (LocalDevVPN)")).tag(2)
                    }
                    Button { pairing = true } label: {
                        HStack {
                            Label(L("Pair this iPhone"), systemImage: "iphone.and.arrow.forward")
                            Spacer()
                            Text(DeviceLink.isPaired ? L("Paired") : L("Not paired")).foregroundColor(.secondary)
                        }
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                }

                Section(header: Text(L("Install options")), footer: Text(L("With a manifest service, iOS just asks to install the app; nothing to set up. Leave it empty to use the local HTTPS installer and its one-time profile."))) {
                    TextField(L("Manifest service (https://…workers.dev)"), text: $store.manifestServerURL)
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    if store.manifestServerURL.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { setup = true } label: { Label(L("Local installer setup"), systemImage: "lock.shield") }.nvdBorderBeam(shape: .rounded(10))
                    }
                    Toggle(L("Stay alive while installing"), isOn: $state.settings.keepAliveAudio)
                    Stepper(value: $state.settings.serverPort, in: 1025...65000, step: 2) {
                        HStack { Text(L("Server port")); Spacer(); Text("\(state.settings.serverPort)").foregroundColor(.secondary) }
                    }
                }

                Section(header: Text(L("Signing"))) {
                    Picker(L("Compression"), selection: $state.settings.compressionLevel) {
                        Text(L("None (fastest)")).tag(0)
                        Text(L("Fast")).tag(1)
                        Text(L("Balanced")).tag(6)
                        Text(L("Smallest")).tag(9)
                    }
                    Toggle(L("Remove app extensions by default"), isOn: $state.settings.autoRemovePlugins)
                    Toggle(L("Remove Watch apps by default"), isOn: $state.settings.removeWatchApps)
                }

                Section(header: Text(L("Appearance"))) {
                    Picker(L("Theme"), selection: $state.settings.appearance) {
                        Text(L("System")).tag(0)
                        Text(L("Light")).tag(1)
                        Text(L("Black")).tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text(L("Anisette server")),
                        footer: Text(L("Apple only accepts Mac-based anisette servers since October 2026. Use one of these, your own server, or the one SayoSign Desktop runs on your computer (scan its QR code)."))) {
                    Picker(L("Server"), selection: serverChoice) {
                        ForEach(Anisette.presets, id: \.url) { p in Text(p.name).tag(p.url) }
                        Text(L("Custom")).tag("custom")
                    }
                    if serverChoice.wrappedValue == "custom" {
                        TextField("https://…", text: $state.settings.anisetteURL)
                            .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
                    }
                    Button {
                        Task { await checkAnisette() }
                    } label: {
                        HStack { Text(L("Check server")); Spacer(); if checking { ProgressView() } }
                    }
                    .disabled(checking)
                    .nvdBorderBeam(shape: .rounded(10))
                    if let info = anisetteInfo {
                        ForEach(info.indices, id: \.self) { i in
                            let row = info[i]
                            HStack(alignment: .top) {
                                Text(row.0).foregroundColor(.secondary)
                                Spacer(minLength: 12)
                                Text(row.1).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                    if let e = anisetteError { Text(e).font(.caption).foregroundColor(.red) }
                    Button(L("Reset anisette"), role: .destructive) {
                        Anisette(server: state.settings.anisetteURL).reset()
                        anisetteInfo = nil
                        state.show(L("Anisette was reset"))
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                }

                Section(header: Text(L("Apple ID"))) {
                    HStack {
                        Text("UDID")
                        TextField("00008110-…", text: $state.settings.udid)
                            .multilineTextAlignment(.trailing).foregroundColor(.secondary)
                            .autocapitalization(.allCharacters).disableAutocorrection(true)
                    }
                }

                Section(header: Text(L("Storage"))) {
                    HStack { Text(L("Temporary files")); Spacer(); Text(formatSize(cacheSize)).foregroundColor(.secondary) }
                    Button(L("Clear temporary files")) {
                        try? FileManager.default.removeItem(at: SignPaths.work)
                        cacheSize = SignAppState.folderSize(SignPaths.work)
                        state.show(L("Cleared"))
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                    Button(L("Reset local installer"), role: .destructive) { confirmReset = true }.nvdBorderBeam(shape: .rounded(10))
                }

                Section(header: Text(L("Install log")), footer: Text(L("What iOS requested during the last install. Send a screenshot if an install fails."))) {
                    if installLog.isEmpty {
                        Text(L("No install yet")).font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(installLog.indices, id: \.self) { i in
                            Text(installLog[i]).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Button(L("Refresh")) { installLog = InstallServer.shared.logLines() }.nvdBorderBeam(shape: .rounded(10))
                }

            }
            .navigationTitle(L("Settings"))
            .sheet(isPresented: $setup) { InstallSetupView().environmentObject(state) }
            .sheet(isPresented: $pairing) { PairingView().environmentObject(state) }
            .confirmationDialog(L("Reset local installer?"), isPresented: $confirmReset, titleVisibility: .visible) {
                Button(L("Reset"), role: .destructive) {
                    InstallServer.shared.stop()
                    LocalCA.reset()
                    state.show(L("Local installer reset. Remove the old profile in Settings."))
                }
            }
            .onAppear {
                cacheSize = SignAppState.folderSize(SignPaths.work)
                installLog = InstallServer.shared.logLines()
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct InstallSetupView: View {
    @EnvironmentObject var state: SignAppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var phase
    @State private var trusted = false
    @State private var checking = false
    @State private var error: String?
    @State private var share: URL?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(SignTheme.gradient).frame(width: 96, height: 96)
                            Image(systemName: trusted ? "checkmark.shield.fill" : "lock.shield.fill").font(.system(size: 44)).foregroundColor(.white)
                        }
                        Spacer()
                    }
                    Text(trusted ? L("All set!") : L("One-time setup")).font(.title.weight(.bold)).frame(maxWidth: .infinity)
                    Text(L("iOS only installs apps over HTTPS. NVDAppleIDDownload made a private certificate authority on this iPhone, its key never leaves the device. Trust it once and installs work offline forever."))
                        .font(.callout).foregroundColor(.secondary)
                    step(1, L("Download the profile"), L("Tap the button and allow the download in Safari.")) {
                        Button(L("Download profile")) { Task { await openProfile() } }.buttonStyle(SmallButtonStyle()).nvdBorderBeam(shape: .rounded(9))
                    }
                    step(2, L("Install it"), L("Settings → General → VPN & Device Management → NVDAppleIDDownload Local Installer → Install.")) {
                        Button(L("Open Settings")) {
                            if let u = URL(string: "App-prefs:General&path=ManagedConfigurationList") ?? URL(string: UIApplication.openSettingsURLString) {
                                Task { @MainActor in _ = await UIApplication.shared.open(u) }
                            }
                        }.buttonStyle(SmallButtonStyle(filled: false)).nvdBorderBeam(shape: .rounded(9))
                    }
                    step(3, L("Enable full trust"), L("Settings → General → About → Certificate Trust Settings → turn on NVDAppleIDDownload Local CA.")) { EmptyView() }
                    if let e = error { Text(e).foregroundColor(.red).font(.callout) }
                    Button {
                        if trusted { dismiss() } else { Task { await check() } }
                    } label: {
                        HStack {
                            if checking { ProgressView().tint(.white) }
                            Text(trusted ? L("Done") : L("Check again"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .nvdBorderBeam(shape: .rounded(13))
                    Button(L("Save profile to Files instead")) {
                        if let d = LocalCA.mobileconfig() {
                            let u = SignPaths.work.appendingPathComponent("NVDAppleIDDownload.mobileconfig")
                            try? d.write(to: u)
                            share = u
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.footnote)
                    .nvdBorderBeam(shape: .rounded(10))
                }
                .padding(20)
            }
            .navigationTitle(L("Local installer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() }.nvdBorderBeam(shape: .rounded(10)) } }
            .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { ShareSheet(items: [$0.url]) }
            .task { await check() }
            .onChange(of: phase) { p in if p == .active { Task { await check() } } }
        }
    }

    func step<V: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder action: () -> V) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).foregroundColor(.white).frame(width: 30, height: 30).background(Circle().fill(SignTheme.gradient))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundColor(.secondary)
                action()
            }
        }
    }

    func openProfile() async {
        do {
            try InstallServer.shared.start(port: state.settings.serverPort)
            InstallServer.shared.keepAlive(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { InstallServer.shared.keepAlive(false) }
            if let u = URL(string: "\(InstallServer.shared.httpBase)/ca.mobileconfig") { await UIApplication.shared.open(u) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func check() async {
        checking = true
        defer { checking = false }
        do {
            try InstallServer.shared.start(port: state.settings.serverPort)
            trusted = await SignInstaller.trusted(port: state.settings.serverPort)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if trusted { InstallServer.shared.keepAlive(false) }
    }
}
#endif
