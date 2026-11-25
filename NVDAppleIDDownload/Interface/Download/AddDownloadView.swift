//
//  AddDownloadView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import ButtonKit
import SwiftUI

struct AddDownloadView: View {
    @State private var bundleID: String = ""
    @State private var searchType: EntityType = .iPhone
    @State private var selection: AppStore.UserAccount.ID = .init()
    @State private var hint = ""
    @State private var hintIsError = false

    // Tìm theo tên app: gõ tên rồi bấm Tìm (chỉ tìm khi bấm, không tìm theo
    // từng ký tự để tránh spam API). Bấm vào kết quả thì tự điền Bundle ID
    // vào ô bên dưới; vẫn nhập tay được như cũ cho app đã rời App Store.
    @State private var searchTerm: String = ""
    @State private var searchResults: [AppStore.AppPackage] = []
    @State private var searching = false
    @State private var searchError = ""

    @FocusState private var searchKeyFocused

    @State private var avm = AppStore.this
    @State private var dvm = Downloads.this

    @Environment(\.dismiss) private var dismiss

    var account: AppStore.UserAccount? {
        avm.accounts.first { $0.id == selection }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(String(localized: "Tên app hoặc Bundle ID"), text: $searchTerm)
                    #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.none)
                    #endif
                        .focused($searchKeyFocused)
                        .onSubmit { searchByName() }
                    Button {
                        searchByName()
                    } label: {
                        Text("Tìm")
                    }
                    .disabled(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account == nil || searching)
                    .nvdBorderBeam(shape: .rounded(10))
                }
                if searching {
                    ProgressView(String(localized: "Đang tìm…"))
                } else if !searchError.isEmpty {
                    Text(searchError)
                        .foregroundStyle(.red)
                } else if !searchResults.isEmpty {
                    ForEach(searchResults) { item in
                        Button {
                            bundleID = item.software.bundleID
                            searchResults = []
                            searchError = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                ArchivePreviewView(archive: item)
                                Text(item.software.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Tìm theo tên app")
            } footer: {
                Text("Gõ tên app, bấm Tìm rồi bấm vào kết quả để điền Bundle ID vào ô bên dưới. App đã không còn trên App Store thì nhập Bundle ID tay ở dưới.")
            }

            Section {
                TextField("Bundle ID", text: $bundleID)
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                #endif
                    .focused($searchKeyFocused)
                Picker("EntityType", selection: $searchType) {
                    ForEach(EntityType.allCases, id: \.self) { type in
                        Text(type.rawValue)
                            .tag(type)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Bundle ID")
            } footer: {
                Text("Tell us the bundle ID of the app to initiate a direct download. Useful to download apps that are no longer available in App Store.")
            }

            Section {
                Picker("Account", selection: $selection) {
                    ForEach(avm.accounts) { account in
                        Text(account.account.email)
                            .id(account.id)
                    }
                }
                .pickerStyle(.menu)
                .onAppear { selection = avm.accounts.first?.id ?? .init() }
                .redacted(reason: .placeholder, isEnabled: avm.demoMode)
            } header: {
                Text("Account")
            } footer: {
                Text("Select an account to download this app")
            }

            Section {
                AsyncButton {
                    guard let account else { return }
                    searchKeyFocused = false
                    do {
                        guard let countryCode = ApplePackage.Configuration.countryCode(for: account.account.store) else { return }
                        let software = try await ApplePackage.Lookup.lookup(bundleID: bundleID, countryCode: countryCode)
                        let appPackage = AppStore.AppPackage(software: software)
                        try await dvm.startDownload(for: appPackage, accountID: account.id, region: countryCode)
                        hint = String(localized: "Download Requested")
                        hintIsError = false
                    } catch {
                        hint = error.localizedDescription
                        hintIsError = true
                        throw error
                    }
                } label: {
                    Text("Request Download")
                }
                .disabledWhenLoading()
                .disabled(bundleID.isEmpty)
                .disabled(account == nil)
                .nvdBorderBeam(shape: .rounded(10))
            } footer: {
                if hint.isEmpty {
                    Text("The package can be installed later from the Downloads page.")
                } else {
                    Text(hint)
                        .foregroundStyle(hintIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Direct Download")
    }

    /// Tìm app theo tên (hoặc Bundle ID) qua App Store, dùng kho của tài
    /// khoản đã chọn — giống cách Request Download lấy countryCode.
    private func searchByName() {
        guard let account else {
            searchError = String(localized: "Hãy chọn tài khoản trước.")
            return
        }
        guard let countryCode = ApplePackage.Configuration.countryCode(for: account.account.store) else { return }
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchKeyFocused = false
        searching = true
        searchError = ""
        searchResults = []
        let entityType = searchType
        Task {
            do {
                var result = try await ApplePackage.Searcher.search(
                    term: term,
                    countryCode: countryCode,
                    limit: 20,
                    entityType: entityType,
                )
                // Gõ đúng Bundle ID thì Lookup trúng ngay — đưa lên đầu.
                if let app = try? await ApplePackage.Lookup.lookup(
                    bundleID: term,
                    countryCode: countryCode,
                    entityType: entityType,
                ), !result.contains(where: { $0.bundleID == app.bundleID }) {
                    result.insert(app, at: 0)
                }
                let packages = result.map { AppStore.AppPackage(software: $0, entityType: entityType) }
                await MainActor.run {
                    searching = false
                    searchResults = packages
                    if packages.isEmpty {
                        searchError = String(localized: "Không tìm thấy app nào. Thử tên khác, hoặc nhập Bundle ID tay ở dưới.")
                    }
                }
            } catch {
                await MainActor.run {
                    searching = false
                    searchResults = []
                    searchError = error.localizedDescription
                }
            }
        }
    }
}
