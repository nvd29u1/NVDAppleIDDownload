//
//  ProductHistoryView.swift
//  NVDAppleIDDownload
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import SwiftUI

struct ProductHistoryView: View {
    @State var vm: AppPackageArchive
    @State private var showErrorAlert = false
    @Environment(\.dismiss) var dismiss

    /// Dung lượng IPA: metadata tải của Apple có thì hiện, không có thì
    /// "—" (riêng bản mới nhất đã tra thêm qua Lookup, xem
    /// AppPackageArchive.enrichLatestExtraIfNeeded).
    private let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private func formattedSize(for key: String) -> String? {
        guard let size = vm.extra(for: key)?.fileSizeBytes else { return nil }
        return sizeFormatter.string(fromByteCount: size)
    }

    var body: some View {
        Form {
            ForEach(vm.versionIdentifiers, id: \.self) { key in
                if let aid = vm.resolvedAccountID(), let pkg = vm.package(for: key) {
                    let metadata = vm.versionItems[key]
                    let extra = vm.extra(for: key)
                    Menu {
                        Button("Download \(pkg.software.version)") {
                            Task {
                                do {
                        try await Downloads.this.startDownload(for: pkg, accountID: aid, region: vm.region)
                                } catch {
                                    vm.error = error.localizedDescription
                                }
                            }
                        }
                        Button("Sao chép số version") {
                            copyToClipboard(pkg.software.version)
                        }
                        Button("Sao chép version ID") {
                            copyToClipboard(key)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(pkg.software.version)
                                    .foregroundStyle(.accent)
                                Spacer()
                                if let size = formattedSize(for: key) {
                                    Text(size)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 6) {
                                if let date = metadata?.releaseDate {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                }
                                Text("ID \(key)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let notes = extra?.releaseNotes, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // Bấm giữ 1 dòng để copy số version / version ID
                    // (đợt 3, build 8 — ý tưởng iPadn mục 6).
                    .contextMenu {
                        Button("Sao chép số version") {
                            copyToClipboard(pkg.software.version)
                        }
                        Button("Sao chép version ID") {
                            copyToClipboard(key)
                        }
                    }
                } else {
                    Button {
                        vm.populateVersionItem(for: key)
                    } label: {
                        HStack {
                            Text(key).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .contextMenu {
                        Button("Sao chép version ID") {
                            copyToClipboard(key)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            ZStack {
                Rectangle()
                    .foregroundStyle(.clear)
                    .background(.ultraThinMaterial)
                ProgressView()
                    .progressViewStyle(.circular)
                    .smallControlSizeOnMac()
            }
            .opacity(vm.loading ? 1 : 0)
            .animation(.default, value: vm.loading)
            .ignoresSafeArea(edges: [.vertical])
        }
        .animation(.default, value: vm.versionIdentifiers)
        .animation(.default, value: vm.versionItems)
        .animation(.default, value: vm.loading)
        .navigationTitle("Version History")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                Menu {
                    Button {
                        vm.populateNextVersionItems()
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled(vm.isVersionItemsFullyLoaded)
                    Divider()
                    Button(role: .destructive) {
                        vm.clearVersionItems()
                        vm.populateVersionIdentifiers {
                            await MainActor.run { vm.populateNextVersionItems() }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(vm.loading) // just make sure
                .opacity(vm.loading ? 0 : 1)
                .overlay { // using overlay to maintain same size while loading
                    if vm.loading {
                        ProgressView()
                            .progressViewStyle(.circular)
                        #if os(macOS)
                            .controlSize(.small)
                        #endif
                    }
                }
            }
        }
        .alert("Oops", isPresented: $showErrorAlert) {
            Button("OK") {
                vm.error = nil
                if vm.shouldDismiss {
                    dismiss()
                }
            }
        } message: {
            Text(vm.error ?? String(localized: "Unknown Error"))
        }
        .onChange(of: vm.error) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .onAppear {
            guard vm.versionItems.isEmpty else { return }
            vm.populateVersionIdentifiers {
                await MainActor.run { vm.populateNextVersionItems() }
            }
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .automatic
        #endif
    }
}
