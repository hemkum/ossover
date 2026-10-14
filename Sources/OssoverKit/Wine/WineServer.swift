// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/WineRunner.swift (kill) and ProcessTable.swift (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (killBottle) (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors

import Foundation

/// Stopping a bottle (plan §4): `wineserver -k` → `wineserver -w` (10 s cap) → SIGTERM then
/// SIGKILL whatever Wine process still carries `WINEPREFIX=<prefix>` in its environment (a
/// shell that merely exported the variable is left alone, see `ProcessTable`) or, once Wine
/// has rewritten its command line and wiped that environment from view, runs an exe inside
/// the prefix by Unix path (`isRewrittenMember`, `members(of:layout:engineRoot:)`).
///
/// `-k` asks the server to kill its clients; a client parked in the Mac driver's Cocoa run loop
/// does not always act on that before the server is gone, and a server that died abnormally
/// leaves the same debris, so the process table is the last word.
///
/// The server also owns the prefix's sync mode (decision 19, REA L-30, L-31): `wineserver` reads
/// `WINEMSYNC` like every client, and a client whose value differs from the live server's is
/// `exit(1)` in `msync_init`. `checkSync` compares a launch's value with the running server's;
/// `.sync-state.json` records the value the server lifetime started with.
public enum WineServer {
    /// How long the shutdown's `wineserver -w` may block: `-k` has already asked the clients to
    /// go, and whatever is left after this gets signals, so the cap is short.
    public static let shutdownWait: TimeInterval = 10
    /// How long a boot's `wineserver -w` may block (`Prefix.initialize`, `waitForExit`). A cold
    /// `wineboot -u` settles in well under a minute; a wait that hits this cap means something
    /// else keeps the server alive — a program from an earlier launch, usually — and the error
    /// says what (pid + command) instead of looking like a hang, which is what an uncapped
    /// `-w` on a stale `notepad.exe` was.
    public static let bootWait: TimeInterval = 120
    /// Grace between SIGTERM and SIGKILL for leftovers.
    public static let killGrace: TimeInterval = 2
    /// The command that ends a busy prefix's processes, quoted in every "still running" error.
    public static let stopCommand = "ossover bottle stop"

    public struct ShutdownReport: Sendable, Equatable {
        /// Whether `wineserver -k` found a server to talk to (exit 0).
        public var serverWasRunning: Bool
        /// Whether `-w` returned before the cap.
        public var waitedCleanly: Bool
        /// Pids that were still alive after the server went and got SIGTERM.
        public var terminated: [pid_t]
        /// Of those, the ones that needed SIGKILL.
        public var forceKilled: [pid_t]

        public init(serverWasRunning: Bool, waitedCleanly: Bool, terminated: [pid_t], forceKilled: [pid_t]) {
            self.serverWasRunning = serverWasRunning
            self.waitedCleanly = waitedCleanly
            self.terminated = terminated
            self.forceKilled = forceKilled
        }

        public var summary: String {
            var out = serverWasRunning ? "wineserver stopped" : "no wineserver was running"
            if !waitedCleanly { out += " (wait hit the \(Int(shutdownWait)) s cap)" }
            if !terminated.isEmpty { out += ", ended \(terminated.count) leftover process(es)" }
            if !forceKilled.isEmpty { out += " (\(forceKilled.count) by SIGKILL)" }
            return out
        }
    }

    /// The environment `wineserver` needs: the bottle's own (so `WINEPREFIX` and the sync mode
    /// agree). `gptkPack` as in `WineEnvironment.make`: the server is a process of the bottle too.
    public static func environment(engine: Engine, bottle: Bottle, layout: BottleLayout, gptkPack: URL? = nil) -> [String: String] {
        WineEnvironment.make(engine: engine, bottle: bottle, layout: layout, program: nil, renderer: .wined3d, gptkPack: gptkPack)
    }

