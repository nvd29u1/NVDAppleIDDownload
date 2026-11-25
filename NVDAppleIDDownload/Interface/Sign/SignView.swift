#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct SignView: View {
    @EnvironmentObject var state: SignAppState
    @Environment(\.dismiss) var dismiss
    let app: LibraryApp

    @State private var name = ""
    @State private var bundleID = ""
    /// With an explicit-ID .p12 profile: keep each app's own bundle ID (like other signers do).
    @State private var keepOwnID = true
    @State private var version = ""
    @State private var minIOS = ""
    @State private var iconURL: URL?
    @State private var iconImage: UIImage?
    @State private var tweaks: [URL] = []
    @State private var entitlements: URL?
    @State private var removePlugins = false
    @State private var removeWatch = true
    @State private var removeSchemes = false
    @State private var fileSharing = false
    @State private var inside = false
    @State private var certID: UUID?
    @State private var progress: Double = 0
    @State private var stage = ""
    @State private var signing = false
    @State private var done: SignedApp?
    @State private var error: String?
    @State private var setup = false

    enum PickKind: Identifiable {
        case icon, tweak, entitlements
        var id: Int { hashValue }
    }

    var cert: StoredCertificate? {
        if let id = certID { return state.certificates.first { $0.id == id } }
        return state.selectedCertificate
    }

    /// The profile's single bundle ID for an explicit .p12 profile (Apple ID profiles are made per app).
    var explicitBundle: String? {
        guard let c = cert, !c.fromAppleID, !c.profile.isWildcard else { return nil }
        return c.profile.bundleID
    }

    var forcedBundle: String? { keepOwnID ? nil : explicitBundle }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Button { pick(.icon) } label: {
                            ZStack(alignment: .bottomTrailing) {
                                AppIconView(image: iconImage ?? state.icon(for: app), size: 66)
                                Image(systemName: "pencil.circle.fill").font(.title3).foregroundColor(SignTheme.rose).background(Circle().fill(Color.white))
                            }
                        }
                        .buttonStyle(.plain)
                        .nvdBorderBeam(shape: .rounded(15))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.title3.weight(.bold))
                            Text("\(app.bundleID) · v\(app.version)").font(.caption).foregroundColor(.secondary)
                            if app.encrypted {
                                Text(L("This IPA is encrypted and will not run. Use a decrypted IPA.")).font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text(L("Certificate"))) {
                    if state.certificates.isEmpty {
                        Button(L("Add a certificate first")) { dismiss(); state.tab = 1 }.nvdBorderBeam(shape: .rounded(10))
                    } else {
                        Picker(L("Certificate"), selection: Binding(get: { cert?.id }, set: { certID = $0 })) {
                            ForEach(state.certificates) { c in
                                Text(c.nickname).tag(Optional(c.id))
                            }
                        }
                        if let c = cert {
                            HStack {
                                StatusDot(status: c.ocsp, expired: c.isExpired)
                                Spacer()
                                Text(c.profile.isWildcard ? L("Wildcard profile") : c.profile.bundleID).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text(L("App")), footer: explicitBundle.map { fb in
                    Text(keepOwnID
                         ? LF("This profile is made for %@. The app keeps its own bundle ID, so several apps can be installed side by side; app extensions are removed.", fb)
                         : LF("This profile only allows %@, the bundle ID will be replaced and app extensions removed.", fb)
                           + (fb.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
                              ? "\n\n⚠️ " + L("NVDAppleIDDownload itself has this bundle ID. An app signed with this certificate cannot be installed while NVDAppleIDDownload uses the same ID.")
                              : ""))
                }) {
                    if explicitBundle != nil {
                        Toggle(L("Keep the app's own bundle ID"), isOn: $keepOwnID)
                    }
                    LabeledField(title: L("Name"), text: $name, placeholder: app.name)
                    LabeledField(title: L("Bundle ID"), text: $bundleID, placeholder: forcedBundle ?? app.bundleID)
                        .disabled(forcedBundle != nil)
                    LabeledField(title: L("Version"), text: $version, placeholder: app.version)
                    LabeledField(title: L("Minimum iOS"), text: $minIOS, placeholder: app.minOS)
                }

                Section(header: Text(L("Tweaks")), footer: Text(L("Supports .dylib, .deb and .framework. Substrate, ElleKit and libhooker tweaks are wired to SayoHook automatically."))) {
                    ForEach(tweaks, id: \.self) { t in
                        HStack {
                            Image(systemName: t.pathExtension == "deb" ? "shippingbox.fill" : "puzzlepiece.extension.fill").foregroundColor(SignTheme.rose)
                            Text(t.lastPathComponent).lineLimit(1)
                        }
                    }
                    .onDelete { tweaks.remove(atOffsets: $0) }
                    let saved = savedTweaks()
                    if !saved.isEmpty {
                        Menu {
                            ForEach(saved, id: \.self) { u in
                                Button(u.lastPathComponent) { if !tweaks.contains(u) { tweaks.append(u) } }
                            }
                        } label: { Label(L("Add saved tweak"), systemImage: "tray.full") }
                    }
                    Button { pick(.tweak) } label: { Label(L("Add tweak from Files"), systemImage: "plus") }.nvdBorderBeam(shape: .rounded(10))
                }

                Section(header: Text(L("Options"))) {
                    Toggle(L("Remove app extensions"), isOn: $removePlugins)
                    Toggle(L("Remove Apple Watch app"), isOn: $removeWatch)
                    Toggle(L("Remove URL schemes"), isOn: $removeSchemes)
                    Toggle(L("Enable file sharing"), isOn: $fileSharing)
                    Toggle(isOn: $inside) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Run inside NVDAppleIDDownload (experimental)"))
                            Text(L("Like LiveContainer: not installed in iOS, no app limit. Use the same certificate NVDAppleIDDownload itself is signed with."))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Button { pick(.entitlements) } label: {
                        HStack {
                            Text(L("Extra entitlements"))
                            Spacer()
                            Text(entitlements?.lastPathComponent ?? L("None")).foregroundColor(.secondary)
                        }
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                }

                if signing {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress).tint(SignTheme.rose)
                            Text(stageName(stage)).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let e = error {
                    Section { Text(e).foregroundColor(.red).font(.callout) }
                }
                if let s = done, s.container == true {
                    Section(footer: Text(L("NVDAppleIDDownload closes; open it again and the app starts inside it. Close that app and open NVDAppleIDDownload again to come back."))) {
                        Button {
                            do { try Container.run(s, ipa: state.ipaURL(s)) } catch { self.error = error.localizedDescription }
                        } label: { Label(L("Run inside NVDAppleIDDownload"), systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .listRowBackground(Color.clear)
                            .nvdBorderBeam(shape: .rounded(13))
                    }
                } else if let s = done {
                    Section {
                        Button {
                            Task {
                                do {
                                    try await SignInstaller.install(s, state: state)
                                    dismiss()
                                } catch is InstallNeedsSetup {
                                    setup = true
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        } label: { Label(L("Install now"), systemImage: "arrow.down.app.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                            .listRowBackground(Color.clear)
                            .nvdBorderBeam(shape: .rounded(13))
                            // Đợt 5, build 17: guest trong LiveContainer
                            // không cài được — nút mờ đi, banner ở đầu
                            // tab Ký IPA đã giải thích.
                            .disabled(LiveContainerGuest.isGuest)
                        // Đợt 5, build 17: nối nút vào openTrollStore đã
                        // có sẵn (trước đây dead code, 0 caller). Chỉ
                        // hiện khi máy đã cài TrollStore; chỉ cần file
                        // .ipa chuẩn, không cần .tipa.
                        if SignInstaller.trollStoreAvailable {
                            Button {
                                if !SignInstaller.openTrollStore(state.ipaURL(s)) {
                                    self.error = L("TrollStore is not installed")
                                }
                            } label: { Label(L("Install with TrollStore"), systemImage: "arrow.down.app") }
                                .buttonStyle(PrimaryButtonStyle())
                                .listRowBackground(Color.clear)
                                .nvdBorderBeam(shape: .rounded(13))
                        }
                    }
                } else {
                    Section {
                        Button { Task { await sign() } } label: {
                            HStack {
                                if signing { ProgressView().tint(.white) }
                                Text(signing ? L("Signing…") : L("Sign"))
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .nvdBorderBeam(shape: .rounded(13))
                        .disabled(signing || cert == nil)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(L("Sign"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() }.nvdBorderBeam(shape: .rounded(10)) }
            }
            .sheet(isPresented: $setup) { InstallSetupView().environmentObject(state) }
            .onAppear {
                removePlugins = state.settings.autoRemovePlugins
                removeWatch = state.settings.removeWatchApps
            }
        }
        .interactiveDismissDisabled(signing)
    }

    /// The kind travels with the request, so the result is filed correctly.
    func pick(_ kind: PickKind) {
        let types: [UTType]
        switch kind {
        case .icon: types = [.png, .jpeg, .image]
        case .tweak: types = [.deb, .dylib, .folder, .data]
        case .entitlements: types = [.xml, .propertyList, .data]
        }
        FilePicker.shared.pick(types, multiple: kind == .tweak) { urls in
            for u in urls { take(u, kind: kind) }
        }
    }

    func savedTweaks() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: SignPaths.tweaks, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func take(_ u: URL, kind: PickKind?) {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        switch kind {
        case .icon:
            if let img = UIImage(contentsOfFile: u.path) ?? (try? Data(contentsOf: u)).flatMap(UIImage.init(data:)) {
                let size = CGSize(width: 180, height: 180)
                let r = UIGraphicsImageRenderer(size: size)
                let out = r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
                let dst = SignPaths.work.appendingPathComponent("icon-\(UUID().uuidString).png")
                try? out.pngData()?.write(to: dst)
                iconURL = dst
                iconImage = out
            }
        case .tweak:
            let dst = SignPaths.tweaks.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: u, to: dst)
                if !tweaks.contains(dst) { tweaks.append(dst) }
            } catch {
                self.error = error.localizedDescription
            }
        case .entitlements:
            let dst = SignPaths.work.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: u, to: dst)
            entitlements = dst
        case .none:
            break
        }
    }

    func stageName(_ s: String) -> String {
        switch s {
        case "copy": return L("Preparing")
        case "prepare": return L("Patching Info.plist")
        case "inject": return L("Injecting tweaks")
        case "sign": return L("Signing binaries")
        case "zip": return L("Packing IPA")
        default: return s
        }
    }

    func sign() async {
        guard let c = cert else { error = L("Choose a certificate"); return }
        error = nil
        signing = true
        progress = 0
        stage = "copy"
        defer { signing = false }
        var opts = SayoCore.SignOptions()
        opts.bundleID = bundleID.trimmingCharacters(in: .whitespaces)
        // An explicit .p12 profile would otherwise rename every app to the profile's ID.
        if opts.bundleID.isEmpty && keepOwnID && explicitBundle != nil { opts.bundleID = app.bundleID }
        opts.displayName = name.trimmingCharacters(in: .whitespaces)
        opts.shortVersion = version.trimmingCharacters(in: .whitespaces)
        opts.minIOS = minIOS.trimmingCharacters(in: .whitespaces)
        opts.iconPNG = iconURL
        opts.entitlements = entitlements
        opts.removePlugins = removePlugins
        opts.removeWatch = removeWatch
        opts.removeURLSchemes = removeSchemes
        opts.fileSharing = fileSharing
        opts.container = inside
        do {
            let result = try await state.performSign(app: app, cert: c, options: opts, tweaks: tweaks) { f, s in
                self.progress = f
                self.stage = s
            }
            progress = 1
            done = result
            state.show(LF("%@ is signed", result.name))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.secondary)
        }
    }
}
#endif
