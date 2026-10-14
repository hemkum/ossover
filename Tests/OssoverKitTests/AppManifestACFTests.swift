// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct AppManifestACFTests {
    @Test func parsesTheWitcherFixture() throws {
        let manifest = try AppManifestACF.load(from: Fixtures.url("acf/appmanifest_292030.acf"))
        #expect(manifest.appID == 292030)
        #expect(manifest.name == "The Witcher 3: Wild Hunt")
        #expect(manifest.buildID == "11916098")
        #expect(manifest.installDir == "The Witcher 3")
        #expect(manifest.betaKey == "next-gen")
        #expect(manifest.stateFlags == 4)
        #expect(manifest.isFullyInstalled)
        #expect(manifest.sizeOnDisk == 53_687_091_200)
        #expect(manifest.lastUpdated == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(manifest.fields.string("TargetBuildID") == "11916098")
        #expect(manifest.fields.object("InstalledDepots")?.object("292031")?.string("size") == "1073741824")
        #expect(manifest.fields.string("LauncherPath") == #"C:\Program Files (x86)\Steam\steam.exe"#, "VDF unescapes backslashes")
    }

    @Test func betaKeyFallsBackThroughTheConfigs() throws {
        let mounted = try AppManifestACF.parse(#""AppState" { "appid" "1" "MountedConfig" { "BetaKey" "beta1" } }"#)
        #expect(mounted.betaKey == "beta1")
        let flat = try AppManifestACF.parse(#""AppState" { "appid" "1" "betakey" "classic" "buildid" "" }"#)
        #expect(flat.betaKey == "classic")
        #expect(flat.buildID == nil, "an empty buildid is no buildid")
        let none = try AppManifestACF.parse(#""AppState" { "appid" "1" "UserConfig" { "language" "english" } }"#)
        #expect(none.betaKey == nil)
        #expect(none.stateFlags == nil)
        #expect(!none.isFullyInstalled)
    }

    @Test func rejectsAFileWithoutAppID() {
        #expect(throws: OssoverError.self) { try AppManifestACF.parse(#""AppState" { "name" "x" }"#) }
    }

    @Test func pathsFollowSteamsLayout() {
        let install = URL(fileURLWithPath: "/ossover-test/bottles/w/prefix/drive_c/Games/The Witcher 3", isDirectory: true)
        #expect(AppManifestACF.fileName(app: 292030) == "appmanifest_292030.acf")
        #expect(AppManifestACF.url(installDir: install, app: 292030).path
                == "/ossover-test/bottles/w/prefix/drive_c/Games/The Witcher 3/steamapps/appmanifest_292030.acf")
    }

    @Test func fetchGuardRefusesASecondFetchWithoutAllowUpdate() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetchGuard = SteamFetchGuard(app: 292030, destination: dir)
        #expect(fetchGuard.expectedExe == "bin/x64/witcher3.exe")
        #expect(!fetchGuard.hasPriorFetch)
        try fetchGuard.checkBeforeFetch(allowUpdate: false)

        let acf = fetchGuard.manifestURL
        try FileManager.default.createDirectory(at: acf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("acf/appmanifest_292030.acf"), to: acf)
        #expect(fetchGuard.hasPriorFetch)
        #expect(throws: OssoverError.self) { try fetchGuard.checkBeforeFetch(allowUpdate: false) }
        do {
            try fetchGuard.checkBeforeFetch(allowUpdate: false)
        } catch let error as OssoverError {
            #expect(error.errorDescription?.contains("--allow-update") == true)
        }
        try fetchGuard.checkBeforeFetch(allowUpdate: true)

        #expect(throws: OssoverError.self) { try fetchGuard.verifyAfterFetch(branch: "next-gen") }
        let exe = dir.appending(path: "bin/x64/witcher3.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        let (manifest, warnings) = try fetchGuard.verifyAfterFetch(branch: "next-gen")
        #expect(manifest?.buildID == "11916098")
        #expect(warnings.isEmpty)
        let (_, mismatch) = try fetchGuard.verifyAfterFetch(branch: "classic")
        #expect(!mismatch.isEmpty, "a betakey that differs from the requested branch is reported")
    }
}
