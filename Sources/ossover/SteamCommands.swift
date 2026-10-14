// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct SteamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steam",
        abstract: "Fetch a game's depot into a bottle with steamcmd (or DepotDownloader). No Steam client, no password handling.",
        discussion: """
            The tool runs in this terminal: you type the Steam password and the Steam Guard code at its own \
            prompt, ossover never reads them. A fetched app is pinned: fetching it again needs --allow-update, \
            so Steam cannot silently move The Witcher 3 4.04 to the DirectX-12-only 5.x Remastered.
            """,
        subcommands: [Branches.self, Fetch.self])

    struct Branches: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List an app's branches (steamcmd app_info_print) to find the right -beta key.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Steam app id (292030 = The Witcher 3).") var app: Int
        @Option(help: "Steam account name (never a password).") var user: String
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            try SteamCMD.validateUser(user)
            let steamcmd = try await SteamCMD.require()
            let argv = SteamCMD.branchesCommand(steamcmd: steamcmd, app: app, user: user)
            let paths = global.paths
            try paths.ensureLayout()
            let transcript = paths.logs.appending(path: "steamcmd-branches-\(app)-\(Format.timestamp(Date())).log")
            defer { try? FileManager.default.removeItem(at: transcript) }

            Console.note("running: " + SteamCMD.commandLine(argv))
            Console.note("steamcmd runs in this terminal (through `script`, so its prompts show); the transcript is parsed and deleted")
            let status = try Shell.runInteractive(executable: Foreground.scriptExecutable, args: Foreground.scriptArguments(transcript: transcript, argv: argv))
            let output = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
            let branches = SteamCMD.parseBranches(output)
            if json { return try Console.json(branches.map(BranchRow.init)) }
            guard !branches.isEmpty else {
                Console.error("no branches block in steamcmd's output (exit \(status)); did the login succeed?")
                throw failure()
            }
            Console.table(["Branch", "Build", "Description", "Password", "Updated"], branches.map {
                [$0.name, Format.optional($0.buildID), Format.optional($0.description), Table.yesNo($0.passwordRequired), Format.date($0.timeUpdated)]
            })
            if status != 0 { Console.warn("steamcmd exited \(status)") }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download an app's Windows depot into a bottle (runscript: force_install_dir before login, app_update -beta <branch> validate).")

        @OptionGroup var global: GlobalOptions
        @Option(help: "Bottle to fetch into.") var bottle: String
        @Option(help: "Steam app id.") var app: Int
        @Option(help: "Branch (-beta key), e.g. next-gen; default branch when omitted.") var branch: String?
        @Option(help: "Steam account name (never a password).") var user: String
        @Option(help: "Windows install directory inside the bottle (default: C:\\Games\\<app name>).") var dest: String?
        @Flag(name: .customLong("allow-update"), help: "Fetch again over an existing install (may change the game version).") var allowUpdate = false
        @Option(help: "steamcmd (default) or depotdownloader.") var tool: SteamTool = .steamcmd

        func run() async throws {
            let paths = global.paths
            try SteamCMD.validateUser(user)
            let session = try BottleSession.open(bottle, paths: paths)
            let destWindows = dest ?? SteamDefaults.installDir(app: app)
            let destination = try Self.destination(destWindows, layout: session.layout)
            let fetchGuard = SteamFetchGuard(app: app, destination: destination)
            try fetchGuard.checkBeforeFetch(allowUpdate: allowUpdate)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                throw OssoverError.io("cannot create \(destination.path): \(error.localizedDescription)")
            }

            let argv: [String]
            var staged: URL?
            switch tool {
            case .steamcmd:
                let steamcmd = try await SteamCMD.require()
                let runscript = try SteamCMD.writeRunscript(layout: session.layout, app: app, branch: branch, user: user, destination: destination)
                Console.note("runscript \(runscript.path):")
                Console.note(SteamCMD.runscriptText(app: app, branch: branch, user: user, destination: destination))
                // steamcmd re-tokenises its +commands on whitespace, so it reads a copy at a space-free path.
                let copy = try SteamCMD.stageRunscript(runscript)
                staged = copy
                argv = SteamCMD.fetchCommand(steamcmd: steamcmd, runscript: copy)
            case .depotdownloader:
                let toolURL = try DepotDownloader.require(paths: paths)
                argv = DepotDownloader.command(tool: toolURL, app: app, branch: branch, user: user, destination: destination)
            }
            defer { if let staged { SteamCMD.unstageRunscript(staged) } }
            guard let executable = argv.first else { throw OssoverError.invalid("empty command") }
            Console.note("running: " + SteamCMD.commandLine(argv))
            Console.note("type the Steam password and the Steam Guard code at the tool's prompt; ossover never sees them")
            let status = try Shell.runInteractive(executable: executable, args: Array(argv.dropFirst()))
            guard status == 0 else {
                Console.error("\(tool.rawValue) exited \(status); nothing recorded in bottle.json")
                throw failure()
            }

            let (updated, warnings) = try fetchGuard.commit(bottle: session.bottle, layout: session.layout, branch: branch, user: user)
            for warning in warnings { Console.warn(warning) }
            let state = updated.steam
            print("fetched app \(app)" + (branch.map { " branch \($0)" } ?? "") + " into \(destWindows)"
                  + " (build \(state?.buildID ?? "?"), betakey \(state?.betaKey ?? "-"))")
            print("recorded in bottle.json; fetching again needs --allow-update")
        }

        /// `--dest` as a Unix directory inside the bottle's prefix.
        static func destination(_ windowsPath: String, layout: BottleLayout) throws -> URL {
            guard WindowsPath.isAbsolute(windowsPath), let url = WindowsPath.toUnix(windowsPath, prefix: layout.prefix) else {
                throw ValidationError("--dest must be an absolute Windows path such as C:\\Games\\The Witcher 3, got '\(windowsPath)'")
            }
            guard url.path.hasPrefix(layout.driveC.path + "/") else {
                throw ValidationError("--dest must be on the bottle's C: drive, got '\(windowsPath)'")
            }
            return url
        }
    }
}

/// Where a depot lands when `--dest` is not given.
enum SteamDefaults {
    static let installDirectories: [Int: String] = [
        292030: "C:\\Games\\The Witcher 3",
    ]

    static func installDir(app: Int) -> String {
        installDirectories[app] ?? "C:\\Games\\steamapp-\(app)"
    }
}

/// `script -q <transcript> <command...>`: a pty for a tool that must talk to the user while we
/// keep a copy of what it printed.
enum Foreground {
    static let scriptExecutable = "/usr/bin/script"

    static func scriptArguments(transcript: URL, argv: [String]) -> [String] {
        ["-q", transcript.path] + argv
    }
}

struct BranchRow: Codable {
    var name: String
    var buildID: String?
    var description: String?
    var passwordRequired: Bool
    var timeUpdated: Date?

    init(_ branch: SteamBranch) {
        name = branch.name
        buildID = branch.buildID
        description = branch.description
        passwordRequired = branch.passwordRequired
        timeUpdated = branch.timeUpdated
    }
}

extension Format {
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
