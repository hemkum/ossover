// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct SteamCMDTests {
    static let destination = URL(fileURLWithPath: "/ossover-test/bottles/witcher3/prefix/drive_c/Games/The Witcher 3", isDirectory: true)
    static let steamcmd = URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd")

    @Test func runscriptTextIsExact() {
        let text = SteamCMD.runscriptText(app: 292030, branch: "next-gen", user: "steamuser", destination: Self.destination)
        #expect(text == """
            @sSteamCmdForcePlatformType windows
            @ShutdownOnFailedCommand 1
            force_install_dir "/ossover-test/bottles/witcher3/prefix/drive_c/Games/The Witcher 3"
            login steamuser
            app_update 292030 -beta next-gen validate
            quit

            """)
        let plain = SteamCMD.runscriptText(app: 292030, branch: nil, user: "steamuser",
                                           destination: URL(fileURLWithPath: "/tmp/dest", isDirectory: true))
        #expect(plain == "@sSteamCmdForcePlatformType windows\n@ShutdownOnFailedCommand 1\nforce_install_dir /tmp/dest\n"
                + "login steamuser\napp_update 292030 validate\nquit\n")
        #expect(SteamCMD.quote("/no/spaces") == "/no/spaces")
        #expect(SteamCMD.quote("/with space") == "\"/with space\"")
        #expect(SteamCMD.quote("/a\"b") == "\"/a\\\"b\"")
    }

    @Test func commandLinesAreExact() {
        let runscript = URL(fileURLWithPath: "/ossover-test/bottles/witcher3/steamcmd/fetch-292030.txt")
        #expect(SteamCMD.fetchCommand(steamcmd: Self.steamcmd, runscript: runscript)
                == ["/opt/homebrew/bin/steamcmd", "+runscript", "/ossover-test/bottles/witcher3/steamcmd/fetch-292030.txt"])
        #expect(SteamCMD.commandLine(SteamCMD.fetchCommand(steamcmd: Self.steamcmd, runscript: runscript))
                == "/opt/homebrew/bin/steamcmd +runscript /ossover-test/bottles/witcher3/steamcmd/fetch-292030.txt")
        #expect(SteamCMD.branchesCommand(steamcmd: Self.steamcmd, app: 292030, user: "steamuser")
                == ["/opt/homebrew/bin/steamcmd", "+login", "steamuser", "+app_info_update", "1", "+app_info_print", "292030", "+quit"])
        #expect(SteamCMD.commandLine(["/x/steamcmd", "+runscript", "/with space/f.txt"]) == "/x/steamcmd +runscript '/with space/f.txt'")
        #expect(SteamCMD.commandLine([]) == "")
        #expect(SteamCMD.runscriptURL(layout: Fixtures.paths.bottleLayout("witcher3"), app: 292030).path
                == "/ossover-test/bottles/witcher3/steamcmd/fetch-292030.txt")
    }

    @Test func depotDownloaderCommandIsExact() {
        let tool = URL(fileURLWithPath: "/ossover-test/tools/depotdownloader/DepotDownloader")
        #expect(DepotDownloader.command(tool: tool, app: 292030, branch: "next-gen", user: "steamuser", destination: Self.destination) == [
            "/ossover-test/tools/depotdownloader/DepotDownloader", "-app", "292030", "-branch", "next-gen", "-os", "windows",
            "-osarch", "64", "-username", "steamuser", "-dir", "/ossover-test/bottles/witcher3/prefix/drive_c/Games/The Witcher 3", "-validate",
        ])
        #expect(DepotDownloader.command(tool: tool, app: 1, branch: nil, user: "u", destination: URL(fileURLWithPath: "/d"))
                == ["/ossover-test/tools/depotdownloader/DepotDownloader", "-app", "1", "-os", "windows", "-osarch", "64", "-username", "u", "-dir", "/d", "-validate"])
        #expect(DepotDownloader.toolURL(paths: Fixtures.paths).path == "/ossover-test/tools/depotdownloader/DepotDownloader")
        #expect(DepotDownloader.stateDirectory(installDir: Self.destination).lastPathComponent == ".DepotDownloader")
    }

    @Test func userNamesCannotSmuggleCommands() throws {
        try SteamCMD.validateUser("steamuser")
        try SteamCMD.validateUser("user_123.x")
        for bad in ["", " ", "user name", "\"quoted\"", "+quit", "-x", "@sSteamCmd", "a\tb"] {
            #expect(throws: OssoverError.self, Comment(rawValue: bad)) { try SteamCMD.validateUser(bad) }
        }
    }

    @Test func runscriptIsWrittenIntoTheBottle() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = OssoverPaths(home: home).bottleLayout("witcher3")
        let url = try SteamCMD.writeRunscript(layout: layout, app: 292030, branch: "next-gen", user: "steamuser", destination: Self.destination)
        #expect(url == SteamCMD.runscriptURL(layout: layout, app: 292030))
        #expect(try String(contentsOf: url, encoding: .utf8)
                == SteamCMD.runscriptText(app: 292030, branch: "next-gen", user: "steamuser", destination: Self.destination))
        #expect(throws: OssoverError.self) {
            try SteamCMD.writeRunscript(layout: layout, app: 1, branch: nil, user: "+quit", destination: Self.destination)
        }
    }

    @Test func stagedRunscriptHasNoWhitespaceInItsPath() throws {
        let home = try Fixtures.temporaryDirectory().appending(path: "with space", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let layout = OssoverPaths(home: home).bottleLayout("witcher3")
        let url = try SteamCMD.writeRunscript(layout: layout, app: 292030, branch: "next-gen", user: "steamuser", destination: Self.destination)
        #expect(url.path.contains(" "), "the bottle's own copy may sit under a path with spaces")
        let staged = try SteamCMD.stageRunscript(url)
        defer { SteamCMD.unstageRunscript(staged) }
        #expect(!staged.path.contains { $0.isWhitespace })
        #expect(staged.lastPathComponent == "fetch-292030.txt")
        let stagedData = try Data(contentsOf: staged)
        let original = try Data(contentsOf: url)
        #expect(stagedData == original)
        #expect(SteamCMD.fetchCommand(steamcmd: Self.steamcmd, runscript: staged).last == staged.path)
        SteamCMD.unstageRunscript(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func branchesParseFromConsoleChatter() {
        let output = """
            Redirecting stderr to '/Users/x/Library/Application Support/Steam/logs/stderr.txt'
            [  0%] Checking for available updates...
            Steam Console Client (c) Valve Corporation - version 1759000000
            -- type 'quit' to exit --
            Loading Steam API...OK
            Logging in using username 'steamuser'...
            "292030"
            {
            \t"common"
            \t{
            \t\t"name"\t\t"The Witcher 3: Wild Hunt"
            \t}
            \t"depots"
            \t{
            \t\t"branches"
            \t\t{
            \t\t\t"public"
            \t\t\t{
            \t\t\t\t"buildid"\t\t"18000000"
            \t\t\t\t"timeupdated"\t\t"1750000000"
            \t\t\t}
            \t\t\t"next-gen"
            \t\t\t{
            \t\t\t\t"buildid"\t\t"11916098"
            \t\t\t\t"description"\t\t"4.04 next-gen"
            \t\t\t\t"timeupdated"\t\t"1700000000"
            \t\t\t}
            \t\t\t"classic"
            \t\t\t{
            \t\t\t\t"buildid"\t\t"3000000"
            \t\t\t\t"description"\t\t"1.32 classic"
            \t\t\t\t"pwdrequired"\t\t"1"
            \t\t\t}
            \t\t}
            \t}
            }
            """
        let branches = SteamCMD.parseBranches(output)
        #expect(branches.map(\.name) == ["public", "next-gen", "classic"])
        #expect(branches[1].buildID == "11916098")
        #expect(branches[1].description == "4.04 next-gen")
        #expect(branches[1].timeUpdated == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!branches[1].passwordRequired)
        #expect(branches[2].passwordRequired)
        #expect(branches[0].description == nil)
        #expect(SteamCMD.parseBranches("no vdf here").isEmpty)
    }

    @Test func locateFindsNothingInAnEmptyEnvironment() {
        #expect(SteamCMD.locate(environment: ["PATH": "/nonexistent-ossover-dir"]) == nil
                || SteamCMD.knownLocations.contains { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
