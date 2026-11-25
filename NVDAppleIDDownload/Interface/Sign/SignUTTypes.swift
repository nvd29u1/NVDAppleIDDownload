#if os(iOS)
import UniformTypeIdentifiers

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
    static let tipa = UTType(filenameExtension: "tipa") ?? .data
    static let p12 = UTType(filenameExtension: "p12") ?? .data
    static let mobileprovision = UTType(filenameExtension: "mobileprovision") ?? .data
    static let deb = UTType(filenameExtension: "deb") ?? .data
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
}
#endif
