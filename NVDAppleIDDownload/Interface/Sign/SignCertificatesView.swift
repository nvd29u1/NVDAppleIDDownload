#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject var state: SignAppState
    @State private var adding = false
    @State private var appleID = false
    @State private var checking = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Button { adding = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus").font(.title2)
                                Text(L("Import .p12")).font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                        }
                        .buttonStyle(.plain)
                        .glassy()
                        .nvdBorderBeam(shape: .rounded(20))
                        // Đợt 5, build 17: guest trong LiveContainer
                        // không nhập file được — nút mờ đi.
                        .disabled(LiveContainerGuest.isGuest)
                        Button { appleID = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "applelogo").font(.title2)
                                Text(L("Apple ID")).font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                        }
                        .buttonStyle(.plain)
                        .glassy()
                        .nvdBorderBeam(shape: .rounded(20))
                    }
                    .foregroundColor(SignTheme.rose)
                    .padding(.top, 6)

                    if state.certificates.isEmpty {
                        EmptyState(title: L("No certificates"), subtitle: L("Import a .p12 with its .mobileprovision, or sign in with a free Apple ID."))
                    }
                    ForEach(state.certificates) { c in
                        CertificateCard(cert: c)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("Certificates"))
            .refreshable { await state.refreshAllOCSP() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            checking = true
                            await state.refreshAllOCSP()
                            checking = false
                            state.show(L("Certificate status updated"))
                        }
                    } label: {
                        if checking { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                }
            }
            .sheet(isPresented: $adding) { ImportCertificateView(prefillP12: nil, prefillProfile: nil).environmentObject(state) }
            .sheet(isPresented: $appleID) { AppleIDView().environmentObject(state) }
        }
        .navigationViewStyle(.stack)
    }
}

struct CertificateCard: View {
    @EnvironmentObject var state: SignAppState
    let cert: StoredCertificate
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var manage = false
    @State private var showDevices = false

