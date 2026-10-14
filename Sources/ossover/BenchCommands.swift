// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark with the Metal HUD log: per-run avg fps and 1% low, median over runs.",
        subcommands: [Run.self, Attach.self])

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch a program, load the benchmark save, measure, repeat; writes results/<ts>/ under the bottle.",
            discussion: """
                Needs Accessibility access to press the load key, or --manual-load for a countdown in which you load the save \
                yourself. Exit 1 when the profile's target is not met. --renderer and --sync run the benchmark matrix \
                (dxmt vs dxvk vs sync variants) from one bottle without re-applying recipes; result.json records the engine, \
                its wine --version, the renderer (kind, pack, strategy) and the effective sync of every session.
                """)

        @OptionGroup var global: GlobalOptions
        @Option(help: "Bottle name.") var bottle: String
        @Option(help: "Program id from bottle.json.") var program: String
        @Option(help: "Renderer for this benchmark instead of the bottle's setting: dxmt, dxvk, d3dmetal (or wined3d as a baseline).")
        var renderer: RendererChoice?
        @Option(help: "Sync mode for this benchmark instead of the bottle's setting: msync, esync, none (downgraded to what the engine has).")
        var sync: SyncMode?
        @Option(help: "Profile name (novigrad) or a path to a BenchProfile JSON.") var profile: String = "novigrad"
        @Option(help: "Runs (overrides the profile).") var runs: Int?
        @Flag(name: .customLong("manual-load"), help: "No key injection; a countdown lets you load the save.") var manualLoad = false
        @Option(name: .customLong("measure"), help: "Measured seconds per run (overrides the profile).") var measureS: Double?
        @Option(name: .customLong("load-wait"), help: "Seconds to wait for the save to load (overrides the profile).") var loadWaitS: Double?
        @Option(name: .customLong("warmup"), help: "Warm-up seconds before measuring (overrides the profile).") var warmupS: Double?
        @Flag(name: .customLong("hud-visible"),
              help: "Draw the Metal HUD overlay during the runs (MTL_HUD_HIDDEN unset). Its log then carries every frame twice; the harness halves the pairs.")
        var hudVisible = false
        @Flag(help: "Print the result as JSON.") var json = false

        func run() async throws {
            var profile = try BenchProfiles.load(self.profile)
            if let runs { profile.runs = runs }
            if manualLoad { profile.manualLoad = true }
            if let measureS { profile.measureS = measureS }
            if let loadWaitS { profile.loadWaitS = loadWaitS }
            if let warmupS { profile.warmupS = warmupS }
            try profile.validate()

            let session = try BottleSession.open(bottle, paths: global.paths)
            let program = try Programs.require(self.program, in: session.bottle)
            // The matrix overrides live on a copy of the bottle for this session only: the
            // launches, the results' bottle.json and the wineserver shutdown all see the same
            // settings, and bottle.json on disk is untouched.
            var overridden = session.bottle
            if let renderer { overridden.settings.renderer = renderer }
            if let sync { overridden.settings.sync = sync }
            let bottle = overridden
            let selection = try session.resolveRenderer(override: renderer)
            try await session.ensurePrefix()
            if renderer != nil || sync != nil {
                // One WINEMSYNC per prefix lifetime (decision 19) and no stale overlay: a
                // wineserver left from an earlier launch would not carry this run's settings.
                let shutdown = try await session.runner.shutdown()
                Console.note("override: \(shutdown.summary)")
            }
            let effectiveSync = WineEnvironment.effectiveSync(bottle.settings.sync, capabilities: session.engine.capabilities)
            if effectiveSync != bottle.settings.sync {
                Console.warn("asked for \(bottle.settings.sync.rawValue) but engine \(session.engine.id) lacks it; launches use \(effectiveSync.rawValue)")
            }
            _ = try session.materialize(selection)
            Console.note("renderer: \(selection.summary); sync: \(effectiveSync.rawValue)")
            let launcher = WineProgramLauncher(engine: session.engine, bottle: bottle, renderer: selection)
            let launch = BenchLaunchInfo(engine: session.engine, bottle: bottle, renderer: selection,
                                         wineVersionString: await Self.wineVersionString(session))
            let harness = BenchHarness(paths: global.paths, launcher: launcher, launch: launch, hudVisible: hudVisible, progress: Console.logger)
            let preconditions = try profile.preconditions.map { try BenchPaths.resolve($0, session: session) }
            let artifacts = BenchPaths.artifacts(settingsFile: preconditions?.settingsFile, logs: session.layout.logs)
            let resolvedProfile = profile
            let result = try await withInterruptCancellation {
                try await harness.bench(bottle: bottle, program: program, profile: resolvedProfile, preconditions: preconditions, artifacts: artifacts)
            }
            if json {
                try Console.json(result)
            } else {
                BenchOutput.print(result)
            }
            guard result.runs.contains(where: \.ok) else {
                Console.error("no run produced HUD frames")
                throw failure()
            }
            if let met = result.meetsTarget, !met { throw failure() }
        }

        /// What the engine's `wine --version` prints (`wine-11.0-8726-g2e2f5fca349`), nil when
        /// it cannot run; the manifest's `wineVersion` is recorded beside it either way.
        static func wineVersionString(_ session: BottleSession) async -> String? {
            guard let result = try? await session.runner.runTool(["--version"], timeout: 120), result.status == 0 else { return nil }
            let line = result.stdout.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return line.isEmpty ? nil : line
        }
    }

    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure an already running process (a CrossOver launch with MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1 via launchctl setenv).",
            discussion: """
                The unified log redacts the HUD's frame list, so without --log only the frame-counter rate is measured (no 1% low). \
                Give --log the file the process's stderr goes to (an ossover wine log, or a file you redirected it to) for the full \
                per-frame lines; it is read from its current end.
                """)

        @OptionGroup var global: GlobalOptions
        @Option(help: "Process id to watch.") var pid: Int32
        @Option(help: "Measured seconds.") var seconds: Double = 60
        @Option(help: "Label recorded in result.json (e.g. crossover-26.3).") var label: String?
        @Option(name: .customLong("log"), help: "The process's stderr log to tail for the full HUD lines.") var log: String?
        @Flag(name: .customLong("hud-visible"), help: "The process draws the HUD overlay: halve the duplicated pairs in --log.") var hudVisible = false
        @Flag(help: "Print the result as JSON.") var json = false

        func run() async throws {
            let harness = BenchHarness(paths: global.paths, launcher: NoLauncher(), hudVisible: hudVisible, progress: Console.logger)
            let logFile = log.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            let result = try await harness.attach(pid: pid, measureS: seconds, label: label, logFile: logFile)
            if json {
                try Console.json(result)
            } else {
                BenchOutput.print(result)
            }
            guard result.runs.contains(where: \.ok) else {
                Console.error("no HUD frames from pid \(pid) (are MTL_HUD_ENABLED=1 and MTL_HUD_LOG_ENABLED=1 in its environment?)")
                throw failure()
            }
        }
    }
}

