#if os(iOS)
import SwiftUI

/// Root of the "Ký IPA" tab: the whole signing feature (library, certificates,
/// sources, sign settings) with its own 4-way switcher at the bottom, toast +
/// busy overlays, the certificate-import sheet and the sign sheet.
///
/// The switcher is a plain button bar, not a nested TabView (two tab bars
/// stacked look broken). The index lives in SignAppState.tab, so deep links
/// and buttons (handleOpen, "Change", ...) keep working exactly as before.
struct SignRootView: View {
    @EnvironmentObject var state: SignAppState
    @EnvironmentObject var certImport: CertificateImportCoordinator
    @Environment(\.scenePhase) var phase

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Đợt 5, build 17: chạy dạng guest trong LiveContainer thì
                // nhập file/cài đặt không hoạt động được (đã chứng minh với
                // NVDsign 24/11) — báo rõ ngay đầu tab thay vì lỗi lặng lẽ.
                if LiveContainerGuest.isGuest {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("Running inside LiveContainer: file import and install don't work here. Install the real app via SideStore or AltStore to use them."))
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }
                Group {
                    switch state.tab {
                    case 1:
                        CertificatesView()
                    case 2:
                        SourcesView()
                    case 3:
                        SignSettingsView()
                    default:
                        LibraryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                signTabBar
            }
            if let t = state.toast {
                ToastView(text: t)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .onTapGesture { state.toast = nil }
                    .zIndex(10)
            }
            if let b = state.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(b).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassy()
                .padding(.top, 8)
                .zIndex(9)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.toast)
        .sheet(isPresented: $certImport.presented) {
            ImportCertificateView(prefillP12: certImport.p12, prefillProfile: certImport.profile)
                .environmentObject(state)
        }
        .sheet(item: $state.pendingSign) { app in
            SignView(app: app).environmentObject(state)
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await state.scanInbox() } }
        }
        .task {
            if Diagnostics.enabled { await Diagnostics.run(state) }
            await state.scanInbox()
            if state.certificates.contains(where: { $0.ocspChecked == nil || $0.ocspChecked! < Date().addingTimeInterval(-3600) }) {
                await state.refreshAllOCSP()
            }
        }
        .tint(SignTheme.rose)
        .preferredColorScheme(state.settings.appearance == 1 ? .light : state.settings.appearance == 2 ? .dark : nil)
    }

    private var signTabBar: some View {
        HStack(spacing: 0) {
            signTabButton(index: 0, title: L("Library"), systemImage: "square.stack.3d.up.fill")
            signTabButton(index: 1, title: L("Certificates"), systemImage: "checkmark.seal.fill")
            signTabButton(index: 2, title: L("Sources"), systemImage: "globe")
            signTabButton(index: 3, title: L("Settings"), systemImage: "gearshape.fill")
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)
    }

    private func signTabButton(index: Int, title: String, systemImage: String) -> some View {
        Button { state.tab = index } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(state.tab == index ? SignTheme.rose : .secondary)
        }
        .buttonStyle(.plain)
    }
}
#endif
