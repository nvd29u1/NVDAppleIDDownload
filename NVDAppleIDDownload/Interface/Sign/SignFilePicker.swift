#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Presents the system Files picker directly (UIKit), instead of SwiftUI's `.fileImporter`.
///
/// `.fileImporter` inside a sheet, driven by a computed `Binding`, loses the picked files:
/// on dismiss SwiftUI resets the binding (so "what was being picked" is already nil) and on
/// some iOS versions never calls the completion at all. Picking "as copy" also means the
/// files are already in our sandbox: no security-scoped access, no waiting for iCloud.
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()
    private var completion: (([URL]) -> Void)?

    func pick(_ types: [UTType], multiple: Bool = false, completion: @escaping ([URL]) -> Void) {
        guard let top = Self.topController() else { return }
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.shouldShowFileExtensions = true
        vc.delegate = self
        self.completion = completion
        top.present(vc, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }
}
#endif
