//
//  Installer+Compute.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation

extension Installer {
    var plistEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = Self.sni
        comps.path = "/\(id).plist"
        comps.port = port
        return comps.url!
    }

    var payloadEndpoint: URL {
        var comps = URLComponents()
        if usesManifestServer {
            // Plain HTTP on 127.0.0.1: the manifest worker only accepts local
            // IPA links, and installd runs on this phone, so it can reach it.
            comps.scheme = "http"
            comps.host = "127.0.0.1"
        } else {
            comps.scheme = "https"
            comps.host = Self.sni
        }
        comps.path = "/\(id).ipa"
        comps.port = port
        return comps.url!
    }

    /// Manifest plist URL served by the configured manifest server
    /// (NVD worker by default). Returns nil when the server URL is unusable.
    var manifestServerManifestURL: URL? {
        let base = manifestServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "url", value: payloadEndpoint.absoluteString),
            URLQueryItem(name: "id", value: archive.software.bundleID),
            URLQueryItem(name: "v", value: archive.software.version),
            URLQueryItem(name: "name", value: archive.software.name),
        ]
        return comps.url
    }

    var iTunesLink: URL {
        if usesManifestServer, let manifestURL = manifestServerManifestURL {
            var comps = URLComponents()
            comps.scheme = "itms-services"
            comps.path = "/"
            comps.queryItems = [
                URLQueryItem(name: "action", value: "download-manifest"),
                URLQueryItem(name: "url", value: manifestURL.absoluteString),
            ]
            return comps.url!
        }
        var comps = URLComponents()
        comps.scheme = "itms-services"
        comps.path = "/"
        comps.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: plistEndpoint.absoluteString),
        ]
        comps.port = port
        return comps.url!
    }

    /// Mark the install as started (manifest-server mode: the manifest is
    /// fetched from the worker, so the local server never sees that step).
    @MainActor
    func beginInstall() {
        if case .ready = status {
            status = .sendingManifest
        }
    }

    var displayImageSmallEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = Self.sni
        comps.path = "/app57x57.png"
        comps.port = port
        return comps.url!
    }

    var displayImageSmallData: Data {
        createWhite(57)
    }

    var displayImageLargeEndpoint: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = Self.sni
        comps.path = "/app512x512.png"
        comps.port = port
        return comps.url!
    }

    var displayImageLargeData: Data {
        createWhite(512)
    }

    var indexHtml: String {
        """
        <html> <head> <meta http-equiv="refresh" content="0;url=\(iTunesLink.absoluteString)"> </head> </html>
        """
    }

    var installManifest: [String: Any] {
        [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": payloadEndpoint.absoluteString,
                        ],
                        [
                            "kind": "display-image",
                            "url": displayImageSmallEndpoint.absoluteString,
                        ],
                        [
                            "kind": "full-size-image",
                            "url": displayImageLargeEndpoint.absoluteString,
                        ],
                    ],
                    "metadata": [
                        "bundle-identifier": archive.software.bundleID,
                        "bundle-version": archive.software.version,
                        "kind": "software",
                        "title": archive.software.name,
                    ],
                ],
            ],
        ]
    }

    var installManifestData: Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: installManifest,
            format: .xml,
            options: .zero,
        )) ?? .init()
    }
}
