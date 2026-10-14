// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Recipe.swift (winetricks step, winetricksExtras) (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette

import Foundation

/// Runs the vendored winetricks script against a bottle, unattended. The script is never
/// downloaded by ossover: the repository carries it at `scripts/vendor/winetricks`, pinned to
/// one commit (`pinnedCommit`, `scripts/vendor/README.md`) and one SHA-256 (`pinnedSHA256`,
/// `scripts/vendor/winetricks.sha256`). On first use it is copied into `<home>/tools/winetricks`
/// after its hash is verified, so a CLI installed outside the checkout keeps working; a `tools/`
/// copy that does not hash to the pin is replaced from the checkout or refused. Verb payloads
/// (vcrun2022 …) are what winetricks itself fetches.
public enum Winetricks {
    /// Names a script to use instead of the search path (used verbatim, not verified).
    public static let environmentKey = "OSSOVER_WINETRICKS"
    public static let scriptName = "winetricks"
    /// Where a repo checkout keeps it, and the file recording its hash.
    public static let vendorRelativePath = "scripts/vendor/winetricks"
    public static let vendorSHA256RelativePath = "scripts/vendor/winetricks.sha256"
    /// `src/winetricks` of https://github.com/Winetricks/winetricks (LGPL-2.1+) at this commit.
    public static let pinnedCommit = "f3890f670867b5ffbc3938726db45c0f7d16c8ba"
    /// SHA-256 of the pinned script. Bumping the vendored file means changing this and
    /// `scripts/vendor/winetricks.sha256` together (`WinetricksTests` ties the three).
    public static let pinnedSHA256 = "672a1ff4442e8691a3ffc0e6860137e201a1d1227e9b3044245f1731e9e9837e"
    /// Directories put in front of the minimal PATH: Homebrew (`cabextract`, `7z`) and /usr/local.
    public static let extraPATH = ["/opt/homebrew/bin", "/usr/local/bin"]
    public static let cabextractName = "cabextract"

    // MARK: Locating

    /// `<home>/tools/winetricks`.
    public static func installedScript(paths: OssoverPaths) -> URL { paths.tools.appending(path: scriptName) }

    /// The checkout's `scripts/vendor/winetricks`: under `repoRoot` when one is given (and only
    /// there), else the first of `cwd` and its parents, then the running executable's directory
    /// and its parents (`.build-*/debug/ossover` sits inside the checkout), that holds one.
    public static func vendoredScript(repoRoot: URL? = nil,
                                      cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                                      executable: URL? = Bundle.main.executableURL) -> URL? {
        let fm = FileManager.default
        if let repoRoot {
            let url = repoRoot.appending(path: vendorRelativePath)
            return fm.isReadableFile(atPath: url.path) ? url : nil
        }
        var roots = ancestors(of: cwd)
        if let executable { roots += ancestors(of: executable.resolvingSymlinksInPath().deletingLastPathComponent()) }
        return roots.map { $0.appending(path: vendorRelativePath) }.first { fm.isReadableFile(atPath: $0.path) }
    }

    /// `url`, its parent, … up to and including `/` (walked on path strings: URL's
    /// `deletingLastPathComponent()` turns `/` into `/..` and never stops).
    static func ancestors(of url: URL) -> [URL] {
        var out: [URL] = []
        var path = url.standardizedFileURL.path
        if path.isEmpty { path = "/" }
        while true {
            out.append(URL(fileURLWithPath: path, isDirectory: true))
            if path == "/" { break }
            let parent = (path as NSString).deletingLastPathComponent
            path = parent.isEmpty ? "/" : parent
        }
        return out
    }

    /// Where the script is looked for, in order: `$OSSOVER_WINETRICKS`, `<home>/tools/winetricks`,
    /// the checkout's `scripts/vendor/winetricks` (see `vendoredScript`).
    public static func candidates(paths: OssoverPaths, repoRoot: URL? = nil,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let explicit = environment[environmentKey], !explicit.isEmpty { out.append(URL(fileURLWithPath: explicit)) }
        out.append(installedScript(paths: paths))
        if let vendored = vendoredScript(repoRoot: repoRoot) { out.append(vendored) }
        return out
    }

    /// The first candidate that is a readable file, or nil. Nothing is copied or verified: what
    /// `doctor` shows. A run uses `prepare`.
    public static func locate(paths: OssoverPaths, repoRoot: URL? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        candidates(paths: paths, repoRoot: repoRoot, environment: environment).first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// The script a run uses. `$OSSOVER_WINETRICKS` wins verbatim. Otherwise
    /// `<home>/tools/winetricks` when it hashes to `expectedSHA256`; else it is installed (or a
    /// stale copy replaced) from the checkout's vendored script, which is verified first and
    /// again after the copy. Throws `.missing` when no script can be found,
    /// `.checksumMismatch` when a copy is not the pinned script.
    @discardableResult
    public static func prepare(paths: OssoverPaths, repoRoot: URL? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               expectedSHA256: String = pinnedSHA256) throws -> URL {
        let fm = FileManager.default
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            guard fm.isReadableFile(atPath: url.path) else {
                throw OssoverError.missing("\(environmentKey)=\(explicit) is not a readable file")
            }
            return url
        }
        let installed = installedScript(paths: paths)
        var installedHash: String?
        if fm.isReadableFile(atPath: installed.path) {
            installedHash = try SHA256Hasher.hex(ofFile: installed)
            if installedHash == expectedSHA256.lowercased() { return installed }
        }
        guard let vendored = vendoredScript(repoRoot: repoRoot) else {
            if let installedHash {
                throw OssoverError.checksumMismatch(file: installed.path, expected: expectedSHA256.lowercased(), actual: installedHash)
            }
            throw missingScriptError(paths: paths)
        }
        try SHA256Hasher.verify(file: vendored, expected: expectedSHA256)
        try install(vendored, to: installed)
        try SHA256Hasher.verify(file: installed, expected: expectedSHA256)
        return installed
    }

