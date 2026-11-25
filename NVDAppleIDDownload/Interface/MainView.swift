//
//  MainView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Shared tab selection for iOS (LegacyTabMainView + NewMainView), so a
/// button deep in Downloads can jump to the "Ký IPA" tab after importing
/// a downloaded IPA for signing.
/// Thứ tự tab (anh chốt 16:01 25/11, build 13): Ký IPA, Tìm kiếm,
/// Lượt tải, Tài khoản hiện trực tiếp; Đã mua, Đang theo dõi, Cài đặt
/// ở menu Thêm (iPhone chỉ hiện 4 tab). Tab mặc định khi mở app vẫn
/// là Lượt tải (`MainTabSelection.tab`).
enum MainTab: Hashable {
    case accounts
    case search
    case downloads
    case sign
    case purchased
    case watchlist
    case settings
}

@MainActor
@Observable
final class MainTabSelection {
    static let shared = MainTabSelection()
    var tab = MainTab.downloads
}

struct MainView: View {
    var body: some View {
        #if os(macOS)
            MacSidebarMainView()
        #else
            LegacyTabMainView()
        #endif
    }
}

#if os(macOS)
    private struct MacSidebarMainView: View {
        @State private var selection: SidebarSection? = .accounts
        @State private var downloads = Downloads.this

        var body: some View {
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $selection) { section in
                    SidebarRow(section: section, downloads: downloads.runningTaskCount)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 150, ideal: 150, max: 200)
            } detail: {
                Group {
                    if let selection {
                        detailView(for: selection)
                    } else {
                        detailView(for: .accounts)
                    }
                }
                .frame(minHeight: 250)
                .navigationSplitViewColumnWidth(min: 480, ideal: 500)
            }
            // Expose the selection so menu commands (⌘,) can drive it.
            .focusedSceneValue(\.sidebarSelection, $selection)
        }

        @ViewBuilder
        private func detailView(for section: SidebarSection) -> some View {
            switch section {
            case .accounts:
                AccountView()
            case .search:
                SearchView()
            case .downloads:
                DownloadView()
            case .sign:
                SignUnavailableView()
            case .purchased:
                PurchasedView()
            case .watchlist:
                WatchlistView()
            case .settings:
                SettingView()
            }
        }
    }

    /// The signing feature is iOS-only (UIKit UI + on-device installer),
    /// so on macOS this section only explains that.
    private struct SignUnavailableView: View {
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "signature").font(.largeTitle)
                Text("Ký IPA chỉ có trên iPhone")
                    .font(.headline)
                Text("Tính năng ký IPA (chứng chỉ .p12 / Apple ID, chèn tweak, cài offline) chỉ chạy trên iOS. Trên Mac, tải IPA về rồi ký trên iPhone.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    enum SidebarSection: Hashable, CaseIterable, Identifiable {
        case sign
        case search
        case downloads
        case accounts
        case purchased
        case watchlist
        case settings

        var id: Self {
            self
        }

        var title: LocalizedStringKey {
            switch self {
            case .accounts:
                "Accounts"
            case .search:
                "Search"
            case .purchased:
                "Đã mua"
            case .watchlist:
                "Đang theo dõi"
            case .downloads:
                "Downloads"
            case .sign:
                "Ký IPA"
            case .settings:
                "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .accounts:
                "person"
            case .search:
                "magnifyingglass"
            case .purchased:
                "bag"
            case .watchlist:
                "eye"
            case .downloads:
                "arrow.down.circle"
            case .sign:
                "signature"
            case .settings:
                "gear"
            }
        }
    }

    private struct SidebarRow: View {
        let section: SidebarSection
        let downloads: Int

        var body: some View {
            HStack {
                Label(section.title, systemImage: section.systemImage)
                if section == .downloads, downloads > 0 {
                    Spacer()
                    Text("\(downloads)")
                        .font(.caption2.bold())
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private struct SidebarSelectionKey: FocusedValueKey {
        typealias Value = Binding<SidebarSection?>
    }

    extension FocusedValues {
        var sidebarSelection: Binding<SidebarSection?>? {
            get { self[SidebarSelectionKey.self] }
            set { self[SidebarSelectionKey.self] = newValue }
        }
    }

    /// Menu commands that jump to sidebar sections by keyboard shortcut.
    struct SidebarMenuCommands: Commands {
        @FocusedValue(\.sidebarSelection) private var selection

        var body: some Commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { selection?.wrappedValue = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(selection == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Search") {
                    selection?.wrappedValue = .search
                    SearchFieldFocus.shared.requestFocus()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(selection == nil)
            }
            CommandGroup(replacing: .help) {
                Button("NVDAppleIDDownload Help", systemImage: "") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/nvd29u1/NVDAppleIDDownload")!)
                }
            }
        }
    }
#else
    private struct LegacyTabMainView: View {
        @State private var selection = MainTabSelection.shared
        @State var dvm = Downloads.this

        var body: some View {
            TabView(selection: $selection.tab) {
                SignRootView()
                    .tabItem { Label("Ký IPA", systemImage: "signature") }
                    .tag(MainTab.sign)
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(MainTab.search)
                DownloadView()
                    .tabItem {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    .badge(dvm.runningTaskCount) // putting badge inside will not work on iOS versions before 18
                    .tag(MainTab.downloads)
                AccountView()
                    .tabItem { Label("Accounts", systemImage: "person") }
                    .tag(MainTab.accounts)
                PurchasedView()
                    .tabItem { Label("Đã mua", systemImage: "bag") }
                    .tag(MainTab.purchased)
                WatchlistView()
                    .tabItem { Label("Đang theo dõi", systemImage: "eye") }
                    .tag(MainTab.watchlist)
                SettingView()
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(MainTab.settings)
            }
        }
    }

    @available(iOS 18.0, *)
    struct NewMainView: View {
        @State private var selection = MainTabSelection.shared
        @State var dvm = Downloads.this

        var body: some View {
            TabView(selection: $selection.tab) {
                Tab("Ký IPA", systemImage: "signature", value: .sign) { SignRootView() }
                Tab("Search", systemImage: "magnifyingglass", value: .search) { SearchView() }
                Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) { DownloadView() }
                    .badge(dvm.runningTaskCount)
                Tab("Accounts", systemImage: "person", value: .accounts) { AccountView() }
                Tab("Đã mua", systemImage: "bag", value: .purchased) { PurchasedView() }
                Tab("Đang theo dõi", systemImage: "eye", value: .watchlist) { WatchlistView() }
                Tab("Settings", systemImage: "gear", value: .settings) { SettingView() }
            }
            .neverMinimizeTab()
            .sidebarAdaptableTabView()
        }
    }
#endif
