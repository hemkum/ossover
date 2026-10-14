// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

extension BottleCommand {
    /// `ossover bottle stop <name>`: the plan's shutdown (`wineserver -k` → `-w` → SIGTERM/SIGKILL
    /// for what is left, `WineServer.shutdown`), as the hint every "still running" error names.
    /// A program from an earlier launch that keeps the bottle's wineserver alive is what blocks a
    /// prefix re-init and what a boot's `wineserver -w` would otherwise wait on.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a bottle: wineserver -k, wineserver -w, then signals for whatever of its prefix is left.",
            discussion: "Lists the bottle's live Wine processes (pid and command) first. Without an installed engine there is no "
                + "wineserver to ask, so the processes get SIGTERM, then SIGKILL. Clears the bottle's sync-state record either way.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Bottle name.") var name: String
        @Flag(help: "List the bottle's Wine processes and exit without stopping anything.") var list = false

        func run() async throws {
            let store = BottleStore(paths: global.paths)
            let bottle = try store.load(name)
            let layout = store.layout(name)
            let session = try? BottleSession.open(name, paths: global.paths)
            let live = try await WineServer.liveProcesses(layout: layout, engineRoot: session?.engine.root)
            if live.isEmpty {
                Console.note("no Wine process of bottle \(name) is running")
            } else {
                Console.note("bottle \(name): \(live.count) Wine process(es): \(WineServer.describe(live))")
            }
            if list { return }
            if let session {
                let report = try await session.runner.shutdown()
                print(report.summary)
            } else {
                // The engine is gone (or not installed): nothing can run `wineserver -k`, so the
                // process table is the only handle, as in `bottle delete --force`.
                let killed = ProcessTable.terminate(live.map(\.pid))
                WineServer.clearSyncState(layout: layout)
                Console.note("engine \(bottle.engineID) is not installed; signals only")
                print(live.isEmpty ? "nothing to stop" : "stopped \(live.count) process(es)" + (killed.isEmpty ? "" : ", \(killed.count) with SIGKILL"))
            }
        }
    }
}
