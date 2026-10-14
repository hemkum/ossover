// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct SmokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke",
        abstract: "Launch a program and check that it opens a window, holds a frame rate for a few seconds and is not black.",
        discussion: "Writes results/<timestamp>/{hud.ndjson, wine.log, screenshot.png, result.json} under the bottle. Exit 1 on a failed verdict.")

    @OptionGroup var global: GlobalOptions
    @Option(help: "Bottle name.") var bottle: String
    @Option(help: "Program id from bottle.json.") var program: String
    @Option(help: "Seconds before the run is abandoned.") var timeout: Double = 180
    @Option(name: .customLong("window-timeout"), help: "Seconds to wait for a window.") var windowTimeout: Double = 60
    @Option(name: .customLong("min-fps"), help: "Frame rate the program must hold.") var minFPS: Double = 20
    @Option(help: "Consecutive seconds at --min-fps.") var sustain: Int = 5
    @Flag(name: .customLong("no-screenshot"), help: "Do not require a non-black screenshot (no Screen Recording access).") var noScreenshot = false
    @Flag(help: "Print the result as JSON.") var json = false

    func run() async throws {
        let session = try BottleSession.open(bottle, paths: global.paths)
        let program = try Programs.require(self.program, in: session.bottle)
        let selection = try session.resolveRenderer()
        try await session.ensurePrefix()
        session.warnAboutSync()
        _ = try session.materialize(selection)
        let launcher = WineProgramLauncher(engine: session.engine, bottle: session.bottle, renderer: selection)
        let harness = BenchHarness(paths: global.paths, launcher: launcher, rendererID: selection.pack?.id, progress: Console.logger)
        let criteria = SmokeCriteria(windowTimeoutS: windowTimeout, minFPS: minFPS, sustainS: sustain, requireScreenshot: !noScreenshot)
        let bottle = session.bottle
        let timeout = self.timeout
        let result = try await withInterruptCancellation {
            try await harness.smoke(bottle: bottle, program: program, timeout: timeout, criteria: criteria)
        }
        if json {
            try Console.json(result)
        } else {
            Console.pairs(Self.rows(result))
        }
        guard result.passed else { throw failure() }
    }

    static func rows(_ result: SmokeResult) -> [(String, String)] {
        [
            ("verdict", result.verdict.rawValue),
            ("program", "\(result.program) in \(result.bottle)" + (result.pid.map { " (pid \($0))" } ?? "")),
            ("renderer", result.rendererID ?? "wined3d"),
            ("window", result.windowSeen ? "seen after \(Format.seconds(result.windowSeenAfterS))" + (result.window.map { " — \($0.summary)" } ?? "") : "not seen"),
            ("sustained fps", Format.fps(result.sustainedFPS) + (result.sustainedStats.map { " (\($0.summary))" } ?? "")),
            ("screenshot", result.screenshotNonBlack.map { $0 ? "not black" : "black" } ?? "none"
                + (result.meanLuminance.map { String(format: " (luminance %.3f)", $0) } ?? "")),
            ("exit status", result.exitStatus.map(String.init) ?? "still running / ended by harness"),
            ("wine log", result.logURL?.path ?? "-"),
            ("hud log", result.hudLogURL?.path ?? "-"),
            ("screenshot file", result.screenshotURL?.path ?? "-"),
            ("result", result.hudLogURL.map { $0.deletingLastPathComponent().appending(path: BenchHarness.resultFileName).path } ?? "-"),
            ("reasons", result.reasons.isEmpty ? "-" : result.reasons.joined(separator: "; ")),
        ]
    }
}

enum Programs {
    static func require(_ id: String, in bottle: Bottle) throws -> Program {
        guard let program = bottle.program(id: id) else {
            throw OssoverError.missing("program '\(id)' in bottle \(bottle.name) (ids: \(Format.list(bottle.programs.map(\.id))); add one with a recipe)")
        }
        return program
    }
}
