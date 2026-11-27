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
    @StateObject private var vm = AppStore.this
    @AppStorage("searchRegion") private var searchRegion = StoreRegionCatalog.defaultSearchRegion

    @State private var showDeviceIdWarning = false
    @State private var editingDeviceId = false
    @State private var deviceIdDraft = ""
    @State private var showResetConfirmation = false

    @State private var isCheckingAnisette = false
    @State private var anisetteCheckResult: String?
    @State private var anisetteCustomServer = false

    /// Picker máy chủ Anisette ở Cài đặt chính — cùng mẫu với tab Ký
    /// IPA (SignSettingsView.serverChoice): chọn preset thì ghi URL
    /// của preset, chọn "Tùy chỉnh" thì hiện ô nhập URL riêng. Giá trị
    /// đang lưu (hoặc mặc định jkcoxson khi chưa lưu gì) luôn khớp
    /// đúng 1 preset hoặc "Tùy chỉnh" nên picker không bao giờ trống.
    var anisetteServerChoice: Binding<String> {
        Binding(get: {
            if anisetteCustomServer { return "custom" }
            return AnisetteService.storePresets.contains(where: { $0.url == vm.anisetteServerURL }) ? vm.anisetteServerURL : "custom"
        }, set: { v in
            anisetteCheckResult = nil
            if v == "custom" { anisetteCustomServer = true } else { anisetteCustomServer = false; vm.anisetteServerURL = v }
        })
    }

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

            // Tải xong tự cài đặt (đợt 4, build 9 — ý tưởng iPadn mục 8):
            // chỉ có tác dụng trên iOS, mặc định tắt.
            #if os(iOS)
                Section {
                    Toggle("Tải xong tự cài đặt", isOn: $vm.autoInstallAfterDownload)
                } header: {
                    Text("Tải xuống")
                } footer: {
                    Text("Bật thì tải xong app sẽ tự mở màn cài đặt (qua máy chủ manifest trong Cài đặt) mà không cần bấm Cài đặt tay. Chỉ chạy khi app đang mở; tải xong lúc app đang ở nền thì không tự cài. Mặc định tắt.")
                }
            #endif

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
                Picker("Máy chủ", selection: anisetteServerChoice) {
                    ForEach(AnisetteService.storePresets, id: \.url) { p in Text(p.name).tag(p.url) }
                    Text("Tùy chỉnh").tag("custom")
                }
                if anisetteServerChoice.wrappedValue == "custom" {
                    TextField("https://…", text: $vm.anisetteServerURL)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                }
                Button("Kiểm tra") {
                    isCheckingAnisette = true
                    anisetteCheckResult = nil
                    Task {
                        let result = await AnisetteService.check(urlString: vm.anisetteServerURL)
                        anisetteCheckResult = result
                        isCheckingAnisette = false
                    }
                }
                .disabled(isCheckingAnisette)
                Button("Khôi phục mặc định") {
                    vm.anisetteServerURL = AnisetteService.defaultServerURL
                    anisetteCustomServer = false
                    anisetteCheckResult = nil
                }
                .disabled(vm.anisetteServerURL == AnisetteService.defaultServerURL)
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
                Text("Từ tháng 11/2026 Apple yêu cầu đăng nhập App Store phải kèm header xác minh thiết bị (Anisette). Chọn 1 máy chủ trong danh sách (mặc định đã có sẵn, không cần gõ tay) hoặc chọn \"Tùy chỉnh\" để nhập địa chỉ máy chủ Anisette của riêng bạn (máy tính trong mạng nhà, ví dụ http://192.168.1.10:6969) — app sẽ lấy header từ máy chủ đó trước mỗi lần đăng nhập. Chỉ có địa chỉ máy chủ được lưu ở đây; mật khẩu Apple ID KHÔNG BAO GIỜ được gửi tới máy chủ này — máy chủ chỉ trả về header, không nhận mật khẩu.")
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

            // Giới thiệu (đợt 5, build 10): nội dung tab Trang chủ cũ
            // (đã bỏ) gom vào đây — logo, lời chào, phiên bản, hướng
            // dẫn, ghi công.
            Section {
                HStack(spacing: 14) {
                    Image(.pigLogo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .nvdBorderBeam(shape: .rounded(15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NVDAppleIDDownload")
                            .font(.title2.weight(.heavy))
                        Text("Welcome to NVDAppleIDDownload")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Phiên bản \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Đăng nhập tài khoản Apple ID ở tab Tài khoản.")
                    Text("2. Thêm lượt tải theo tên app hoặc Bundle ID ở tab Lượt tải.")
                    Text("3. Tải xong mở file IPA, bấm Ký IPA này để ký ở tab Ký IPA.")
                    Text("4. Cài chứng chỉ ở mục Device bên trên rồi cài app trực tiếp hoặc qua AirDrop.")
                }
                .font(.callout)
                Text("The App Store API can be unstable. Retry if an error occurs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Dựa trên Asspp của Lakr233 (MIT). Tính năng ký dùng mã nguồn mở theo giấy phép GPL-3.0, xem chi tiết trong LICENSES.md trên GitHub. Hiệu ứng viền sáng BorderBeam của ismnoiet (MIT).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Chuyển từ mục Giới thiệu cũ ở Cài đặt Ký IPA (bỏ ở
                // build 16 theo lệnh anh — Cài đặt chính đã có giới
                // thiệu rồi): link GitHub của app gộp, dòng Twemoji
                // (CC-BY 4.0), link BorderBeam. Giữ attribution đủ
                // vì app phân phối công khai (GPL-3.0/MIT).
                Link(destination: URL(string: "https://github.com/nvd29u1/NVDAppleIDDownload")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/ismnoiet/border-beam-ios")!) {
                    Label("BorderBeam", systemImage: "sun.max")
                }
                // Đợt 5, build 17: khoảng iOS hỗ trợ + tích xanh. Đầu
                // dưới lấy từ MinimumOSVersion của binary (đổi min ở
                // Base.xcconfig thì tự cập nhật); đầu trên là hằng số
                // maxSupportedIOSVersion cạnh version trong main.swift
                // (mốc ổn định anh chốt 19/11: 27.2). Dòng ghi chú giữ
                // trung thực mốc đã kiểm chứng thật (27.0).
                #if os(iOS)
                if isCurrentIOSSupported {
                    Label("Hỗ trợ iOS \(minSupportedIOSVersion) – \(maxSupportedIOSVersion)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Hỗ trợ iOS \(minSupportedIOSVersion) – \(maxSupportedIOSVersion)")
                        .foregroundStyle(.secondary)
                }
                #else
                Text("Hỗ trợ iOS \(minSupportedIOSVersion) – \(maxSupportedIOSVersion)")
                    .foregroundStyle(.secondary)
                #endif
                Text("Đã kiểm chứng tới iOS \(testedIOSVersion).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Text("Đang chạy trong LiveContainer thì nhập file và cài đặt không hoạt động — cài app thật qua SideStore hoặc AltStore để dùng các tính năng này.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            } header: {
                Text("Giới thiệu")
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