    var selected: Bool { state.selectedCertificate?.id == cert.id }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(cert.nickname).font(.headline).lineLimit(1)
                            if cert.fromAppleID { Image(systemName: "applelogo").font(.caption) }
                        }
                        Text(cert.details.subject).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(SignTheme.rose)
                    } else {
                        Button(L("Use")) { state.settings.selectedCertificate = cert.id }.buttonStyle(SmallButtonStyle(filled: false)).nvdBorderBeam(shape: .rounded(9))
                    }
                }
                HStack(spacing: 8) {
                    StatusDot(status: cert.ocsp, expired: cert.isExpired)
                    Pill(text: LF("%d days left", cert.daysLeft), color: cert.daysLeft < 14 ? .orange : SignTheme.coral)
                    Pill(text: cert.profile.isWildcard ? L("Wildcard") : L("Explicit ID"), color: .secondary)
                }
                if let r = cert.revokedAt {
                    Text(LF("Revoked on %@", dateFormatter.string(from: r))).font(.caption).foregroundColor(.red)
                }
                if expanded {
                    Divider()
                    InfoRow(L("Team"), "\(cert.profile.teamName) (\(cert.details.team))")
                    InfoRow(L("Type"), cert.details.subject.components(separatedBy: ":").first ?? "")
                    InfoRow(L("Issuer"), cert.details.issuer)
                    InfoRow(L("Serial"), cert.details.serial)
                    InfoRow(L("Certificate expires"), dateFormatter.string(from: cert.details.notAfter))
                    InfoRow(L("Profile"), cert.profile.name)
                    InfoRow(L("App ID"), cert.profile.appID)
                    InfoRow(L("Profile expires"), dateFormatter.string(from: cert.profile.expiration))
                    InfoRow(L("Devices"), cert.profile.allDevices ? L("All (enterprise)") : "\(cert.profile.devices.count)")
                    if !cert.profile.devices.isEmpty {
                        Button { withAnimation { showDevices.toggle() } } label: {
                            Text(showDevices ? L("Hide UDIDs") : L("Show UDIDs")).font(.caption.weight(.semibold))
                        }
                        .nvdBorderBeam(shape: .rounded(10))
                        if showDevices {
                            ForEach(cert.profile.devices, id: \.self) { u in
                                Text(u + (u.uppercased() == state.settings.udid.uppercased() ? "  ← " + L("This iPhone") : ""))
                                    .font(.caption2.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    InfoRow(L("Debuggable"), cert.profile.getTaskAllow ? L("Yes") : L("No"))
                    if let d = cert.ocspChecked { InfoRow(L("Checked"), RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Entitlements")).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Text(cert.profile.entitlementKeys.map { $0.replacingOccurrences(of: "com.apple.developer.", with: "") }.joined(separator: " · "))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    if cert.fromAppleID {
                        Button { manage = true } label: { Label(L("Manage Apple ID account"), systemImage: "person.badge.key") }
                            .buttonStyle(SmallButtonStyle(filled: false))
                            .nvdBorderBeam(shape: .rounded(9))
                    }
                    HStack {
                        Button {
                            Task { await state.refreshOCSP(cert) }
                        } label: { Label(L("Check now"), systemImage: "arrow.clockwise") }
                            .buttonStyle(SmallButtonStyle(filled: false))
                            .nvdBorderBeam(shape: .rounded(9))
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Label(L("Delete"), systemImage: "trash") }
                            .buttonStyle(SmallButtonStyle(filled: false))
                            .nvdBorderBeam(shape: .rounded(9))
                    }
                }
            }
        }
        .onTapGesture { withAnimation(.spring()) { expanded.toggle() } }
        .sheet(isPresented: $manage) { AppleAccountView(cert: cert).environmentObject(state) }
        .confirmationDialog(L("Delete this certificate?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { state.deleteCertificate(cert) }
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    init(_ t: String, _ v: String) { title = t; value = v }
    var body: some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.caption.weight(.medium)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

struct ImportCertificateView: View {
    @EnvironmentObject var state: SignAppState
    @Environment(\.dismiss) var dismiss
    @State var prefillP12: URL?
    @State var prefillProfile: URL?
    @State private var p12: URL?
    @State private var profile: URL?
    @State private var password = ""
    @State private var nickname = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("Files")), footer: Text(L("Tip: you can select the .p12 and the .mobileprovision together."))) {
                    Button { pickFiles() } label: {
                        HStack {
                            Label(L("Certificate (.p12)"), systemImage: "key.fill")
                            Spacer()
                            Text(p12?.lastPathComponent ?? L("Choose")).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                    .disabled(LiveContainerGuest.isGuest)
                    Button { pickFiles() } label: {
                        HStack {
                            Label(L("Profile (.mobileprovision)"), systemImage: "doc.text.fill")
                            Spacer()
                            Text(profile?.lastPathComponent ?? L("Choose")).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .nvdBorderBeam(shape: .rounded(10))
                    .disabled(LiveContainerGuest.isGuest)
                }
                Section(header: Text(L("Details"))) {
                    SecureField(L("Password"), text: $password)
                    TextField(L("Nickname (optional)"), text: $nickname)
                }
                if let e = error { Section { Text(e).foregroundColor(.red) } }
                Section {
                    Button(L("Import")) { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(p12 == nil || profile == nil)
                        .listRowBackground(Color.clear)
                        .nvdBorderBeam(shape: .rounded(13))
                }
            }
            .navigationTitle(L("Add certificate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() }.nvdBorderBeam(shape: .rounded(10)) } }
            .onAppear {
                if p12 == nil { p12 = prefillP12 }
                if profile == nil { profile = prefillProfile }
                CertificateImportCoordinator.shared.p12 = nil
                CertificateImportCoordinator.shared.profile = nil
                if let p = p12 { autoProfile(near: p) }
            }
        }
    }

    func pickFiles() {
        FilePicker.shared.pick([.item], multiple: true) { urls in
            error = nil
            for u in urls { take(u) }
        }
    }

    /// Reads a picked file (a copy the picker made for us), then files it as the certificate or the profile by looking at its contents.
    func take(_ u: URL) {
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var readError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &readError) { url in
            data = try? Data(contentsOf: url)
        }
        guard let d = data, !d.isEmpty else {
            error = L("Cannot read the selected files") + (readError.map { ": " + $0.localizedDescription } ?? "")
            return
        }
        let ext = u.pathExtension.lowercased()
        let looksLikeProfile = ext == "mobileprovision" || d.range(of: Data("<plist".utf8)) != nil
        let looksLikeP12 = ext == "p12" || ext == "pfx" || (!looksLikeProfile && d.first == 0x30)
        let isProfile = looksLikeProfile && !(ext == "p12" || ext == "pfx")
        guard isProfile || looksLikeP12 else {
            error = L("This is not a .p12 or .mobileprovision file") + ": " + u.lastPathComponent
            return
        }
        let dst = SignPaths.work.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent)
        do {
            try d.write(to: dst)
        } catch {
            self.error = error.localizedDescription
            return
        }
        // The picker hands us a private copy; its folder may hold stale files, so no autoProfile here.
        try? FileManager.default.removeItem(at: u)
        if isProfile { profile = dst } else { p12 = dst }
    }

    func autoProfile(near p: URL) {
        guard profile == nil else { return }
        let dir = p.deletingLastPathComponent()
        if let f = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "mobileprovision" }) {
            profile = f
        }
    }

    func save() {
        guard let p = p12, let m = profile, let pd = try? Data(contentsOf: p), let md = try? Data(contentsOf: m) else {
            error = L("Cannot read the selected files")
            return
        }
        do {
            _ = try state.addCertificate(p12: pd, profile: md, password: password, nickname: nickname)
            state.show(L("Certificate added"))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
