//  AppLockService.swift
//  NVDAppleIDDownload
//
//  Khoá app bằng Face ID / Touch ID / mật khẩu (đợt 3, build 8 — ý
//  tưởng iPadn mục "Đáng nhắc thêm", viết lại sạch, giữ MIT).
//
//  Dùng LocalAuthentication với policy .deviceOwnerAuthentication:
//  có sinh trắc học thì dùng sinh trắc học, không có thì hệ thống tự
//  hỏi mật khẩu máy / mật khẩu thiết bị — app không tự làm màn hình
//  nhập mật khẩu riêng, không lưu mật khẩu nào. Bật trong Cài đặt
//  (AppStore.appLockEnabled). Khi bật: mở app lên là khoá; rời app
//  (sang nền / chuyển app khác) thì khoá lại ngay, nên ảnh chụp màn
//  hình đa nhiệm cũng chỉ thấy màn khoá chứ không thấy nội dung bên
//  trong.
//

import ButtonKit
import LocalAuthentication
import SwiftUI

@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    /// Đang ở màn khoá (che toàn bộ nội dung app).
    var isLocked = false
    /// Lỗi mở khoá gần nhất (vd. thiết bị chưa đặt mật khẩu).
    var errorMessage: String?

    private init() {}

    /// Khoá lại nếu người dùng đã bật khoá app trong Cài đặt.
    func lockIfEnabled() {
        if AppStore.this.appLockEnabled {
            isLocked = true
        }
    }

    /// Mở khoá bằng Face ID / Touch ID / mật khẩu thiết bị.
    func unlock() async {
        errorMessage = nil
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            errorMessage = String(localized: "Thiết bị chưa đặt Face ID / Touch ID / mật khẩu nên không khoá được app. Hãy đặt mật khẩu thiết bị trước rồi bật lại.")
            logger.error("AppLock: cannot evaluate policy: \(evaluationError?.localizedDescription ?? "?")")
            return
        }
        do {
            let unlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Mở khoá NVDAppleIDDownload"),
            )
            if unlocked {
                isLocked = false
            }
        } catch {
            errorMessage = String(localized: "Không mở khoá được. Thử lại.")
        }
    }
}

/// Bọc màn hình chính: khi khoá đang bật và đang ở trạng thái khoá thì
/// che toàn bộ nội dung bằng màn khoá. Đặt ở gốc WindowGroup trong
/// main.swift để mọi tab đều bị che, kể cả khi app vừa mở lại.
struct AppLockGate<Content: View>: View {
    let content: Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock.shared
    @State private var store = AppStore.this

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
            if store.appLockEnabled, lock.isLocked {
                lockScreen
            }
        }
        .onAppear {
            // Mở app lên mà khoá đang bật thì khoá ngay.
            if store.appLockEnabled {
                lock.isLocked = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Rời app (sang nền / đa nhiệm) thì khoá lại ngay — ảnh chụp
            // màn hình đa nhiệm cũng chỉ thấy màn khoá.
            if phase != .active {
                lock.lockIfEnabled()
            }
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("NVDAppleIDDownload đã khoá")
                .font(.title3.bold())
            Text("Mở khoá bằng Face ID / Touch ID hoặc mật khẩu thiết bị để tiếp tục.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            AsyncButton {
                await lock.unlock()
            } label: {
                Text("Mở khoá")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabledWhenLoading()
            .nvdBorderBeam(shape: .rounded(10))
            if let errorMessage = lock.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}
