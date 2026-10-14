// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fallback A for the Witcher 3 depot (plan §3 Phase 3): SteamRE's DepotDownloader, a native
/// arm64 .NET tool (MIT). ossover never downloads it; the user unpacks a release under
/// `tools/depotdownloader/` and this builds the command line. Like steamcmd it asks for the
/// password and Steam Guard code in its own terminal; nothing here takes one.
///
/// DepotDownloader writes no `appmanifest_<app>.acf`; it keeps its own state in
/// `<dest>/.DepotDownloader/`, which `SteamFetchGuard` treats as evidence of a prior fetch.
public enum DepotDownloader {
    public static let directoryName = "depotdownloader"
    public static let executableName = "DepotDownloader"
    /// The directory DepotDownloader keeps its manifests in, under the install directory.
    public static let stateDirectoryName = ".DepotDownloader"
    public static let releasesPage = "https://github.com/SteamRE/DepotDownloader/releases"

    /// `tools/depotdownloader/DepotDownloader`.
    public static func toolURL(paths: OssoverPaths) -> URL {
        paths.tools.appending(path: directoryName, directoryHint: .isDirectory).appending(path: executableName)
    }

    public static func isInstalled(paths: OssoverPaths) -> Bool {
        FileManager.default.isExecutableFile(atPath: toolURL(paths: paths).path)
    }

    public static func installHint(paths: OssoverPaths) -> String {
        "unpack a DepotDownloader release (\(releasesPage), macos-arm64) so that \(toolURL(paths: paths).path) is executable"
    }

    /// Throws `.missing` with the install hint when the tool is not there.
    public static func require(paths: OssoverPaths) throws -> URL {
        let url = toolURL(paths: paths)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw OssoverError.missing("DepotDownloader: \(installHint(paths: paths))")
        }
        return url
    }

    /// `DepotDownloader -app <app> -branch <b> -os windows -osarch 64 -username <u> -dir <dest> -validate`
    /// (`-branch` omitted for the default branch).
    public static func command(tool: URL, app: Int, branch: String?, user: String, destination: URL) -> [String] {
        var argv = [tool.path, "-app", String(app)]
        if let branch, !branch.isEmpty { argv += ["-branch", branch] }
        argv += ["-os", "windows", "-osarch", "64", "-username", user, "-dir", destination.path, "-validate"]
        return argv
    }

    /// `<dest>/.DepotDownloader`.
    public static func stateDirectory(installDir: URL) -> URL {
        installDir.appending(path: stateDirectoryName, directoryHint: .isDirectory)
    }
}
