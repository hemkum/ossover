// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One Steam branch as `app_info_print` lists it under `depots/branches`.
public struct SteamBranch: Equatable, Sendable, Identifiable {
    public var name: String
    public var buildID: String?
    public var description: String?
    /// `pwdrequired 1`: a private beta that needs a branch password (entered in steamcmd's TTY).
    public var passwordRequired: Bool
    public var timeUpdated: Date?

    public init(name: String, buildID: String? = nil, description: String? = nil, passwordRequired: Bool = false, timeUpdated: Date? = nil) {
        self.name = name
        self.buildID = buildID
        self.description = description
        self.passwordRequired = passwordRequired
        self.timeUpdated = timeUpdated
    }

    public var id: String { name }
}

/// Builds what `ossover steam branches` / `steam fetch` run. steamcmd is an Intel binary (needs
/// Rosetta) that talks to the user in a terminal: Steam password and Steam Guard code go
/// straight into its TTY. Nothing here takes, logs or stores a password, and a user name with
/// whitespace is rejected so `login <user>` cannot smuggle one in.
///
/// Plan §3 Phase 3: the runscript forces the Windows depot, puts `force_install_dir` **before**
/// `login` (steamcmd ignores it afterwards), pins the branch with `-beta`, validates, quits.
public enum SteamCMD {
    public static let knownLocations = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]
    public static let executableName = "steamcmd"
    public static let installHint = "brew install --cask steamcmd (needs Rosetta 2: softwareupdate --install-rosetta --agree-to-license)"

    // MARK: Location

    /// The first steamcmd found: the Homebrew locations, then `PATH` from `environment`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var candidates = knownLocations
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(executableName)" }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// `locate` + the Rosetta check; throws `.missing` / `.unsupported`.
    public static func require(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> URL {
        guard let url = locate(environment: environment) else {
            throw OssoverError.missing("steamcmd (\(installHint))")
        }
        try await requireRosetta()
        return url
    }

    /// steamcmd is x86-64 only: on Apple silicon Rosetta 2 must be installed.
    public static func requireRosetta() async throws {
        guard SysInfo.isAppleSilicon() else { return }
        guard await SysInfo.rosettaInstalled() else {
            throw OssoverError.unsupported("steamcmd is an Intel binary and Rosetta 2 is not installed: run `softwareupdate --install-rosetta --agree-to-license`")
        }
    }

    // MARK: Runscript

    /// Non-empty, no whitespace, no leading `+`/`-`/`@` (which steamcmd would read as a command).
    public static func validateUser(_ user: String) throws {
        guard !user.isEmpty, !user.contains(where: \.isWhitespace), !user.contains("\""),
              let first = user.first, first != "+", first != "-", first != "@" else {
            throw OssoverError.invalid("Steam user name '\(user)' is not usable (one word, no quotes)")
        }
    }

    /// A path for a runscript line: quoted when it has whitespace or quotes.
    public static func quote(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return path }
        return "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The runscript text, one command per line. `branch == nil` fetches the default branch.
    ///
    /// ```
    /// @sSteamCmdForcePlatformType windows
    /// @ShutdownOnFailedCommand 1
    /// force_install_dir <dest>
    /// login <user>
    /// app_update <app> -beta <branch> validate
    /// quit
    /// ```
    public static func runscriptText(app: Int, branch: String?, user: String, destination: URL) -> String {
        var update = "app_update \(app)"
        if let branch, !branch.isEmpty { update += " -beta \(branch)" }
        update += " validate"
        return [
            "@sSteamCmdForcePlatformType windows",
            "@ShutdownOnFailedCommand 1",
            "force_install_dir \(quote(destination.path))",
            "login \(user)",
            update,
            "quit",
        ].joined(separator: "\n") + "\n"
    }

    /// `bottles/<n>/steamcmd/fetch-<app>.txt`.
    public static func runscriptURL(layout: BottleLayout, app: Int) -> URL {
        layout.steamcmd.appending(path: "fetch-\(app).txt")
    }

    /// Writes the runscript for `app` into the bottle's `steamcmd/` directory and returns it.
    @discardableResult
    public static func writeRunscript(layout: BottleLayout, app: Int, branch: String?, user: String, destination: URL) throws -> URL {
        try validateUser(user)
        let url = runscriptURL(layout: layout, app: app)
        do {
            try FileManager.default.createDirectory(at: layout.steamcmd, withIntermediateDirectories: true)
            try Data(runscriptText(app: app, branch: branch, user: user, destination: destination).utf8).write(to: url, options: .atomic)
        } catch {
            throw OssoverError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    /// A copy of the runscript at a path without whitespace, for `+runscript`. steamcmd joins
    /// its `+command` arguments into one console line and re-tokenises it on whitespace, so a
    /// runscript under the default home (`~/Library/Application Support/ossover/…`) would be
    /// opened as `~/Library/Application`. The copy lives in a fresh directory under the
    /// system temporary directory (`/tmp` when even that has spaces); remove it with
    /// `unstageRunscript` afterwards. The bottle's own copy stays as the record of what ran.
    public static func stageRunscript(_ runscript: URL) throws -> URL {
        let fm = FileManager.default
        let base = [fm.temporaryDirectory, URL(fileURLWithPath: "/tmp", isDirectory: true)]
            .first { !$0.path.contains(where: \.isWhitespace) } ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        let directory = base.appending(path: "ossover-steamcmd-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staged = directory.appending(path: runscript.lastPathComponent)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: runscript, to: staged)
        } catch {
            throw OssoverError.io("cannot stage \(runscript.path) at \(staged.path): \(error.localizedDescription)")
        }
        return staged
    }

    /// Removes a `stageRunscript` copy and its directory; never throws.
    public static func unstageRunscript(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    // MARK: Commands (argv; the CLI execs them in the foreground TTY)

    /// `steamcmd +runscript <file>`: run interactively, steamcmd asks for the password and the
    /// Steam Guard code itself. `runscript` must not contain whitespace (`stageRunscript`).
    public static func fetchCommand(steamcmd: URL, runscript: URL) -> [String] {
        [steamcmd.path, "+runscript", runscript.path]
    }

    /// `steamcmd +login <user> +app_info_update 1 +app_info_print <app> +quit`: without the
    /// `app_info_update` a fresh install prints a reduced, cached object with no `branches`.
    public static func branchesCommand(steamcmd: URL, app: Int, user: String) -> [String] {
        [steamcmd.path, "+login", user, "+app_info_update", "1", "+app_info_print", String(app), "+quit"]
    }

    /// The command as one line, for messages and logs.
    public static func commandLine(_ argv: [String]) -> String {
        guard let executable = argv.first else { return "" }
        return Shell.commandLine(executable, Array(argv.dropFirst()))
    }

    // MARK: Parsing

    /// The branches `app_info_print` listed: the keys of every `"branches" { ... }` block in
    /// `output` (console chatter before it is skipped), first occurrence of a name wins.
    public static func parseBranches(_ output: String) -> [SteamBranch] {
        var seen = Set<String>()
        var branches: [SteamBranch] = []
        for block in VDF.objects(named: "branches", in: output) {
            for entry in block.entries where seen.insert(entry.key.lowercased()).inserted {
                let fields = entry.value.object ?? VDFObject()
                let updated = fields.string("timeupdated").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                branches.append(SteamBranch(
                    name: entry.key,
                    buildID: fields.string("buildid"),
                    description: fields.string("description"),
                    passwordRequired: fields.string("pwdrequired") == "1",
                    timeUpdated: updated
                ))
            }
        }
        return branches
    }
}
