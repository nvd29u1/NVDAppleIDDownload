//
//  DownloadView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import SwiftUI

struct DownloadView: View {
    @State private var vm = Downloads.this
    @State private var updateStore = UpdateCheckStore.shared

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Downloads")
        }
        // Kiểm tra bản mới cho app đã tải (đợt 3, build 8 — ý tưởng
        // iPadn mục 9): chỉ tra khi mở tab, không chạy nền liên tục.
        .onAppear {
            Task { await updateStore.check(manifests: vm.manifests) }
        }
    }

    private var content: some View {
        Group {
            if vm.manifests.isEmpty {
                ContentUnavailableView(
                    label: {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    },
                    description: {
                        Text("Search for an app or add a download link to get started.")
                    },
                    actions: {
                        NavigationLink("Add Download") {
                            AddDownloadView()
                        }
                    },
                )
                .padding()
            } else {
                Form {
                    packageList
                }
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: PackageManifest.self) { manifest in
            PackageView(pkg: manifest)
        }
        .toolbar {
            NavigationLink(destination: AddDownloadView()) {
                Image(systemName: "plus")
            }
        }
    }

    private var packageList: some View {
        ForEach(vm.manifests, id: \.id) { req in
            PackageManifestRow(manifest: req)
        }
    }
}

private struct PackageManifestRow: View {
    let manifest: PackageManifest
    @State private var vm = Downloads.this
    @State private var updateStore = UpdateCheckStore.shared

    var body: some View {
        NavigationLink(value: manifest) {
            VStack(spacing: 8) {
                ArchivePreviewView(archive: manifest.package)
                SimpleProgress(progress: manifest.state.percent)
                    .animation(.interactiveSpring, value: manifest.state.percent)
                HStack {
                    Text(manifest.hint)
                    Spacer()
                    Text(manifest.creation.formatted())
                }
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                if manifest.completed {
                    // Nhắc bản mới (đợt 3, build 8): app đã tải có bản mới
                    // trên Store thì hiện nhãn cam; đã "Giữ phiên bản này"
                    // thì không nhắc nữa (xem UpdateCheckStore.hasUpdate).
                    if updateStore.hasUpdate(for: manifest),
                       let latest = updateStore.latestVersion(for: manifest.package.software.bundleID)
                    {
                        HStack {
                            Label("Có bản mới: v\(latest)", systemImage: "arrow.up.circle")
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .font(.system(.footnote, design: .rounded))
                    }
                    if manifest.pinned {
                        HStack {
                            Label("Đã giữ phiên bản này", systemImage: "pin.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.system(.footnote, design: .rounded))
                    }
                    HStack {
                        ExportIPAButton(manifest: manifest)
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .font(.system(.footnote, design: .rounded))
                        Button(manifest.pinned ? "Bỏ giữ phiên bản" : "Giữ phiên bản này") {
                            vm.setPinned(manifest, !manifest.pinned)
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .font(.system(.footnote, design: .rounded))
                        Spacer()
                    }
                }
            }
        }
        .contextMenu {
            let actions = vm.getAvailableActions(for: manifest)
            ForEach(actions, id: \.self) { action in
                let label = vm.getActionLabel(for: action)
                Button(role: label.isDestructive ? .destructive : .none) {
                    vm.performDownloadAction(for: manifest, action: action)
                } label: {
                    Label(label.title, systemImage: label.systemImage)
                }
            }
        }
    }
}

extension PackageManifest {
    var hint: String {
        if let error = state.error {
            return error
        }
        return switch state.status {
        case .pending:
            String(localized: "Pending...")
        case .downloading:
            [
                String(Int(state.percent * 100)) + "%",
                state.speed.isEmpty ? "" : state.speed + "/s",
            ]
            .compactMap(\.self)
            .joined(separator: " ")
        case .paused:
            String(localized: "Paused")
        case .completed:
            String(localized: "Completed")
        case .failed:
            String(localized: "Failed")
        }
    }
}
