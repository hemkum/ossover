// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/SteamLibrary.swift (parseManifest) (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette

import Foundation

/// `steamapps/appmanifest_<app>.acf`: what Steam (or steamcmd) recorded about an installed
/// app. With `force_install_dir <dest>` steamcmd writes it at `<dest>/steamapps/`.
///
/// ```
/// "AppState"
/// {
///     "appid"        "292030"
///     "name"         "The Witcher 3: Wild Hunt"
///     "StateFlags"   "4"
///     "installdir"   "The Witcher 3"
///     "buildid"      "12345678"
///     "SizeOnDisk"   "53687091200"
///     "UserConfig"   { "BetaKey" "next-gen" }
///     "MountedConfig" { "BetaKey" "next-gen" }
/// }
/// ```
public struct AppManifestACF: Equatable, Sendable {
    public static let steamappsDirectoryName = "steamapps"

    public var appID: Int
    public var name: String?
    public var buildID: String?
    public var installDir: String?
    /// `UserConfig/BetaKey`, else `MountedConfig/BetaKey`, else a top-level `betakey`; nil on
    /// the default (public) branch.
    public var betaKey: String?
    public var sizeOnDisk: Int64?
    /// 4 = fully installed.
    public var stateFlags: Int?
    public var lastUpdated: Date?
    /// Everything under `AppState`, for keys this type does not model.
    public var fields: VDFObject

    public init(appID: Int, name: String? = nil, buildID: String? = nil, installDir: String? = nil, betaKey: String? = nil,
                sizeOnDisk: Int64? = nil, stateFlags: Int? = nil, lastUpdated: Date? = nil, fields: VDFObject = VDFObject()) {
        self.appID = appID
        self.name = name
        self.buildID = buildID
        self.installDir = installDir
        self.betaKey = betaKey
        self.sizeOnDisk = sizeOnDisk
        self.stateFlags = stateFlags
        self.lastUpdated = lastUpdated
        self.fields = fields
    }

    /// StateFlags 4: fully installed.
    public var isFullyInstalled: Bool { stateFlags == 4 }

    public static func fileName(app: Int) -> String { "appmanifest_\(app).acf" }

    /// `<steamapps>/appmanifest_<app>.acf`.
    public static func url(steamapps: URL, app: Int) -> URL { steamapps.appending(path: fileName(app: app)) }

    /// `<installDir>/steamapps/appmanifest_<app>.acf`: where a `force_install_dir` fetch puts it.
    public static func url(installDir: URL, app: Int) -> URL {
        url(steamapps: installDir.appending(path: steamappsDirectoryName, directoryHint: .isDirectory), app: app)
    }

    // MARK: Parsing

    /// Parses ACF text. The `AppState` object is used when present, else the first object, else
    /// the top level (so a flat `"key" "value"` file still reads).
    public static func parse(_ text: String) throws -> AppManifestACF {
        let root = try VDF.parse(text)
        let state = root.object("AppState") ?? root.entries.lazy.compactMap(\.value.object).first ?? root
        guard let appText = state.string("appid"), let appID = Int(appText) else {
            throw OssoverError.invalid("appmanifest: no numeric 'appid'")
        }
        let betaKey = [state.object("UserConfig")?.string("BetaKey"),
                       state.object("MountedConfig")?.string("BetaKey"),
                       state.string("betakey")]
            .compactMap { $0 }.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let updated = state.string("LastUpdated").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        return AppManifestACF(
            appID: appID,
            name: state.string("name"),
            buildID: state.string("buildid").flatMap { $0.isEmpty ? nil : $0 },
            installDir: state.string("installdir"),
            betaKey: betaKey,
            sizeOnDisk: state.string("SizeOnDisk").flatMap(Int64.init),
            stateFlags: state.string("StateFlags").flatMap(Int.init),
            lastUpdated: updated,
            fields: state
        )
    }

    public static func load(from url: URL) throws -> AppManifestACF {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OssoverError.missing("\(url.path): \(error.localizedDescription)")
        }
        do {
            return try parse(String(decoding: data, as: UTF8.self))
        } catch let error as OssoverError {
            if case let .invalid(what) = error { throw OssoverError.invalid("\(url.lastPathComponent): \(what)") }
            throw error
        }
    }
}
