// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps a Steam depot pinned once fetched (plan §3 Phase 3): a second `steam fetch` into a
/// directory that already holds `appmanifest_<app>.acf` (or DepotDownloader state) is refused
/// unless `allowUpdate`, because Steam would move Witcher 3 4.04 (`next-gen`) to the DX12-only
/// 5.x Remastered. After a fetch the expected executable must exist, and what the ACF says is
/// recorded on the bottle (`bottle.steam`).
public struct SteamFetchGuard: Sendable, Equatable {
    /// The file a finished fetch must contain, relative to the install directory.
    public static let expectedExecutables: [Int: String] = [
        292030: "bin/x64/witcher3.exe",   // The Witcher 3: Wild Hunt, 4.04 `next-gen` (DX11)
    ]

    public let app: Int
    /// Unix path of the install directory (`force_install_dir` / `-dir`).
    public let destination: URL
    /// Relative path of the executable that proves the fetch is complete; nil = unknown app.
    public let expectedExe: String?

    public init(app: Int, destination: URL, expectedExe: String? = nil) {
        self.app = app
        self.destination = destination.standardizedFileURL
        self.expectedExe = expectedExe ?? Self.expectedExecutables[app]
    }

    /// `<dest>/steamapps/appmanifest_<app>.acf`.
    public var manifestURL: URL { AppManifestACF.url(installDir: destination, app: app) }
    /// `<dest>/.DepotDownloader`.
    public var depotDownloaderState: URL { DepotDownloader.stateDirectory(installDir: destination) }
    /// `<dest>/<expectedExe>`, when known.
    public var expectedExeURL: URL? { expectedExe.map { destination.appending(path: $0) } }

    /// True when a previous fetch left its records here.
    public var hasPriorFetch: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: manifestURL.path) || fm.fileExists(atPath: depotDownloaderState.path)
    }

    /// Refuses a re-fetch (`.alreadyExists`) unless `allowUpdate`.
    public func checkBeforeFetch(allowUpdate: Bool) throws {
        guard hasPriorFetch, !allowUpdate else { return }
        var what = "app \(app) is already fetched at \(destination.path)"
        if let manifest = try? AppManifestACF.load(from: manifestURL) {
            what += " (build \(manifest.buildID ?? "?")" + (manifest.betaKey.map { ", branch \($0)" } ?? "") + ")"
        }
        throw OssoverError.alreadyExists(what + "; pass --allow-update to let Steam update it")
    }

    /// After a fetch: the expected executable must exist (`.missing` otherwise). Returns the
    /// ACF when steamcmd wrote one, and warnings (branch mismatch, incomplete state flags).
    public func verifyAfterFetch(branch: String?) throws -> (manifest: AppManifestACF?, warnings: [String]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw OssoverError.missing("install directory \(destination.path)")
        }
        if let exe = expectedExeURL, !fm.fileExists(atPath: exe.path) {
            throw OssoverError.missing("\(exe.path) after fetching app \(app): the download did not finish or served another build")
        }
        var warnings: [String] = []
        var manifest: AppManifestACF?
        if fm.fileExists(atPath: manifestURL.path) {
            let acf = try AppManifestACF.load(from: manifestURL)
            manifest = acf
            if let stateFlags = acf.stateFlags, stateFlags != 4 {
                warnings.append("appmanifest StateFlags=\(stateFlags) (4 = fully installed)")
            }
            let served = acf.betaKey ?? ""
            let wanted = branch ?? ""
            if served.caseInsensitiveCompare(wanted) != .orderedSame {
                warnings.append("requested branch '\(wanted.isEmpty ? "(default)" : wanted)' but the manifest records '\(served.isEmpty ? "(default)" : served)'")
            }
        } else if fm.fileExists(atPath: depotDownloaderState.path) {
            warnings.append("no appmanifest (DepotDownloader fetch): build id not recorded")
        } else {
            warnings.append("no appmanifest_\(app).acf under \(destination.path)")
        }
        return (manifest, warnings)
    }

    /// The `bottle.steam` record for a fetch.
    public static func state(app: Int, branch: String?, user: String, installDir: String, manifest: AppManifestACF?,
                             at: Date = Date()) -> SteamState {
        SteamState(appID: app, branch: branch, buildID: manifest?.buildID, betaKey: manifest?.betaKey ?? branch,
                   installDir: installDir, fetchedAt: at, account: user)
    }

    /// `verifyAfterFetch` + record `steam` on the bottle + save `bottle.json`. Returns the
    /// updated bottle and the warnings. The install directory is stored as a Windows path
    /// (`C:\Games\The Witcher 3`) relative to the bottle's prefix.
    public func commit(bottle: Bottle, layout: BottleLayout, branch: String?, user: String,
                       at: Date = Date()) throws -> (bottle: Bottle, warnings: [String]) {
        let (manifest, warnings) = try verifyAfterFetch(branch: branch)
        var updated = bottle
        updated.steam = Self.state(app: app, branch: branch, user: user,
                                   installDir: WindowsPath.toWindows(destination, prefix: layout.prefix),
                                   manifest: manifest, at: at)
        try updated.save(to: layout.bottleJSON)
        return (updated, warnings)
    }
}
