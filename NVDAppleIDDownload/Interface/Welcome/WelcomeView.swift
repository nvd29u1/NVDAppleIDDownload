//
//  WelcomeView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/11.
//

import SwiftUI

struct WelcomeView: View {
    @State var openInstruction: Bool = false

    // NVD theme: dark plum background, green pig logo.
    private static let plumTop = Color(red: 0.48, green: 0.13, blue: 0.28)
    private static let plumBottom = Color(red: 0.23, green: 0.07, blue: 0.16)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Self.plumTop, Self.plumBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Image(.pigLogo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .shadow(radius: 12)

                Text("Welcome to NVDAppleIDDownload")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                Spacer().frame(height: 0)
            }

            VStack(spacing: 16) {
                Spacer()
                HStack(spacing: 8) {
                    Text(version)
                    Button {
                        openInstruction = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $openInstruction) {
                        SimpleInstruction()
                            .padding(32)
                    }
                }
                Text("The App Store API can be unstable. Retry if an error occurs.")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }
}
