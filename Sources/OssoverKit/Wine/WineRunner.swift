// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/WineRunner.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (direct launch, allowlisted log header, Rosetta diagnosis)
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors (`start /unix`, tool runs)

import Foundation

/// A program started by `WineRunner.launch`: the pid, the streaming process and its log.
/// Mirrors `ShellProcess` so a harness can watch it without knowing about Wine.
public final class RunningProgram: @unchecked Sendable {
    public let process: ShellProcess
    public let logURL: URL
    public let programID: String
    public let command: String

    init(process: ShellProcess, logURL: URL, programID: String, command: String) {
        self.process = process
        self.logURL = logURL
        self.programID = programID
        self.command = command
    }

    public var pid: pid_t { process.pid }
    public var isRunning: Bool { process.isRunning }
    /// Nil while running.
    public var exitStatus: Int32? { process.exitStatus }
    public var logFile: URL { logURL }
    public var startedAt: Date { process.startedAt }

    /// Suspends until the wine process exits; returns its status.
    public func waitUntilExit() async -> Int32 { await process.wait() }
    /// Same as `waitUntilExit`, under the name a `LaunchedProcess` uses.
    public func wait() async -> Int32 { await process.wait() }
    /// Blocks until exit or `timeout`; nil on timeout.
    public func waitBlocking(timeout: TimeInterval? = nil) -> Int32? { process.waitBlocking(timeout: timeout) }
    /// SIGTERM to the wine process (the prefix's other processes stay; see `WineServer.shutdown`).
    public func terminate() { process.terminate() }
    /// SIGKILL.
    public func forceKill() { process.forceKill() }
}

/// Launches Wine in a bottle (plan §4 "Process model"): `<engine wine> <unix exe> args` with the
/// parent attached, output to `bottles/<n>/logs/<ts>-<program>.log` behind an allowlisted-env
/// header; `runTool` for `wineboot`, `winecfg`, `reg`, `regedit` with captured output.
///
/// Every process it starts goes through `checkServerSync` first (decision 19, REA L-30, L-31):
/// the prefix's live wineserver and its clients must share one `WINEMSYNC`.
public struct WineRunner: Sendable {
    public let engine: Engine
    public let bottle: Bottle
    public let layout: BottleLayout
    /// The accepted GPTK (D3DMetal) pack whose `libd3dshared.dylib` every process of the bottle
    /// gets on a CrossOver-derived engine (REA L-53), nil when none is installed.
    public let gptkPack: URL?

    /// `gptkPack` explicit: nil means no GPTK row at all.
    public init(engine: Engine, bottle: Bottle, layout: BottleLayout, gptkPack: URL?) {
        self.engine = engine
        self.bottle = bottle
        self.layout = layout
        self.gptkPack = gptkPack
    }

    /// `init` for a bottle layout; the GPTK pack is the accepted one of the home the bottle sits
    /// under (`<home>/bottles/<name>`, `OssoverPaths.init(containing:)`), read from the renderer
    /// store now, so prefix init, settings re-application and launches all hand every process the
    /// same row (REA L-53) whichever path built the runner.
    public init(engine: Engine, bottle: Bottle, layout: BottleLayout) {
        self.init(engine: engine, bottle: bottle, layout: layout, gptkPack: Self.gptkPack(paths: OssoverPaths(containing: layout)))
    }

    /// `init` for a bottle under `paths`; resolves the GPTK pack from the renderer store.
    public init(engine: Engine, bottle: Bottle, paths: OssoverPaths) {
        self.init(engine: engine, bottle: bottle, layout: paths.bottleLayout(bottle.name), gptkPack: Self.gptkPack(paths: paths))
    }

    /// The accepted GPTK pack under `paths`, if any: the usable (files complete, licence accepted)
    /// d3dmetal pack with the highest version, as `WineEnvironment.make` wants it.
    public static func gptkPack(paths: OssoverPaths) -> URL? {
        RendererStore(paths: paths).pack(ofKind: .d3dmetal)?.root
    }

