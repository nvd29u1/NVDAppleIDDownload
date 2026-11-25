//
//  PackageView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import ButtonKit
import Kingfisher
import SwiftUI

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

struct PackageView: View {
    @State var pkg: PackageManifest

    var archive: AppStore.AppPackage {
        pkg.package
    }

    var url: URL {
        pkg.targetLocation
    }

    @Environment(\.dismiss) var dismiss
    #if os(iOS)
        @State private var installer: Installer?
        @State private var error: String = ""
        @State private var signImportMessage: String?
        @State private var showSignImportAlert = false
    #endif
    #if os(macOS)
        @State private var copied = false
    #endif

    @State private var vm = AppStore.this
    @State private var downloads = Downloads.this

    var body: some View {
        Form {
            Section {
                ArchivePreviewView(archive: archive)
            } header: {
                Text("Package")
            }

            Section {
                CopyableRow(label: "Bundle ID", value: archive.software.bundleID, monospaced: true)
                Text("Version")
                    .badge(archive.software.version)
                Text("Developer")
                    .badge(archive.software.sellerName)
                if !archive.software.primaryGenreName.isEmpty {
                    Text("Category")
                        .badge(archive.software.primaryGenreName)
                }
                Text("Compatibility")
                    .badge("\(archive.software.minimumOsVersion)+")
                if archive.software.userRatingCount > 0 {
                    Text("Rating")
                        .badge("\(String(format: "%.1f", archive.software.averageUserRating)) (\(archive.software.userRatingCount))")
                }
            } header: {
                Text("Details")
            }

            if pkg.completed {
                #if os(macOS)
                    DeviceCTLInstallSection(package: pkg)

                    Section {
                        ExportIPAButton(manifest: pkg)
                        // Giữ phiên bản này (đợt 3, build 8): đã giữ thì
                        // tab Lượt tải không nhắc "Có bản mới" nữa.
                        Button(pkg.pinned ? "Bỏ giữ phiên bản này" : "Giữ phiên bản này") {
                            downloads.setPinned(pkg, !pkg.pinned)
                        }
                    } header: {
                        Text("Control")
                    } footer: {
                        Text("File IPA vẫn mã hoá FairPlay và gắn với Apple ID đã mua — chỉ xuất đúng file đã tải, không giải mã.")
                    }
                #endif
                #if os(iOS)
                    Section {
                        AsyncButton {
                            installer = try await Installer(archive: archive, path: url, manifestServerURL: vm.manifestServerURL)
                        } label: {
                            Text("Install")
                        }
                        .disabledWhenLoading()
                        .sheet(item: $installer) {
                            installer?.destroy()
                            installer = nil
                        } content: {
                            InstallerView(installer: $0)
                        }

                        Button("Install via AirDrop") {
                            let newUrl = temporaryDirectory
                                .appendingPathComponent("\(archive.software.bundleID)-\(archive.software.version)")
                                .appendingPathExtension("ipa")
                            try? FileManager.default.removeItem(at: newUrl)
                            try? FileManager.default.copyItem(at: url, to: newUrl)
                            AirDrop(items: [newUrl])
                        }

                        // Xuất file IPA đã tải ra khỏi app: mở Share Sheet để
                        // lưu vào Tệp / AirDrop / chia sẻ qua app khác. File
                        // vẫn mã hoá FairPlay, chỉ xuất đúng file đã tải.
                        ExportIPAButton(manifest: pkg)

                        // Đưa IPA vừa tải sang tab Ký IPA (đợt 5, build 10):
                        // nhập vào thư viện ký rồi mở tab Ký IPA để ký
                        // (.p12 / Apple ID, chèn tweak) và cài offline.
                        Button("Ký IPA này") {
                            Task { await importToSign() }
                        }
                        .alert("Đã đưa vào Ký IPA", isPresented: $showSignImportAlert) {
                            Button("Mở tab Ký IPA") { MainTabSelection.shared.tab = .sign }
                            Button("Để sau", role: .cancel) {}
                        } message: {
                            if let signImportMessage { Text(signImportMessage) }
                        }

                        // Giữ phiên bản này (đợt 3, build 8): đã giữ thì
                        // tab Lượt tải không nhắc "Có bản mới" nữa.
                        Button(pkg.pinned ? "Bỏ giữ phiên bản này" : "Giữ phiên bản này") {
                            downloads.setPinned(pkg, !pkg.pinned)
                        }
                    } header: {
                        Text("Control")
                    } footer: {
                        if error.isEmpty {
                            Text("Direct install may have limitations that cannot be bypassed. Use AirDrop if possible on another device.")
                        } else {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                #endif

                Section {
                    // Xem nội dung IPA (đợt 3, build 8): liệt kê file trong
                    // ZIP, xem trước file text/ảnh nhỏ, trích 1 file ra
                    // Share Sheet (xem FileListView / FileAnalysisView).
                    NavigationLink("Xem nội dung IPA") {
                        FileListView(packageURL: pkg.targetLocation)
                    }
                    #if os(macOS)
                        HStack {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Text(url.path)
                                    .multilineTextAlignment(.leading)
                            }
                            .help("Show in Finder")
                            .buttonStyle(.borderless)
                            .tint(.accentColor)
                            Spacer()
                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(url.path, forType: .string)
                                copied = true
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1))
                                    copied = false
                                }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "document.on.document")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .help("Copy File Path")
                            .buttonStyle(.borderless)
                            .tint(.accentColor)
                        }
                    #endif
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("Developer options.")
                }
            } else {
                Section {
                    let actions = downloads.getAvailableActions(for: pkg)
                    ForEach(actions.filter { $0 != .delete }, id: \.self) { action in
                        let label = downloads.getActionLabel(for: action)
                        Button(label.title) {
                            downloads.performDownloadAction(for: pkg, action: action)
                        }
                        .foregroundStyle(label.isDestructive ? .red : .primary)
                    }
                } header: {
                    Text("Incomplete Package")
                } footer: {
                    switch pkg.state.status {
                    case .pending:
                        Text("\(Int(pkg.state.percent * 100))%...")
                    case .downloading:
                        Text("\(Int(pkg.state.percent * 100))%...")
                    case .paused:
                        Text("Paused at \(Int(pkg.state.percent * 100))%")
                    case .completed:
                        Group {}
                    case .failed:
                        Text("Download failed.")
                    }
                }
            }

            Section {
                Text(pkg.account.account.email)
                    .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                Text("\(pkg.account.account.store) - \(ApplePackage.Configuration.countryCode(for: pkg.account.account.store) ?? String(localized: "Unknown"))")
            } header: {
                Text("Account")
            } footer: {
                Text("This account is used to download this package. If you choose to AirDrop, your target device must sign in or previously signed in to this account and have at least one app installed.")
            }

            Section {
                let deleteAction = DownloadAction.delete
                let label = downloads.getActionLabel(for: deleteAction)
                Button(label.title) {
                    Task { downloads.performDownloadAction(for: pkg, action: deleteAction) }
                    dismiss()
                }
                .foregroundStyle(label.isDestructive ? .red : .primary)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text(url.path)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pkg.package.software.name)
    }

    #if os(iOS)
        /// Nhập IPA vừa tải vào thư viện ký (đợt 5, build 10).
        private func importToSign() async {
            await SignAppState.shared.importIPA(url)
            signImportMessage = "Đã đưa \(archive.software.name) vào tab Ký IPA. Mở tab để chọn chứng chỉ và ký."
            showSignImportAlert = true
        }
    #endif
}
