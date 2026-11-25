//
//  ViewBackports.swift
//  NVDAppleIDDownload
//
//  Created by luca on 19.09.2025.
//

import SwiftUI

extension View {
    @ViewBuilder
    func mediumAndLargeDetents() -> some View {
        #if os(iOS)
            presentationDetents([.medium, .large])
        #else
            self
        #endif
    }

    @ViewBuilder
    func neverMinimizeTab() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                tabBarMinimizeBehavior(.never)
            } else {
                self
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func activateSearchWhenSearchTabSelected() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                tabViewSearchActivation(.searchTabSelection)
            } else {
                self
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func sidebarAdaptableTabView() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                tabViewStyle(.sidebarAdaptable)
            } else {
                self
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func smallControlSizeOnMac() -> some View {
        #if os(macOS)
            controlSize(.small)
        #else
            self
        #endif
    }

    /// .contentTransition(.symbolEffect(.replace)) chỉ có từ iOS 17+ /
    /// macOS 14+: trên iOS 16 bỏ qua hiệu ứng, icon vẫn đổi bình thường.
    @ViewBuilder
    func symbolEffectReplaceIfAvailable() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    @ViewBuilder
    func hide() -> some View {}
}

/// Empty-state view tương thích iOS 16 (bản 17): trên iOS 17+ /
/// macOS 14+ dùng ContentUnavailableView của hệ thống, dưới đó vẽ lại
/// bằng VStack (icon lớn + tiêu đề + mô tả + nút hành động).
struct NVDContentUnavailableView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String?
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    var body: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let description {
                    Text(description)
                }
            } actions: {
                actions()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                actions()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}

public extension ToolbarContent {
    @ToolbarContentBuilder
    nonisolated func hideSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
