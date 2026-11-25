//
//  FileAnalysisView.swift
//  NVDAppleIDDownload
//
//  Created by 秋星桥 on 2024/7/19.
//

import SwiftUI
import ZIPFoundation

#if canImport(UIKit)
    import UIKit

    typealias PlatformImage = UIImage
#elseif canImport(AppKit) && !canImport(UIKit)
    import AppKit

    typealias PlatformImage = NSImage
#else
    typealias PlatformImage = AnyObject
#endif

struct FileAnalysisView: View {
    let packageURL: URL
    let relativePath: String

    let tempDir = temporaryDirectory
        .appendingPathComponent(UUID().uuidString)

    @State var message = ""
    @State var extractedFile: URL?
    @State var thumbnail: PlatformImage?
    /// Nội dung text của file nhỏ (≤ 64 KB, đọc được UTF-8) — xem trước
    /// ngay trong app (đợt 3, build 8). File nhị phân / file lớn thì
    /// không hiện text, chỉ trích ra Share Sheet như trước.
    @State var textPreview: String?

    var renderedThumbnail: Image? {
        guard let thumbnail else { return nil }
        #if canImport(UIKit)
            return Image(uiImage: thumbnail)
        #elseif canImport(AppKit) && !canImport(UIKit)
            return Image(nsImage: thumbnail)
        #else
            return nil
        #endif
    }

    var body: some View {
        Form {
            if let extractedFile {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        if let image = renderedThumbnail {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 120, height: 120)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Image(systemName: "doc.text.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(extractedFile.lastPathComponent)
                            .font(.system(.headline))
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                } footer: {
                    Text(extractedFile.path)
                }
                .transition(.opacity)
                if let textPreview {
                    Section {
                        ScrollView {
                            Text(textPreview)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 320)
                    } header: {
                        Text("Nội dung file")
                    } footer: {
                        Text("Chỉ xem trước file text nhỏ (dưới 64 KB). File lớn hơn thì dùng nút Chia sẻ file bên dưới.")
                    }
                    .transition(.opacity)
                }
                Section {
                    Button("Share File") {
                        AirDrop(items: [extractedFile])
                    }
                } header: {
                    Text("Operations")
                } footer: {
                    Text(message)
                        .foregroundStyle(.red)
                }
                .transition(.opacity)
            } else {
                Text(message.isEmpty ? String(localized: "Not Available") : message)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .formStyle(.grouped)
        .animation(.spring, value: relativePath)
        .animation(.spring, value: extractedFile)
        .onAppear {
            message = String(localized: "Examining contents...")
            Task {
                do { try await loadContents() }
                catch {
                    await MainActor.run { message = error.localizedDescription }
                }
            }
        }
        .onDisappear {
            try? FileManager.default.removeItem(at: tempDir)
        }
        .navigationTitle("Contents")
    }

    func loadContents() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let archive = try Archive(url: packageURL, accessMode: .read)
        guard let file = archive[relativePath] else {
            assertionFailure()
            throw NSError(domain: "FileAnalysisView", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "File not found"),
            ])
        }
        let destination = tempDir.appendingPathComponent(relativePath)
        _ = try archive.extract(file, to: destination)
        // Xem trước: ảnh thì làm thumbnail, text nhỏ thì đọc nội dung.
        // Đọc tối đa 64 KB để file log/binary lớn không nuốt bộ nhớ.
        let data = (try? Data(contentsOf: destination)) ?? Data()
        var previewText: String?
        var previewImage: PlatformImage?
        #if canImport(UIKit)
            previewImage = UIImage(data: data)
        #elseif canImport(AppKit) && !canImport(UIKit)
            previewImage = NSImage(data: data)
        #endif
        if previewImage == nil, data.count <= 64 * 1024,
           let text = String(data: data, encoding: .utf8), !text.isEmpty
        {
            previewText = text
        }
        await MainActor.run {
            message = String(localized: "Extracted File")
            extractedFile = destination
            thumbnail = previewImage
            textPreview = previewText
        }
    }
}