    /// The full sequence. Never throws for a server that is already gone; throws only when the
    /// wineserver binary cannot be started or the process table cannot be read. Ends the server
    /// lifetime, so the sync-state record goes with it.
    @discardableResult
    public static func shutdown(engine: Engine, bottle: Bottle, layout: BottleLayout, gptkPack: URL? = nil,
                                wait: TimeInterval = shutdownWait, grace: TimeInterval = killGrace) async throws -> ShutdownReport {
        let env = environment(engine: engine, bottle: bottle, layout: layout, gptkPack: gptkPack)
        let cwd = layout.root
        let kill = try await Shell.run(executable: engine.wineserver.path, args: ["-k"], env: env, cwd: cwd, timeout: wait)
        var waitedCleanly = true
        do {
            _ = try await Shell.run(executable: engine.wineserver.path, args: ["-w"], env: env, cwd: cwd, timeout: wait)
        } catch OssoverError.timeout {
            waitedCleanly = false
        }
        let leftovers = try await liveProcesses(layout: layout, engineRoot: engine.root).map(\.pid)
        let hard = ProcessTable.terminate(leftovers, grace: grace)
        clearSyncState(layout: layout)
        return ShutdownReport(serverWasRunning: kill.succeeded, waitedCleanly: waitedCleanly, terminated: leftovers, forceKilled: hard)
    }

    /// `wineserver -w`: blocks until the prefix's server exits (a boot or an installer's helpers
    /// finishing), at most `timeout` (`bootWait` by default). On expiry throws `.timeout` whose
    /// text names the bottle and lists what is still alive in its prefix (pid + command) with the
    /// `ossover bottle stop` hint: a server that outlives a boot is being kept alive by a client,
    /// and a wait with no diagnostic is indistinguishable from a hang.
    public static func waitForExit(engine: Engine, bottle: Bottle, layout: BottleLayout, gptkPack: URL? = nil,
                                   timeout: TimeInterval = bootWait) async throws {
        let env = environment(engine: engine, bottle: bottle, layout: layout, gptkPack: gptkPack)
        do {
            _ = try await Shell.run(executable: engine.wineserver.path, args: ["-w"], env: env, cwd: layout.root, timeout: timeout)
        } catch OssoverError.timeout {
            let live = (try? await liveProcesses(layout: layout, engineRoot: engine.root)) ?? []
            throw OssoverError.timeout(command: "wineserver -w (bottle \(bottle.name)): " + busyClause(bottle: bottle.name, live: live),
                                       seconds: timeout)
        }
    }

    /// Pids of everything running in the prefix right now (`liveProcesses`).
    public static func processes(layout: BottleLayout) async throws -> [pid_t] {
        try await liveProcesses(layout: layout).map(\.pid)
    }

    /// Whether anything runs in the prefix.
    public static func isRunning(layout: BottleLayout) async throws -> Bool {
        !(try await processes(layout: layout)).isEmpty
    }

    /// Everything alive in the prefix right now as `ps` shows it (pid + command line):
    /// `members(of:layout:engineRoot:)` over the live table.
    public static func liveProcesses(layout: BottleLayout, engineRoot: URL? = nil) async throws -> [ProcessEntry] {
        members(of: try await ProcessTable.list(), layout: layout, engineRoot: engineRoot)
    }

    /// The prefix's processes among `entries`, in table order: the `WINEPREFIX` exact match of
    /// `ProcessTable.filter(_:winePrefix:engineRoot:)` (the server, the loaders, anything from
    /// `engineRoot`), plus `isRewrittenMember`. Pure.
    public static func members(of entries: [ProcessEntry], layout: BottleLayout, engineRoot: URL? = nil) -> [ProcessEntry] {
        let byEnvironment = Set(ProcessTable.filter(entries, winePrefix: layout.prefix, engineRoot: engineRoot))
        return entries.filter { byEnvironment.contains($0) || isRewrittenMember($0, prefix: layout.prefix) }
    }

    /// Whether `entry` is a process of `prefix` by the one mark Wine leaves on macOS once it has
    /// rewritten a PE process's command line: argv[0] is the Unix path of an exe inside the
    /// prefix (`<prefix>/drive_c/…/notepad.exe`). Wine's `set_process_name` overwrites the
    /// exec-args area that `ps -E` and `KERN_PROCARGS2` read, so a running program shows no
    /// `WINEPREFIX` at all — only wineserver and the loaders keep theirs — and the `WINEPREFIX`
    /// match alone would list the server a stale program keeps alive but not the program.
    /// System processes rewritten to `C:\windows\…` carry no prefix path and stay invisible
    /// (`wineserver -k` ends those). Pure.
    public static func isRewrittenMember(_ entry: ProcessEntry, prefix: URL) -> Bool {
        ProcessTable.pathForms(prefix).contains { form in
            let command = entry.commandWithoutEnvironment
            return command.hasPrefix(form + "/") && command.count > form.count + 1
        }
    }