    /// Copies `source` to `destination` (parent created, an existing file replaced) and makes
    /// it executable; the copy lands under a temporary name first.
    static func install(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(scriptName).\(getpid()).tmp")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: temporary)
            try fm.copyItem(at: source, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        } catch let error as OssoverError {
            throw error
        } catch {
            try? fm.removeItem(at: temporary)
            throw OssoverError.io("cannot install winetricks at \(destination.path): \(error.localizedDescription)")
        }
    }

    /// `cabextract` on the PATH winetricks will get, or nil.
    public static func locateCabextract() -> URL? {
        (extraPATH + Shell.minimalPATH.split(separator: ":").map(String.init))
            .map { URL(fileURLWithPath: $0).appending(path: cabextractName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The error for a missing script, with what to do about it.
    public static func missingScriptError(paths: OssoverPaths) -> OssoverError {
        .missing("winetricks script: not at \(installedScript(paths: paths).path) and no checkout with \(vendorRelativePath) above the working directory or the ossover binary. Run ossover from the checkout once (the pinned script is copied into tools/), copy it there yourself (https://github.com/Winetricks/winetricks src/winetricks at commit \(pinnedCommit), sha256 \(pinnedSHA256)), or set \(environmentKey); ossover does not download it")
    }

    // MARK: Running

    /// The variables a winetricks run adds on top of the bottle's env (pure): the engine's
    /// binaries, unattended mode, and a PATH that finds `cabextract`. `gptkPack` as in
    /// `WineEnvironment.make`.
    public static func environment(engine: Engine, bottle: Bottle, layout: BottleLayout, gptkPack: URL? = nil) -> [String: String] {
        var env = WineEnvironment.make(engine: engine, bottle: bottle, layout: layout, program: nil, renderer: .wined3d, gptkPack: gptkPack)
        env["WINE"] = engine.wine.path
        env["WINESERVER"] = engine.wineserver.path
        env["WINE_BIN"] = engine.wine.path
        env["WINESERVER_BIN"] = engine.wineserver.path
        env["WINE_BINDIR"] = engine.wine.deletingLastPathComponent().path
        env["WINEARCH"] = "win64"
        env["W_OPT_UNATTENDED"] = "1"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        env["PATH"] = (extraPATH + [engine.wine.deletingLastPathComponent().path, Shell.minimalPATH]).joined(separator: ":")
        return env
    }

    /// Runs `winetricks --unattended <verbs>` streaming to `logs/<ts>-winetricks-<verbs>.log`.
    /// The script is `script`, else `prepare`'s (installed into `tools/` on first use). Throws
    /// `.missing` when the script or `cabextract` is absent, `.processFailed` on a non-zero
    /// exit. Returns the log file.
    @discardableResult
    public static func run(verbs: [String], engine: Engine, bottle: Bottle, layout: BottleLayout, paths: OssoverPaths,
                           script: URL? = nil, onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> URL {
        guard !verbs.isEmpty else { throw OssoverError.invalid("winetricks: no verbs") }
        let script = try script ?? prepare(paths: paths)
        guard locateCabextract() != nil else {
            throw OssoverError.missing("cabextract (winetricks needs it): brew install cabextract")
        }
        guard layout.prefixInitialised else {
            throw OssoverError.missing("prefix \(layout.prefix.path) is not initialised; create the bottle first")
        }
        // Every wine process winetricks starts is a client of the prefix's server: same WINEMSYNC
        // (decision 19) and the same GPTK row as a launch.
        let runner = WineRunner(engine: engine, bottle: bottle, layout: layout, gptkPack: WineRunner.gptkPack(paths: paths))
        try await runner.checkServerSync()
        let env = environment(engine: engine, bottle: bottle, layout: layout, gptkPack: runner.gptkPack)
        let args = [script.path, "--unattended"] + verbs
        let log = layout.logFile(program: "winetricks-" + verbs.joined(separator: "-"))
        let header = "# ossover winetricks \(verbs.joined(separator: " ")) bottle=\(bottle.name) engine=\(engine.id) script=\(script.path)\n"
        let process = try Shell.runStreaming(executable: "/bin/bash", args: args, env: env, cwd: layout.root,
                                             logFile: log, header: header, onOutput: onOutput)
        let status = await process.wait()
        guard status == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw OssoverError.processFailed(command: Shell.commandLine("/bin/bash", args), status: status, output: tail)
        }
        return log
    }
}
