// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/highball/main.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (run: pin name | Windows path | Unix path, arguments after --)

import ArgumentParser
import Foundation
import OssoverKit

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a program in a bottle: a program id from bottle.json, a C:\\ path or a Unix path to an exe.",
        discussion: """
            The renderer overlay is placed first (strategy B copies DXMT's DLLs into system32, C only sets \
            WINEDLLPATH_PREPEND), then wine starts with the parent attached. The wine log streams to stdout \
            until the program exits and the exit code is printed. Put the program's own arguments after `--`.
            """)

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Bottle name.") var bottle: String
    @Argument(help: "Program id, C:\\... path, Unix path, or a path under drive_c.") var program: String
    @Argument(parsing: .postTerminator, help: "Arguments for the program (after --).") var arguments: [String] = []
    @Option(help: "Renderer for this launch instead of the bottle's setting.") var renderer: RendererChoice?
    @Option(name: .customLong("env"), help: "Extra KEY=VALUE for this launch (repeatable).") var env: [EnvAssignment] = []
    @Flag(name: .customLong("print-env"), help: "Print the launch environment and exit without running.") var printEnv = false
    @Flag(help: "Do not echo the wine log to stdout (it is still written under logs/).") var quiet = false
    @Flag(help: "Stop the bottle's wineserver after the program exits.") var shutdown = false
    @Flag(name: .customLong("restart-server"),
          help: """
              Stop the bottle's running wineserver (wineserver -k, -w) instead of refusing: when it was started with another \
              sync mode, or when the prefix must be re-initialised for a changed engine while programs of an earlier launch \
              still run in it.
              """)
    var restartServer = false
    @Option(name: .customLong("boot-wait"),
            help: "Seconds a prefix boot's wineserver -w may block before failing with the bottle's live processes listed.")
    var bootWait: Double = WineServer.bootWait

    func validate() throws {
        guard bootWait > 0 else { throw ValidationError("--boot-wait must be a positive number of seconds") }
    }

    func run() async throws {
        let session = try BottleSession.open(bottle, paths: global.paths)
        let target = try session.program(program, arguments: arguments)
        let selection = try session.resolveRenderer(override: renderer)
        let extra = EnvAssignment.dictionary(env)
        if printEnv {
            for line in WineEnvironment.lines(session.runner.environment(program: target, renderer: selection, extra: extra)) {
                print(line)
            }
            return
        }
        // A wineserver already running for the bottle is reused, not rebooted under: the init
        // steps run only when the stamp or system.reg say so, and never while the prefix has live
        // processes unless --restart-server (BottleStore.initializationDecision). The launch
        // below still refuses a server whose WINEMSYNC differs (WineRunner.checkServerSync).
        // When the steps do run, their `wineserver -w` is capped at --boot-wait and names what
        // keeps the server alive on expiry (WineServer.waitForExit) instead of hanging.
        let prefix = try await BottleStore(paths: global.paths).ensureInitialized(session.bottle, engine: session.engine,
                                                                                  stopLiveProcesses: restartServer, bootWait: bootWait,
                                                                                  log: Console.logger)
        for note in prefix.report?.notes ?? [] { Console.warn(note) }
        if !prefix.ran, let server = prefix.runningWineserver {
            Console.note("wineserver (pid \(server.pid)) already runs for bottle \(bottle); reusing it")
        }
        session.warnAboutSync()
        _ = try session.materialize(selection)
        Console.note("renderer: \(selection.summary)")

        let onOutput: (@Sendable (Data) -> Void)? = quiet ? nil : { @Sendable data in Console.stream(data) }
        let running = try await session.runner.launch(program: target, renderer: selection, extra: extra,
                                                      restartServer: restartServer, onOutput: onOutput)
        Console.note("started \(target.id) as pid \(running.pid); log \(running.logURL.path)")
        let interrupt = InterruptGuard { running.terminate() }
        let status = await running.wait()
        interrupt.cancel()
        if shutdown {
            let report = try await session.runner.shutdown()
            Console.note(report.summary)
        }
        if interrupt.wasInterrupted {
            Console.note("interrupted; \(target.id) was sent SIGTERM")
            throw failure()
        }
        print("exit code \(status)")
        guard status == 0 else { throw failure() }
    }
}