    /// `pid 4242 /…/wineloader64 C:\…\notepad.exe; pid 4243 /…/wineserver`: the entries by pid,
    /// environment words stripped. Pure.
    public static func describe(_ entries: [ProcessEntry]) -> String {
        entries.sorted { $0.pid < $1.pid }.map { "pid \($0.pid) \($0.commandWithoutEnvironment)" }.joined(separator: "; ")
    }

    /// The clause every busy-prefix error ends with — what is alive and how to end it — for a
    /// caller that has already named the bottle. An empty `live` (a process that exited just
    /// after a cap, or a table that could not be read) still points at the stop command, which
    /// also clears the sync-state record. Pure.
    public static func busyClause(bottle name: String, live: [ProcessEntry]) -> String {
        guard !live.isEmpty else {
            return "no process of its prefix is visible now (one may have exited just after the cap); `\(stopCommand) \(name)` resets it"
        }
        return "\(live.count) Wine process(es) still run in its prefix: \(describe(live)). Stop them first: \(stopCommand) \(name)"
    }

    // MARK: Sync state (decision 19)

    /// `bottles/<name>/.sync-state.json`: the sync mode, and the `WINEMSYNC` value, the prefix's
    /// current wineserver lifetime was started with. Written by `WineRunner` when it starts a
    /// process, removed by `shutdown`; a server that exited on its own leaves a stale record,
    /// which is why the live server's environment is consulted first and the record only when
    /// that cannot be read.
    public struct SyncState: Codable, Equatable, Sendable, SchemaDocument {
        public static let currentSchema = "ossover.sync-state/1"

        public var schema: String
        /// The effective mode (`WineEnvironment.effectiveSync`).
        public var sync: SyncMode
        /// The `WINEMSYNC` value handed to the processes ("1" or "0").
        public var winemsync: String
        public var engineID: String
        public var startedAt: Date

        public init(sync: SyncMode, winemsync: String, engineID: String, startedAt: Date = Date()) {
            self.schema = Self.currentSchema
            self.sync = sync
            self.winemsync = winemsync
            self.engineID = engineID
            self.startedAt = startedAt.secondPrecision
        }

        enum CodingKeys: String, CodingKey {
            case schema, sync, winemsync
            case engineID = "engineId"
            case startedAt
        }

        /// Same mode, value and engine; `startedAt` ignored.
        public func sameLifetime(as other: SyncState) -> Bool {
            sync == other.sync && winemsync == other.winemsync && engineID == other.engineID
        }
    }

    public static let syncStateFileName = ".sync-state.json"

    public static func syncStateURL(layout: BottleLayout) -> URL { layout.root.appending(path: syncStateFileName) }

    /// The record, nil when absent or unreadable.
    public static func syncState(layout: BottleLayout) -> SyncState? {
        try? JSONDocument.loadDocument(SyncState.self, from: syncStateURL(layout: layout))
    }

    /// Writes the record unless an equal one (`sameLifetime`) is already there.
    public static func recordSyncState(_ state: SyncState, layout: BottleLayout) throws {
        if let existing = syncState(layout: layout), existing.sameLifetime(as: state) { return }
        try JSONDocument.save(state, to: syncStateURL(layout: layout))
    }

    public static func clearSyncState(layout: BottleLayout) {
        try? FileManager.default.removeItem(at: syncStateURL(layout: layout))
    }

    /// A prefix's running `wineserver` as the check sees it.
    public struct LiveServer: Sendable, Equatable {
        public var pid: pid_t
        /// Its environment, nil when it could not be read (`ProcessTable.commandLineAndEnvironment`
        /// refuses a process that is not ours or is already gone).
        public var environment: [String: String]?

        public init(pid: pid_t, environment: [String: String]?) {
            self.pid = pid
            self.environment = environment
        }
    }

