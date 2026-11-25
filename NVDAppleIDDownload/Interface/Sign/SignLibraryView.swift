#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var state: SignAppState
    @State private var importing = false
    @State private var urlPrompt = false
    @State private var urlText = ""
    @State private var segment = 0
    @State private var share: URL?
    @State private var setup = false
    @State private var search = ""

    var filteredLibrary: [LibraryApp] {
        search.isEmpty ? state.library : state.library.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    var filteredSigned: [SignedApp] {
        search.isEmpty ? state.signed : state.signed.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    Picker("", selection: $segment) {
                        Text(L("Imported")).tag(0)
                        Text(L("Signed apps")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    ForEach(state.downloads) { d in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(d.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(d.progress * 100))%").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                }
                                ProgressView(value: d.progress).tint(SignTheme.rose)
                                Text(d.status).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if segment == 0 {
                        if filteredLibrary.isEmpty && state.downloads.isEmpty {
                            EmptyState(title: L("No apps yet"), subtitle: L("Import an .ipa from Files, open one with NVDAppleIDDownload, or grab apps from a source."))
                        }
                        ForEach(filteredLibrary) { app in
                            LibraryRow(app: app)
                                .contextMenu {
                                    Button { state.pendingSign = app } label: { Label(L("Sign"), systemImage: "signature") }
                                    Button { Task { await state.addUnsigned(app) } } label: {
                                        Label(L("Install without re-signing"), systemImage: "arrow.down.app")
                                    }
                                    .disabled(LiveContainerGuest.isGuest)
                                    Button(role: .destructive) { state.deleteLibrary(app) } label: { Label(L("Delete"), systemImage: "trash") }
                                }
                        }
                    } else {
                        if filteredSigned.isEmpty {
                            EmptyState(title: L("Nothing signed yet"), subtitle: L("Signed apps appear here, ready to install or share."))
                        }
                        ForEach(filteredSigned) { app in
                            SignedRow(app: app, share: $share, setup: $setup)
                                .contextMenu {
                                    Button { share = state.ipaURL(app) } label: { Label(L("Share IPA"), systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { state.deleteSigned(app) } label: { Label(L("Delete"), systemImage: "trash") }
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("NVDAppleIDDownload")
            .searchable(text: $search, prompt: L("Search apps"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label(L("Import from Files"), systemImage: "folder") }
                            // Đợt 5, build 17: guest trong LiveContainer
                            // không nhập file được — nút mờ đi.
                            .disabled(LiveContainerGuest.isGuest)
                        Button { urlPrompt = true } label: { Label(L("Download from URL"), systemImage: "link") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipa, .tipa, .zip, .data], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r {
                    Task { for u in urls { await state.importIPA(u) } }
                }
            }
            .alert(L("Download from URL"), isPresented: $urlPrompt) {
                TextField("https://…/app.ipa", text: $urlText)
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Download")) {
                    if let u = URL(string: urlText.trimmingCharacters(in: .whitespaces)) {
                        Task { await state.download(u, name: u.lastPathComponent) }
                    }
                    urlText = ""
                }
            }
            .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(isPresented: $setup) {
                InstallSetupView().environmentObject(state)
            }
        }
        .navigationViewStyle(.stack)
    }

    var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(SignTheme.gradient).frame(width: 52, height: 52)
                Image(.pigLogo).resizable().frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let c = state.selectedCertificate {
                    Text(c.nickname).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(status: c.ocsp, expired: c.isExpired)
                        Text(LF("%d days left", c.daysLeft)).font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Text(L("No certificate")).font(.headline)
                    Text(L("Add a .p12 or sign in with Apple ID")).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(L("Change")) { state.tab = 1 }.buttonStyle(SmallButtonStyle(filled: false)).nvdBorderBeam(shape: .rounded(9))
        }
        .padding(14)
        .glassy()
        .nvdBorderBeam(shape: .rounded(20))
        .padding(.top, 6)
    }
}

struct ShareItem: Identifiable {
    var id: String { url.path }
    let url: URL
}

struct StatusDot: View {
    let status: OCSPStatus
    let expired: Bool
    var color: Color {
        if expired { return .gray }
        switch status {
        case .good: return .green
        case .revoked: return .red
        default: return .orange
        }
    }
    var text: String {
        if expired { return L("Expired") }
        switch status {
        case .good: return L("Signed")
        case .revoked: return L("Revoked")
        case .unknown: return L("Unknown")
        case .unchecked: return L("Checking…")
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.semibold)).foregroundColor(color)
        }
    }
}

struct LibraryRow: View {
    @EnvironmentObject var state: SignAppState
    let app: LibraryApp
    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppIconView(image: state.icon(for: app))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text(app.bundleID).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Pill(text: "v" + app.version)
                        Pill(text: formatSize(app.size), color: .secondary)
                        if app.encrypted { Pill(text: L("Encrypted"), color: .red) }
                    }
                }
                Spacer(minLength: 6)
                Button(L("Sign")) { state.pendingSign = app }.buttonStyle(SmallButtonStyle()).nvdBorderBeam(shape: .rounded(9))
            }
        }
    }
}

struct SignedRow: View {
    @EnvironmentObject var state: SignAppState
    let app: SignedApp
    @Binding var share: URL?
    @Binding var setup: Bool
    @State private var installing = false

    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppIconView(image: app.libraryID.flatMap { id in state.library.first { $0.id == id } }.flatMap { state.icon(for: $0) })
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text(app.bundleID).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Pill(text: "v" + app.version)
                        Pill(text: app.certificateName, color: .secondary)
                        if !app.tweaks.isEmpty { Pill(text: LF("%d tweaks", app.tweaks.count), color: .purple) }
                        if app.container == true { Pill(text: L("Inside NVDAppleIDDownload"), color: .teal) }
                    }
                }
                Spacer(minLength: 6)
                VStack(spacing: 6) {
                    if app.container == true {
                        Button { runInside() } label: { Text(L("Run")) }
                            .buttonStyle(SmallButtonStyle())
                            .nvdBorderBeam(shape: .rounded(9))
                    } else {
                        Button {
                            Task { await install() }
                        } label: {
                            if installing { ProgressView().tint(.white) } else { Text(L("Install")) }
                        }
                        .buttonStyle(SmallButtonStyle())
                        .nvdBorderBeam(shape: .rounded(9))
                        .disabled(LiveContainerGuest.isGuest || installing)
                    }
                    Button { share = state.ipaURL(app) } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(SmallButtonStyle(filled: false))
                        .nvdBorderBeam(shape: .rounded(9))
                }
            }
        }
    }

    func runInside() {
        do {
            state.show(LF("%@ starts when you open NVDAppleIDDownload again", app.name))
            try Container.run(app, ipa: state.ipaURL(app))
        } catch {
            state.show(error.localizedDescription)
        }
    }

    func install() async {
        installing = true
        defer { installing = false }
        do {
            if try await SignInstaller.install(app, state: state) {
                state.show(LF("%@ is installed", app.name))
            } else {
                state.show(L("Confirm the install prompt, keep NVDAppleIDDownload open until the icon finishes"))
            }
        } catch is InstallNeedsSetup {
            setup = true
        } catch {
            state.show(error.localizedDescription)
        }
    }
}
#endif
