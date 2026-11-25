//
//  SettingView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct SettingView: View {
    @Environment(\.openURL) private var openURL
    @State private var vm = AppStore.this
    @AppStorage("searchRegion") private var searchRegion = StoreRegionCatalog.defaultSearchRegion

    @State private var showDeviceIdWarning = false
    @State private var editingDeviceId = false
    @State private var deviceIdDraft = ""
    @State private var showResetConfirmation = false

    @State private var isCheckingAnisette = false
    @State private var anisetteCheckResult: String?

    var body: some View {
        NavigationStack {
            formContent
        }
    }

    private var normalizedDeviceID: String? {
        AppStore.normalizedDeviceIdentifier(deviceIdDraft)
    }

    private func saveDeviceID() {
        guard let identifier = normalizedDeviceID else { return }
        // The AppStore setter also propagates this to ApplePackage.Configuration.
        vm.deviceIdentifier = identifier
        editingDeviceId = false
    }

    private var formContent: some View {
        Form {
            // Chia sẻ IPA qua Wi-Fi (đợt 3, build 8): công tắc cho phép
            // mở màn chia sẻ; máy chủ chỉ chạy khi đang ở màn đó, rời
            // màn là tắt ngay, không chạy nền.
            Section {
                Toggle("Chia sẻ IPA qua Wi-Fi", isOn: $vm.wifiTransferEnabled)
                NavigationLink {
                    WiFiTransferView()
                } label: {
                    HStack {
                        Text("Mở màn chia sẻ")
                        Spacer()
                        Text(vm.wifiTransferEnabled ? "Đã bật" : "Đang tắt")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!vm.wifiTransferEnabled)
            } header: {
                Text("Chia sẻ qua Wi-Fi")
            } footer: {
                Text("Bật rồi mở màn chia sẻ: máy tính cùng Wi-Fi gõ địa chỉ IP:cổng hiện trên màn để tải file IPA đã tải xong. Máy chủ tắt ngay khi rời màn.")
            }

            // Khoá app bằng Face ID / Touch ID / mật khẩu (đợt 3, build
            // 8): dùng LocalAuthentication của hệ thống, app không lưu
            // mật khẩu nào. Mở app lên là khoá; rời app thì khoá lại.
            Section {
                Toggle("Khoá app bằng Face ID / Touch ID / mật khẩu", isOn: $vm.appLockEnabled)
            } header: {
                Text("Khoá app")
            } footer: {
                Text("Bật thì mỗi lần mở app đều phải mở khoá bằng Face ID / Touch ID hoặc mật khẩu thiết bị. Rời app (sang nền / đa nhiệm) thì khoá lại ngay nên màn hình đa nhiệm cũng chỉ thấy màn khoá. Thiết bị chưa đặt mật khẩu thì không khoá được.")
            }

            Section {
                Toggle("Demo Mode", isOn: $vm.demoMode)
                Button("Delete All Downloads", role: .destructive) {
                    Downloads.this.removeAll()
                }
            } header: {
                Text("General")
            } footer: {
                Text("Demo mode redacts all accounts and sensitive information.")
            }

            Section {
                TextField("Manifest Server URL", text: $vm.manifestServerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                Button("Restore Default") {
                    vm.manifestServerURL = AppStore.defaultManifestServerURL
                }
                .disabled(vm.manifestServerURL == AppStore.defaultManifestServerURL)
            } header: {
                Text("Install App")
            } footer: {
                Text("Use this manifest server to install downloaded apps directly. Leave empty to use the built-in local server (requires installing and trusting the certificate).")
            }

            Section {
                TextField("Ví dụ: http://192.168.1.10:6969", text: $vm.anisetteServerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                Button("Kiểm tra") {
                    isCheckingAnisette = true
                    anisetteCheckResult = nil
                    Task {
                        let result = await AnisetteService.check(urlString: vm.anisetteServerURL)
                        anisetteCheckResult = result
                        isCheckingAnisette = false
                    }
                }
                .disabled(vm.anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCheckingAnisette)
                if isCheckingAnisette {
                    Text("Đang kiểm tra máy chủ…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let anisetteCheckResult {
                    Text(anisetteCheckResult)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Máy chủ Anisette")
            } footer: {
                Text("Từ tháng 11/2026 Apple yêu cầu đăng nhập App Store phải kèm header xác minh thiết bị (Anisette). Điền địa chỉ máy chủ Anisette của riêng bạn (máy tính trong mạng nhà, ví dụ http://192.168.1.10:6969) — app sẽ lấy header từ máy chủ đó trước mỗi lần đăng nhập. Để trống là tắt, đăng nhập như trước. Chỉ có địa chỉ máy chủ được lưu ở đây; mật khẩu Apple ID KHÔNG BAO GIỜ được gửi tới máy chủ này — máy chủ chỉ trả về header, không nhận mật khẩu.")
            }

            // Vùng tìm kiếm (đợt 2, build 7): độc lập với vùng tài khoản,
            // chỉ dùng để tìm app / tra cứu catalog. Mở màn chọn vùng
            // riêng để xem đủ 177 vùng, tick ưa thích, kéo sắp xếp.
            Section {
                NavigationLink {
                    SearchRegionSettingsView()
                } label: {
                    HStack {
                        Text("Chọn vùng tìm kiếm")
                        Spacer()
                        Text(StoreRegionCatalog.pickerLabel(for: searchRegion))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Vùng tìm kiếm")
            } footer: {
                Text("Vùng này chỉ dùng để tìm app và tra cứu, không ảnh hưởng vùng của tài khoản (để mua và tải). Đổi vùng không làm mất tài khoản nào.")
            }

            Section {
                Text(ProcessInfo.processInfo.hostName)
                    .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                if editingDeviceId {
                    TextField("Device GUID", text: $deviceIdDraft)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .onSubmit(saveDeviceID)
                    #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                    #endif
                    if normalizedDeviceID == nil {
                        Text("Enter a valid 12-character hexadecimal device GUID.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    #if os(macOS)
                        HStack {
                            Button("Save") { saveDeviceID() }
                                .disabled(normalizedDeviceID == nil)
                            Button("Cancel", role: .cancel) {
                                editingDeviceId = false
                            }
                            Button("Generate Device GUID") {
                                deviceIdDraft = DeviceIdentifier.random()
                            }
                            Spacer()
                        }
                    #else
                        Button("Save") { saveDeviceID() }
                            .disabled(normalizedDeviceID == nil)
                        Button("Cancel", role: .cancel) {
                            editingDeviceId = false
                        }
                        Button("Generate Device GUID") {
                            deviceIdDraft = DeviceIdentifier.random()
                        }
                    #endif
                } else {
                    HStack {
                        Text(vm.deviceIdentifier)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .redacted(reason: .placeholder, isEnabled: vm.demoMode)
                        Spacer()
                        Button("Edit Device GUID") {
                            showDeviceIdWarning = true
                        }
                    }
                    #if os(macOS)
                        HStack {
                            Button("Open Settings") {
                                openURL(URL(string: "x-apple.systempreferences:")!)
                            }
                            Button("Show Certificate in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Installer.ca])
                            }
                            Spacer()
                        }
                    #else
                        Button("Open Settings") {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        Button("Install Certificate") {
                            openURL(Installer.caURL)
                        }
                    #endif
                }
            } header: {
                Text("Device")
            } footer: {
                #if canImport(UIKit)
                    Text("Grant local network permission to install apps. Install and trust the SSL certificate for on-device installation.")
                #else
                    Text("Grant local network permission to install apps. Install the SSL certificate through System Keychain.")
                #endif
            }
            .alert("Edit Device GUID", isPresented: $showDeviceIdWarning) {
                Button("Edit", role: .destructive) {
                    deviceIdDraft = vm.deviceIdentifier
                    editingDeviceId = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Changing the device GUID may cause all existing accounts to stop working. Apple limits the number of devices you can sign in with at once.")
            }

            Section {
                Button("Reset", role: .destructive) {
                    showResetConfirmation = true
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This will reset all your settings.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                NavigationLink {
                    LogView()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        .alert("Reset Application", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                try? FileManager.default.removeItem(at: documentsDirectory)
                try? FileManager.default.removeItem(at: temporaryDirectory)
                #if canImport(UIKit)
                    UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                #endif
                #if canImport(AppKit) && !canImport(UIKit)
                    NSApp.terminate(nil)
                #endif
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    exit(0)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all your settings and data. The app will close afterwards.")
        }
    }
}
