// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the benchmark harness asks a launcher to start: one program of a bottle, with the
/// bench's extra environment (`MTL_HUD_*`, `WINEDEBUG=-all`) merged on top of the bottle's and
/// the program's own, and the log written where the harness can copy it from.
public struct LaunchRequest: Sendable, Equatable {
    public var bottle: Bottle
    public var layout: BottleLayout
    public var program: Program
    /// Merged last (above the program's `env`).
    public var extraEnvironment: [String: String]
    /// Where the launcher should write the wine log; nil lets it choose (`logs/<ts>-<program>.log`).
    public var logFile: URL?

    public init(bottle: Bottle, layout: BottleLayout, program: Program, extraEnvironment: [String: String] = [:],
                logFile: URL? = nil) {
        self.bottle = bottle
        self.layout = layout
        self.program = program
        self.extraEnvironment = extraEnvironment
        self.logFile = logFile
    }
}

/// A started program as the harness sees it. `ShellProcess` already is one.
public protocol LaunchedProcess: AnyObject, Sendable {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// Nil while running.
    var exitStatus: Int32? { get }
    /// The wine log (combined stdout+stderr with the launch header).
    var logFile: URL { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func forceKill()
    /// Suspends until exit; returns the status.
    func wait() async -> Int32
}

extension ShellProcess: LaunchedProcess {}

/// Starts programs in bottles. The CLI's `WineProgramLauncher` (WineAdapters.swift) conforms on
/// top of `WineRunner`, with `shutdown` = `wineserver -k` → `wineserver -w` → signals (plan §4);
/// the harness is written against this protocol so it compiles and tests without Wine.
public protocol ProgramLauncher: Sendable {
    /// Starts `request.program` with the parent attached (plan §4 "direct" launch) and returns
    /// at once; the harness watches the pid, the windows and the HUD log from here.
    func launch(_ request: LaunchRequest) async throws -> any LaunchedProcess

    /// Ends every process of the bottle's prefix after a run. The default implementation
    /// SIGTERMs (then SIGKILLs) whatever has `WINEPREFIX=<prefix>` in its environment.
    func shutdown(_ layout: BottleLayout) async throws
}

extension ProgramLauncher {
    public func shutdown(_ layout: BottleLayout) async throws {
        let pids = try await ProcessTable.processes(ofPrefix: layout.prefix)
        guard !pids.isEmpty else { return }
        ProcessTable.terminate(pids, grace: 5)
    }
}