enum BenchProfiles {
    static func load(_ reference: String) throws -> BenchProfile {
        if reference.lowercased() == BenchProfile.novigrad.name { return .novigrad }
        if Catalog.isFile(reference) { return try JSONDocument.load(BenchProfile.self, from: Catalog.fileURL(reference)) }
        throw ValidationError("unknown bench profile '\(reference)' (novigrad, or a path to a profile JSON)")
    }
}

/// Resolves a profile's Windows paths against the bottle and names the per-run artifacts.
enum BenchPaths {
    /// DXMT/DXVK log names (`<exe>_d3d11.log` beside the wine logs, `DXMT_LOG_PATH`/`DXVK_LOG_PATH`).
    static let rendererLogSuffixes = ["_d3d11.log", "_dxgi.log", "_d3d10core.log", "_d3d9.log", "_winemetal.log"]

    static func resolve(_ preconditions: BenchPreconditions, session: BottleSession) throws -> ResolvedBenchPreconditions {
        let userName = Prefix.userName(layout: session.layout, engine: session.engine)
        let variables = WindowsPath.standardVariables(userName: userName, engineRoot: session.engine.root)
        func unix(_ windows: String, what: String) throws -> URL {
            let expanded = WindowsPath.expand(windows, variables: variables)
            guard WindowsPath.unresolvedVariables(in: expanded).isEmpty, let url = WindowsPath.toUnix(expanded, prefix: session.layout.prefix) else {
                throw OssoverError.invalid("bench profile \(what) '\(windows)' is not a Windows path inside the prefix")
            }
            return url
        }
        var out = ResolvedBenchPreconditions(saveExtension: preconditions.saveExtension, requiredSettings: preconditions.requiredSettings)
        out.savesDirectory = try preconditions.savesDirectory.map { try unix($0, what: "savesDirectory") }
        out.settingsFile = try preconditions.settingsFile.map { try unix($0, what: "settingsFile") }
        if let save = preconditions.benchmarkSave {
            out.benchmarkSave = save.hasPrefix("/") ? URL(fileURLWithPath: save) : (try RepoRoot.require()).appending(path: save)
        }
        return out
    }