    /// What `checkSync` found.
    public enum SyncCheck: Sendable, Equatable {
        /// No wineserver runs for the prefix; the launch starts one with its own value.
        case noServer
        /// The live server has the same `WINEMSYNC` (on/off) as the launch.
        case matches(pid: pid_t)
        /// The live server was started with another value (`server` is its raw `WINEMSYNC`, nil =
        /// unset); every client of it must match, so the launch is refused unless the server is restarted.
        case mismatch(pid: pid_t, server: String?, wanted: String)
        /// A server runs, its environment could not be read and no record exists: nothing to compare.
        case unknown(pid: pid_t)
        /// A mismatched server was stopped (`restartServer`); `previous` is the value it ran with.
        case restarted(pid: pid_t, previous: String?, report: ShutdownReport)

        public var summary: String {
            switch self {
            case .noServer: return "no wineserver is running; the next launch starts one"
            case let .matches(pid): return "wineserver (pid \(pid)) already runs with the same WINEMSYNC"
            case let .mismatch(pid, server, wanted):
                return "wineserver (pid \(pid)) runs with WINEMSYNC=\(server ?? "unset") but the launch needs WINEMSYNC=\(wanted)"
            case let .unknown(pid): return "wineserver (pid \(pid)) is running but its WINEMSYNC could not be read"
            case let .restarted(pid, previous, report):
                return "wineserver (pid \(pid), WINEMSYNC=\(previous ?? "unset")) restarted for the new sync mode: \(report.summary)"
            }
        }
    }

    /// Whether the entry's executable is a `wineserver` (bare or by path). Pure.
    public static func isWineserver(_ entry: ProcessEntry) -> Bool {
        guard let first = entry.commandWithoutEnvironment.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return false
        }
        let executable = String(first)
        return executable == "wineserver" || executable.hasSuffix("/wineserver")
    }

    /// The prefix's wineserver entries among `entries` (`ProcessTable.filter(_:winePrefix:engineRoot:)`
    /// membership, then the executable name). Pure.
    public static func serverEntries(_ entries: [ProcessEntry], layout: BottleLayout, engineRoot: URL? = nil) -> [ProcessEntry] {
        ProcessTable.filter(entries, winePrefix: layout.prefix, engineRoot: engineRoot).filter(isWineserver)
    }

    /// `WINEMSYNC` as ntdll and wineserver read it (REA L-30): `getenv && atoi(...) != 0`, so unset,
    /// empty, `0` and non-numeric text are all off, and `1`, `2`, `1abc` are on. Pure.
    public static func msyncEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        var rest = Substring(value).drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if let first = rest.first, first == "-" || first == "+" { rest = rest.dropFirst() }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        return (Int(digits) ?? 0) != 0
    }

    /// Compares the launch's `wanted` value with the live server's: its environment when readable,
    /// else the `recorded` state, else `.unknown`. Pure.
    public static func compareSync(wanted: String, server: LiveServer?, recorded: SyncState?) -> SyncCheck {
        guard let server else { return .noServer }
        if let environment = server.environment {
            let value = environment[WineEnvironment.msyncKey]
            return msyncEnabled(value) == msyncEnabled(wanted) ? .matches(pid: server.pid)
                : .mismatch(pid: server.pid, server: value, wanted: wanted)
        }
        if let recorded {
            return msyncEnabled(recorded.winemsync) == msyncEnabled(wanted) ? .matches(pid: server.pid)
                : .mismatch(pid: server.pid, server: recorded.winemsync, wanted: wanted)
        }
        return .unknown(pid: server.pid)
    }

    /// The live check: the process table, the first wineserver of the prefix, its environment from
    /// `KERN_PROCARGS2` (falling back to the `ps -E` text), then `compareSync`.
    public static func checkSync(wanted: String, layout: BottleLayout, engineRoot: URL? = nil) async throws -> SyncCheck {
        let servers = serverEntries(try await ProcessTable.list(), layout: layout, engineRoot: engineRoot)
        guard let entry = servers.first else { return .noServer }
        var environment = ProcessTable.commandLineAndEnvironment(of: entry.pid)?.environment
        if environment == nil, let value = ProcessTable.environmentValues(of: entry, key: WineEnvironment.msyncKey).last {
            environment = [WineEnvironment.msyncKey: value]
        }
        return compareSync(wanted: wanted, server: LiveServer(pid: entry.pid, environment: environment), recorded: syncState(layout: layout))
    }
}
