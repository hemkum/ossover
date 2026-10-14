// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Paths.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// Filesystem layout of everything ossover owns: `~/Library/Application Support/ossover/` unless
/// `OSSOVER_HOME` says otherwise (tests and integration runs point it at a temp directory).
///
/// ```
/// <home>/
///   engines/<id>/        installed engines (manifest.json, SHA256SUMS, wine/, overlays/)
///   renderers/<id>/      renderer packs (manifest.json, wine/, external/)
///   bottles/<name>/      bottle.json, prefix/, logs/, steamcmd/
///   downloads/           archives by file name, partials beside them
///   tools/               winetricks, steamcmd, DepotDownloader
///   logs/                ossover's own logs (not a bottle's)
///   licenses/            licence acceptance records (D3DMetal)
///   cache/               per-engine caches (GStreamer plugin registries, REA L-08)
///   .metadata_never_index
/// ```
public struct OssoverPaths: Sendable, Equatable {
    public static let homeEnvironmentKey = "OSSOVER_HOME"
    public static let spotlightMarkerName = ".metadata_never_index"

    public let home: URL

    /// `~/Library/Application Support/ossover`.
    public static var defaultHome: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "ossover", directoryHint: .isDirectory)
    }

    /// Precedence: the caller's `home`, then `OSSOVER_HOME`, then the default.
    public init(home: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = Self.resolve(explicit: home, environment: environment, defaultHome: Self.defaultHome)
    }

    /// The home a bottle layout sits under (`<home>/bottles/<name>`), for the Wine stage, which
    /// holds only the layout; pure path arithmetic.
    public init(containing layout: BottleLayout) {
        self.home = layout.root.deletingLastPathComponent().deletingLastPathComponent()
    }

    public static func resolve(explicit: URL?, environment: [String: String], defaultHome: URL) -> URL {
        if let explicit { return explicit.standardizedFileURL }
        if let raw = environment[homeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return defaultHome.standardizedFileURL
    }

    public var engines: URL { directory("engines") }
    public var renderers: URL { directory("renderers") }
    public var bottles: URL { directory("bottles") }
    public var downloads: URL { directory("downloads") }
    public var tools: URL { directory("tools") }
    public var logs: URL { directory("logs") }
    public var licenses: URL { directory("licenses") }
    public var cache: URL { directory("cache") }
    public var spotlightMarker: URL { home.appending(path: Self.spotlightMarkerName) }

    /// Every directory `ensureLayout()` creates, home first.
    public var allDirectories: [URL] { [home, engines, renderers, bottles, downloads, tools, logs, licenses, cache] }

    /// `cache/gstreamer-registry-<engineId>.<arch>.bin`: GStreamer's plugin registry for one
    /// engine, never shared between engines (`WineEnvironment.gstreamerVariables`, REA L-08).
    public func gstreamerRegistry(for engine: Engine) -> URL {
        cache.appending(path: "gstreamer-registry-\(engine.id).\(engine.arch.rawValue).bin")
    }

    public func engine(_ id: String) -> URL { engines.appending(path: id, directoryHint: .isDirectory) }
    public func renderer(_ id: String) -> URL { renderers.appending(path: id, directoryHint: .isDirectory) }
    public func bottle(_ name: String) -> URL { bottles.appending(path: name, directoryHint: .isDirectory) }
    public func bottleLayout(_ name: String) -> BottleLayout { BottleLayout(root: bottle(name)) }
    /// `downloads/<file name of the source>`.
    public func download(for source: ArtifactSource) -> URL { downloads.appending(path: source.fileName) }

    /// Creates the layout and the Spotlight opt-out marker (a game install is tens of GB of files
    /// nobody searches for, and mds indexing them makes a launch look hung).
    public func ensureLayout() throws {
        let fm = FileManager.default
        for dir in allDirectories {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw OssoverError.io("cannot create \(dir.path): \(error.localizedDescription)")
            }
        }
        if !fm.fileExists(atPath: spotlightMarker.path) {
            guard fm.createFile(atPath: spotlightMarker.path, contents: nil) else {
                throw OssoverError.io("cannot create \(spotlightMarker.path)")
            }
        }
    }

    /// Installed engine ids (directories under `engines/` holding a manifest), sorted.
    public func installedEngineIDs() -> [String] { subdirectories(of: engines, containing: Engine.manifestFileName) }
    /// Installed renderer pack ids, sorted.
    public func installedRendererIDs() -> [String] { subdirectories(of: renderers, containing: RendererPack.manifestFileName) }
    /// Bottle names (directories under `bottles/` holding a `bottle.json`), sorted.
    public func bottleNames() -> [String] { subdirectories(of: bottles, containing: Bottle.fileName) }

    func directory(_ name: String) -> URL { home.appending(path: name, directoryHint: .isDirectory) }

    func subdirectories(of parent: URL, containing marker: String) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                && fm.fileExists(atPath: url.appending(path: marker).path)
        }.map(\.lastPathComponent).sorted()
    }
}