    /// The settings file plus every renderer log in the bottle's `logs/`, read after each run.
    static func artifacts(settingsFile: URL?, logs: URL) -> @Sendable () -> [URL] {
        { @Sendable in
            var files: [URL] = []
            if let settingsFile, FileManager.default.fileExists(atPath: settingsFile.path) { files.append(settingsFile) }
            let entries = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            files += entries.filter { url in rendererLogSuffixes.contains { url.lastPathComponent.lowercased().hasSuffix($0) } }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return files
        }
    }
}

/// `bench attach` watches an externally launched process; it never launches one.
struct NoLauncher: ProgramLauncher {
    func launch(_ request: LaunchRequest) async throws -> any LaunchedProcess {
        throw OssoverError.unsupported("bench attach does not launch programs")
    }

    func shutdown(_ layout: BottleLayout) async throws {}
}

enum BenchOutput {
    static func print(_ result: BenchResult) {
        var renderer = Format.optional(result.renderer ?? result.rendererID)
        if let pack = result.rendererID {
            renderer += " (pack \(pack)" + (result.rendererVersion.map { " \($0)" } ?? "") + (result.rendererStrategy.map { ", strategy \($0)" } ?? "") + ")"
        }
        if let choice = result.rendererChoice, choice != result.renderer { renderer += " [asked: \(choice)]" }
        let wine = result.wineVersionString ?? result.wineVersion
        var header: [(String, String)] = [
            ("kind", result.kind.rawValue),
            ("target", Format.optional(result.bottle.map { "\($0)/\(result.program ?? "?")" } ?? result.label)),
            ("engine", Format.optional(result.engineID) + (wine.map { " (\($0))" } ?? "")),
            ("renderer", renderer),
            ("sync", Format.optional(result.sync)),
            ("profile", result.profile.map { "\($0.name): load \(Int($0.loadWaitS)) s, warm-up \(Int($0.warmupS)) s, measure \(Int($0.measureS)) s × \($0.runs)" } ?? "-"),
            ("system", result.sysInfo.summary),
            ("thermal", "before: \(firstLine(result.thermalBefore))" + (result.thermalAfter.map { "; after: \(firstLine($0))" } ?? "")),
            ("results", result.resultsDirectory.path),
        ]
        if let median = result.median { header.append(("median", median.summary)) }
        if let counter = result.medianCounter { header.append(("median counter", counter.summary)) }
        if let source = result.runs.compactMap(\.hudSource).first {
            header.append(("hud source", source == .wineLog ? "wine log (full per-frame lines)" : "unified log (header fields only: no intervals, no 1% low)"))
        }
        if let target = result.profile?.target {
            let met = result.meetsTarget.map { $0 ? "yes" : "no" } ?? "-"
            header.append(("meets target", "\(met) (avg ≥ \(Int(target.avgFPS)) fps, 1% low ≥ \(Int(target.p1LowFPS)) fps)"))
        }
        Console.pairs(header)
        Swift.print("")
        Console.table(["Run", "Frames", "Avg fps", "Counter fps", "1% low", "p50", "GPU ms", "Measured", "Wall", "Non-black", "Notes"], result.runs.map { run in
            [String(run.run), String(run.stats?.frames ?? run.counter?.frames ?? 0), Format.fps(run.stats?.avgFPS), Format.fps(run.counter?.fps),
             Format.fps(run.stats?.p1LowFPS), Format.fps(run.stats?.p50FPS), run.stats.map { String(format: "%.2f", $0.gpuTimeMeanMs) } ?? "-",
             Format.seconds(run.stats?.durationS), Format.seconds(run.counter?.wallS), Format.optional(run.screenshotNonBlack),
             run.notes.isEmpty ? "-" : run.notes.joined(separator: "; ")]
        })
    }

    static func firstLine(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.first ?? "-"
    }
}
