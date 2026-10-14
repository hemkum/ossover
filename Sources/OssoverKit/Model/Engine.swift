// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An installed engine: its manifest resolved against the directory it lives in, so every
/// consumer gets absolute URLs and nobody re-derives `lib/wine/x86_64-unix` by hand.
///
/// Layout (plan §5): `engines/<id>/{manifest.json, SHA256SUMS, wine/{bin,lib,share},
/// overlays/{dxmt,dxvk,d3dmetal}}`. The bootstrap engine uses other relative paths; the
/// manifest's `paths` say where things are.
public struct Engine: Sendable, Equatable, Identifiable {
    public static let manifestFileName = "manifest.json"
    public static let sha256sumsFileName = "SHA256SUMS"
    public static let overlaysDirectoryName = "overlays"

    public let root: URL
    public let manifest: EngineManifest

    public init(root: URL, manifest: EngineManifest) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
    }

    public var id: String { manifest.id }
    public var arch: EngineArch { manifest.arch }
    public var capabilities: EngineCapabilities { manifest.capabilities }

    public var manifestURL: URL { root.appending(path: Self.manifestFileName) }
    public var sha256sumsURL: URL { root.appending(path: Self.sha256sumsFileName) }

    public var wine: URL { root.appending(path: manifest.paths.wine) }
    public var wineserver: URL { root.appending(path: manifest.paths.wineserver) }
    /// `lib/wine`.
    public var libWine: URL { root.appending(path: manifest.paths.libWine, directoryHint: .isDirectory) }
    /// `lib` (dylibs next to `lib/wine`).
    public var libDir: URL { libWine.deletingLastPathComponent() }
    /// Where Wine's `bin/` lives; `share/wine` (mono, gecko) sits beside it.
    public var wineRoot: URL { wine.deletingLastPathComponent().deletingLastPathComponent() }
    public var shareWine: URL { wineRoot.appending(path: "share/wine", directoryHint: .isDirectory) }
    /// GStreamer plugin directory for `GST_PLUGIN_SYSTEM_PATH`, when the engine bundles one.
    public var gstreamerPlugins: URL { libDir.appending(path: "gstreamer-1.0", directoryHint: .isDirectory) }
    public var frameworks: URL? {
        manifest.paths.frameworks.map { root.appending(path: $0, directoryHint: .isDirectory) }
    }

    public var unixLibDir: URL { libWine.appending(path: arch.unixLibDir, directoryHint: .isDirectory) }
    public var pe64LibDir: URL { libWine.appending(path: arch.pe64LibDir, directoryHint: .isDirectory) }
    public var pe32LibDir: URL { libWine.appending(path: EngineArch.pe32LibDir, directoryHint: .isDirectory) }

    /// `overlays/` — renderer overlays for strategy C (`WINEDLLPATH_PREPEND`).
    public var overlays: URL { root.appending(path: Self.overlaysDirectoryName, directoryHint: .isDirectory) }
    public func overlay(_ kind: RendererKind) -> URL { overlays.appending(path: kind.rawValue, directoryHint: .isDirectory) }

    /// Directory of a renderer shipped inside the engine tarball, or nil when none is bundled.
    public func bundledRendererURL(_ kind: RendererKind) -> URL? {
        manifest.bundledRenderer(kind).map { root.appending(path: $0.path, directoryHint: .isDirectory) }
    }

    /// `${engine}` → the engine directory, for `baseEnv` and recipe paths.
    public var variables: [String: String] { ["engine": root.path] }

    // MARK: Files

    /// Reads `manifest.json` from an engine directory.
    public static func load(root: URL) throws -> Engine {
        let url = root.appending(path: manifestFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OssoverError.missing("engine manifest \(url.path)")
        }
        return Engine(root: root, manifest: try EngineManifest.load(from: url))
    }

    /// True when the manifest and the wine loader are both present.
    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: manifestURL.path) && fm.isExecutableFile(atPath: wine.path)
    }

    /// Throws when the binaries the manifest points at are not there or not executable.
    public func validateLayout() throws {
        let fm = FileManager.default
        for (name, url) in [("wine", wine), ("wineserver", wineserver)] {
            guard fm.fileExists(atPath: url.path) else { throw OssoverError.missing("engine \(id): \(name) at \(url.path)") }
            guard fm.isExecutableFile(atPath: url.path) else { throw OssoverError.invalid("engine \(id): \(name) at \(url.path) is not executable") }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: libWine.path, isDirectory: &isDir), isDir.boolValue else {
            throw OssoverError.missing("engine \(id): lib/wine at \(libWine.path)")
        }
        guard fm.fileExists(atPath: unixLibDir.path) else {
            throw OssoverError.missing("engine \(id): \(arch.unixLibDir) at \(unixLibDir.path)")
        }
    }
}