    /// Default timeout for a tool run (`wineboot -u` on a cold prefix takes under a minute).
    public static let toolTimeout: TimeInterval = 600

    // MARK: Log header (pure)

    /// Prefixes of the variables a log header may show; never the whole environment (a bottle's
    /// env can hold personal paths or tokens, and logs get pasted into bug reports). `WINE`
    /// covers the fixed `WINESERVER`/`WINELOADER` rows (REA L-10) and the sync rows.
    public static let loggedPrefixes = ["WINE", "CX_", "DXMT_", "D3DM_", "DXVK_", "MTL_", "ROSETTA_", "GST_"]
    public static let loggedKeys: Set<String> = ["LC_ALL"]

    public static func isLogged(key: String) -> Bool {
        loggedKeys.contains(key) || loggedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The lines between `Shell.runStreaming`'s command line and the output.
    public static func header(engine: Engine, bottle: Bottle, program: String, renderer: RendererSelection,
                              env: [String: String], command: String) -> String {
        let sync = WineEnvironment.effectiveSync(bottle.settings.sync, capabilities: engine.capabilities)
        var out = "# ossover engine=\(engine.id) bottle=\(bottle.name) program=\(program)\n"
        out += "# renderer=\(renderer.summary) sync=\(sync.rawValue)"
        if sync != bottle.settings.sync { out += " (bottle asks \(bottle.settings.sync.rawValue))" }
        out += " winver=\(bottle.settings.windowsVersion.rawValue) dpi=\(bottle.settings.dpi) retina=\(bottle.settings.retina ? "y" : "n")\n"
        if let note = renderer.note { out += "# note: \(note)\n" }
        out += "# command: \(command)\n"
        for line in WineEnvironment.lines(env.filter { isLogged(key: $0.key) }) { out += "# \(line)\n" }
        return out
    }

    // MARK: Resolution (pure given the user name)

    /// The Unix path of a program's `exe`: Windows variables expanded, `C:`/`Z:`/`X:` mapped.
    /// `variables` adds to the standard set (a recipe's `gameDir`).
    public static func executableURL(for program: Program, layout: BottleLayout, engine: Engine, userName: String,
                                     variables: [String: String] = [:]) throws -> URL {
        let vars = WindowsPath.standardVariables(userName: userName, engineRoot: engine.root).merging(variables) { _, new in new }
        let expanded = WindowsPath.expand(program.exe, variables: vars)
        let unresolved = WindowsPath.unresolvedVariables(in: expanded)
        guard unresolved.isEmpty else {
            throw OssoverError.invalid("program \(program.id): exe '\(program.exe)' leaves \(unresolved.joined(separator: ", ")) unresolved")
        }
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard let url = WindowsPath.toUnix(expanded, prefix: layout.prefix) else {
            throw OssoverError.invalid("program \(program.id): exe '\(program.exe)' is not an absolute Windows path")
        }
        return url
    }

    /// The working directory: the program's own (Windows path) or the exe's directory.
    public static func workingDirectory(for program: Program, exe: URL, layout: BottleLayout, engine: Engine, userName: String,
                                        variables: [String: String] = [:]) -> URL {
        guard let dir = program.workingDir, !dir.isEmpty else { return exe.deletingLastPathComponent() }
        let vars = WindowsPath.standardVariables(userName: userName, engineRoot: engine.root).merging(variables) { _, new in new }
        let expanded = WindowsPath.expand(dir, variables: vars)
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        return WindowsPath.toUnix(expanded, prefix: layout.prefix) ?? exe.deletingLastPathComponent()
    }

    /// Wine's argument list for a launch mode.
    public static func wineArguments(exe: URL, args: [String], launchMode: LaunchMode) -> [String] {
        switch launchMode {
        case .direct: return [exe.path] + args
        case .start: return ["start", "/wait", "/unix", exe.path] + args
        }
    }

    // MARK: Launch

    /// Starts a bottle program and returns at once. `extra` is merged last (the bench's
    /// `MTL_HUD_*`, `WINEDEBUG=-all`); `logFile` overrides the default `logs/<ts>-<id>.log`;
    /// `restartServer` stops a wineserver started with another sync mode instead of refusing.
    public func launch(program: Program, renderer: RendererSelection, extra: [String: String] = [:],
                       variables: [String: String] = [:], logFile: URL? = nil, restartServer: Bool = false,
                       onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> RunningProgram {
        let userName = Prefix.userName(layout: layout, engine: engine)
        let exe = try Self.executableURL(for: program, layout: layout, engine: engine, userName: userName, variables: variables)
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw OssoverError.missing("program \(program.id): \(exe.path) (\(program.exe))")
        }
        let cwd = Self.workingDirectory(for: program, exe: exe, layout: layout, engine: engine, userName: userName, variables: variables)
        return try await launch(exe: exe, args: program.args, launchMode: program.launchMode, programID: program.id, cwd: cwd,
                                program: program, renderer: renderer, extra: extra, logFile: logFile, restartServer: restartServer,
                                onOutput: onOutput)
    }

    /// Starts an executable by Unix path (a dropped installer, a smoke test's notepad).
    public func launch(exe: URL, args: [String] = [], launchMode: LaunchMode = .direct, programID: String? = nil,
                       cwd: URL? = nil, program: Program? = nil, renderer: RendererSelection,
                       extra: [String: String] = [:], logFile: URL? = nil, restartServer: Bool = false,
                       onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> RunningProgram {
        try checkCanRun()
        let id = programID ?? Program.slug(exe.deletingPathExtension().lastPathComponent)
        let env = environment(program: program, renderer: renderer, extra: extra)
        try await checkServerSync(environment: env, restartServer: restartServer)
        ensureCache()
        let args = Self.wineArguments(exe: exe, args: args, launchMode: launchMode)
        let command = Shell.commandLine(engine.wine.path, args)
        let log = logFile ?? layout.logFile(program: id)
        let header = Self.header(engine: engine, bottle: bottle, program: id, renderer: renderer, env: env, command: command)
        let process = try Shell.runStreaming(executable: engine.wine.path, args: args, env: env,
                                             cwd: cwd ?? exe.deletingLastPathComponent(), logFile: log, header: header, onOutput: onOutput)
        return RunningProgram(process: process, logURL: log, programID: id, command: command)
    }

    // MARK: Tools

    /// Runs `wine <args>` (wineboot, winecfg, reg, regedit, …) to completion with captured
    /// output. No renderer overlay env by default; non-zero exit is in the result's `status`.
    @discardableResult
    public func runTool(_ args: [String], renderer: RendererSelection = .wined3d, extra: [String: String] = [:],
                        cwd: URL? = nil, timeout: TimeInterval? = toolTimeout, restartServer: Bool = false) async throws -> ShellResult {
        try checkCanRun()
        let env = environment(program: nil, renderer: renderer, extra: extra)
        try await checkServerSync(environment: env, restartServer: restartServer)
        ensureCache()
        return try await Shell.run(executable: engine.wine.path, args: args, env: env, cwd: cwd ?? toolDirectory, timeout: timeout)
    }

    /// `runTool` that throws `.processFailed` on a non-zero exit.
    @discardableResult
    public func runToolChecked(_ args: [String], renderer: RendererSelection = .wined3d, extra: [String: String] = [:],
                               cwd: URL? = nil, timeout: TimeInterval? = toolTimeout, restartServer: Bool = false) async throws -> ShellResult {
        try await runTool(args, renderer: renderer, extra: extra, cwd: cwd, timeout: timeout, restartServer: restartServer)
            .check(command: Shell.commandLine(engine.wine.path, args))
    }

    /// Runs `wineserver <args>` with the bottle's environment (`-k`, `-w`: talking to a server,
    /// not starting one, so no sync check).
    @discardableResult
    public func runWineserver(_ args: [String], timeout: TimeInterval? = toolTimeout) async throws -> ShellResult {
        let env = WineServer.environment(engine: engine, bottle: bottle, layout: layout, gptkPack: gptkPack)
        return try await Shell.run(executable: engine.wineserver.path, args: args, env: env, cwd: toolDirectory, timeout: timeout)
    }

    /// The environment a launch of `program` would get (for `ossover run --print-env` and tests).
    public func environment(program: Program? = nil, renderer: RendererSelection, extra: [String: String] = [:]) -> [String: String] {
        WineEnvironment.make(engine: engine, bottle: bottle, layout: layout, program: program, renderer: renderer,
                             gptkPack: gptkPack, extra: extra)
    }

    /// `wineserver -k` → `-w` → leftover pids (see `WineServer`).
    @discardableResult
    public func shutdown() async throws -> WineServer.ShutdownReport {
        try await WineServer.shutdown(engine: engine, bottle: bottle, layout: layout, gptkPack: gptkPack)
    }

    // MARK: Sync (decision 19)

    /// One `WINEMSYNC` per wineserver lifetime (REA L-30, L-31): `wineserver` reads the variable
    /// like every client and a client whose value differs is `exit(1)` in `msync_init`, so
    /// `wineboot`, `winecfg`, `reg`, winetricks and every program of a prefix must carry the value
    /// its live server was started with. Refuses (throws `.invalid`) when the live server runs
    /// with another value, unless `restartServer`, in which case `WineServer.shutdown` (`-k` →
    /// `-w`) runs first and the next process starts a fresh server. `environment` is the table the
    /// process will get (its `WINEMSYNC` is what counts, so an `extra` override is honoured);
    /// nil means the bottle's tool environment. Records the value in `.sync-state.json`.
    /// A settings change of `sync` goes through here with `restartServer: true`.
    @discardableResult
    public func checkServerSync(environment: [String: String]? = nil, restartServer: Bool = false) async throws -> WineServer.SyncCheck {
        let env = environment ?? self.environment(program: nil, renderer: .wined3d)
        let wanted = env[WineEnvironment.msyncKey] ?? "0"
        var check = try await WineServer.checkSync(wanted: wanted, layout: layout, engineRoot: engine.root)
        if case let .mismatch(pid, server, _) = check {
            guard restartServer else {
                throw OssoverError.invalid("bottle \(bottle.name): its wineserver (pid \(pid)) was started with WINEMSYNC=\(server ?? "unset") "
                    + "but this launch needs WINEMSYNC=\(wanted); every process of a prefix must use the sync mode its server "
                    + "started with, so stop it first (`ossover run --restart-server`, or `ossover bottle settings` after a sync change restarts it)")
            }
            let report = try await shutdown()
            check = .restarted(pid: pid, previous: server, report: report)
        }
        let effective = WineEnvironment.effectiveSync(bottle.settings.sync, capabilities: engine.capabilities)
        try WineServer.recordSyncState(WineServer.SyncState(sync: effective, winemsync: wanted, engineID: engine.id), layout: layout)
        return check
    }

    /// `<home>/cache` for `GST_REGISTRY` (REA L-08), created when a home predates it. Best effort:
    /// GStreamer runs without a registry cache, it only rescans.
    func ensureCache() {
        try? FileManager.default.createDirectory(at: OssoverPaths(containing: layout).cache, withIntermediateDirectories: true)
    }

    /// Where tools run: `drive_c` once it exists, else the bottle directory (a fresh prefix has nothing yet).
    var toolDirectory: URL {
        FileManager.default.fileExists(atPath: layout.driveC.path) ? layout.driveC : layout.root
    }

    /// Fails early with a readable reason instead of Foundation's "Bad CPU type in executable".
    func checkCanRun() throws {
        guard FileManager.default.isExecutableFile(atPath: engine.wine.path) else {
            throw OssoverError.missing("engine \(engine.id): wine at \(engine.wine.path)")
        }
        if engine.manifest.requiresRosetta, SysInfo.isAppleSilicon(), !SysInfo.rosettaRuntimePresent() {
            throw OssoverError.unsupported("engine \(engine.id) is x86-64 and needs Rosetta 2, which is not installed: run `softwareupdate --install-rosetta --agree-to-license` and try again")
        }
    }
}
