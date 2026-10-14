// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Documents

/// What the unattended smoke test demands (plan §3: window, ≥5 s at ≥20 fps, non-black picture).
public struct SmokeCriteria: Sendable, Equatable, Codable {
    /// Seconds to wait for a window after launch.
    public var windowTimeoutS: Double
    /// Every line-to-line stretch of the HUD's frame counter over the trailing `sustainS` seconds
    /// must run at this rate or better.
    public var minFPS: Double
    public var sustainS: Int
    /// Mean luminance (0...1) at or below which a screenshot counts as black.
    public var blackThreshold: Double
    /// When false, a missing or impossible screenshot does not fail the verdict (no Screen
    /// Recording access on a CI box).
    public var requireScreenshot: Bool

    public init(windowTimeoutS: Double = 60, minFPS: Double = 20, sustainS: Int = 5,
                blackThreshold: Double = Screenshot.blackThreshold, requireScreenshot: Bool = true) {
        self.windowTimeoutS = windowTimeoutS
        self.minFPS = minFPS
        self.sustainS = sustainS
        self.blackThreshold = blackThreshold
        self.requireScreenshot = requireScreenshot
    }
}

public enum Verdict: String, Codable, Sendable {
    case pass, fail
}

/// Where a result's HUD samples came from. The wine log (the program's stderr) carries the
/// full per-frame lines; the unified log (`log stream`, `hud.ndjson`) only the header fields,
/// enough for the frame-counter rate but not for intervals or 1% lows.
public enum HUDSource: String, Codable, Sendable {
    case wineLog = "wine-log"
    case unifiedLog = "unified-log"
}

/// `results/<ts>/result.json` of `ossover smoke`.
public struct SmokeResult: Codable, Equatable, Sendable, SchemaDocument {
    public static let currentSchema = "ossover.smoke-result/1"

    public var schema: String
    public var bottle: String
    public var program: String
    public var engineID: String?
    public var rendererID: String?
    public var startedAt: Date
    public var timeoutS: Double
    public var criteria: SmokeCriteria
    public var launched: Bool
    public var pid: Int?
    public var exitStatus: Int32?
    public var windowSeen: Bool
    public var windowSeenAfterS: Double?
    public var window: WindowInfo?
    /// Frame rate of the first qualifying `sustainS` window, from the HUD's frame counter over
    /// wall time; nil when none was reached.
    public var sustainedFPS: Double?
    /// The interval statistics of that window (nil when only header fields were available).
    public var sustainedStats: MetalHUDStats?
    /// The frame-counter reading of that window.
    public var sustainedCounter: MetalHUDCounterStats?
    public var hudSource: HUDSource?
    /// The variables the harness added to the launch (the HUD rows, `WINEDEBUG=-all`).
    public var environment: [String: String]?
    /// Nil when no screenshot could be judged (no access, window gone, capture failed).
    public var screenshotNonBlack: Bool?
    public var meanLuminance: Double?
    public var screenshotURL: URL?
    public var logURL: URL?
    public var hudLogURL: URL?
    public var verdict: Verdict
    public var reasons: [String]

    public init(bottle: String, program: String, engineID: String?, rendererID: String?, startedAt: Date, timeoutS: Double,
                criteria: SmokeCriteria, environment: [String: String]? = nil) {
        self.schema = Self.currentSchema
        self.bottle = bottle
        self.program = program
        self.engineID = engineID
        self.rendererID = rendererID
        self.startedAt = startedAt.secondPrecision
        self.timeoutS = timeoutS
        self.criteria = criteria
        self.environment = environment
        self.launched = false
        self.windowSeen = false
        self.verdict = .fail
        self.reasons = []
    }

    enum CodingKeys: String, CodingKey {
        case schema, bottle, program
        case engineID = "engineId"
        case rendererID = "rendererId"
        case startedAt, timeoutS, criteria, launched, pid, exitStatus, windowSeen, windowSeenAfterS, window,
             sustainedFPS, sustainedStats, sustainedCounter, hudSource, environment, screenshotNonBlack, meanLuminance
        case screenshotURL = "screenshot"
        case logURL = "log"
        case hudLogURL = "hudLog"
        case verdict, reasons
    }

    /// Pure: the verdict from the observations. A missing screenshot fails only when required.
    public static func verdict(launched: Bool, windowSeen: Bool, sustainedFPS: Double?, screenshotNonBlack: Bool?,
                               requireScreenshot: Bool) -> Verdict {
        guard launched, windowSeen, sustainedFPS != nil else { return .fail }
        switch screenshotNonBlack {
        case .some(true): return .pass
        case .some(false): return .fail
        case .none: return requireScreenshot ? .fail : .pass
        }
    }

    public mutating func evaluate() {
        verdict = Self.verdict(launched: launched, windowSeen: windowSeen, sustainedFPS: sustainedFPS,
                               screenshotNonBlack: screenshotNonBlack, requireScreenshot: criteria.requireScreenshot)
    }

    public var passed: Bool { verdict == .pass }
}

/// The plan's pass line: ≥60 fps average and ≥30 fps 1%-low over the measured window.
public struct BenchTarget: Sendable, Equatable, Codable {
    public var avgFPS: Double
    public var p1LowFPS: Double

    public init(avgFPS: Double = 60, p1LowFPS: Double = 30) {
        self.avgFPS = avgFPS
        self.p1LowFPS = p1LowFPS
    }

    public static let witcher3 = BenchTarget()

    public func met(by stats: MetalHUDStats) -> Bool { stats.avgFPS >= avgFPS && stats.p1LowFPS >= p1LowFPS }
}

/// What must be true before a run (plan §4 "Benchmark harness" preconditions): the benchmark
/// save is the newest in the game's save directory (so "Continue" loads it) and the settings
/// file carries the profile's values. Windows paths with `%USERPROFILE%`; the CLI resolves them
/// against the bottle (`ResolvedBenchPreconditions`).
public struct BenchPreconditions: Sendable, Equatable, Codable {
    /// Windows path of the save directory (`%USERPROFILE%\Documents\The Witcher 3\gamesaves`).
    public var savesDirectory: String?
    /// Extension of the save files there (`sav`).
    public var saveExtension: String
    /// The benchmark save, relative to the repository checkout (`recipes/witcher3/bench/benchmark.sav`)
    /// or absolute. Copied into `savesDirectory` with a fresh mtime when the newest save there
    /// is not it.
    public var benchmarkSave: String?
    /// Windows path of the settings file (`%USERPROFILE%\Documents\The Witcher 3\user.settings`).
    public var settingsFile: String?
    /// `key` → the exact value `IniFile` must report for it (section-agnostic), e.g.
    /// `HairWorksLevel` → `0`, `Resolution` → `"2560x1600"` (quotes included).
    public var requiredSettings: [String: String]

    public init(savesDirectory: String? = nil, saveExtension: String = "sav", benchmarkSave: String? = nil,
                settingsFile: String? = nil, requiredSettings: [String: String] = [:]) {
        self.savesDirectory = savesDirectory
        self.saveExtension = saveExtension
        self.benchmarkSave = benchmarkSave
        self.settingsFile = settingsFile
        self.requiredSettings = requiredSettings
    }

    /// The Witcher 3 benchmark: HairWorks off, borderless 2560x1600 (plan §2 benchmark definition).
    public static let witcher3 = BenchPreconditions(
        savesDirectory: #"%USERPROFILE%\Documents\The Witcher 3\gamesaves"#,
        saveExtension: "sav",
        benchmarkSave: "recipes/witcher3/bench/benchmark.sav",
        settingsFile: #"%USERPROFILE%\Documents\The Witcher 3\user.settings"#,
        requiredSettings: ["HairWorksLevel": "0", "Resolution": "\"2560x1600\""])
}

/// `BenchPreconditions` with every path resolved to a Unix URL.
public struct ResolvedBenchPreconditions: Sendable, Equatable {
    public var savesDirectory: URL?
    public var saveExtension: String
    public var benchmarkSave: URL?
    public var settingsFile: URL?
    public var requiredSettings: [String: String]

    public init(savesDirectory: URL? = nil, saveExtension: String = "sav", benchmarkSave: URL? = nil,
                settingsFile: URL? = nil, requiredSettings: [String: String] = [:]) {
        self.savesDirectory = savesDirectory
        self.saveExtension = saveExtension
        self.benchmarkSave = benchmarkSave
        self.settingsFile = settingsFile
        self.requiredSettings = requiredSettings
    }
}

/// Timings of one benchmark: reach the main menu (smoke criteria), load the save, wait
/// `loadWaitS`, warm up `warmupS`, measure `measureS`; `runs` times; median.
public struct BenchProfile: Sendable, Equatable, Codable {
    public var name: String
    /// Seconds to wait after the load key for the save to load.
    public var loadWaitS: Double
    public var warmupS: Double
    public var measureS: Double
    public var runs: Int
    /// A person loads the save: the harness counts down `manualLoadCountdownS` instead of
    /// pressing `loadKey` (no Accessibility access needed).
    public var manualLoad: Bool
    public var manualLoadCountdownS: Double
    /// The key that loads the save from the main menu ("Continue" is Witcher 3's default item).
    public var loadKey: InputInjector.Key
    /// Seconds to reach the main menu (window + sustained fps) before a run is abandoned.
    public var menuTimeoutS: Double
    public var menu: SmokeCriteria
    /// Idle seconds between runs (thermals).
    public var cooldownS: Double
    public var target: BenchTarget?
    /// Checked before every run; nil checks nothing.
    public var preconditions: BenchPreconditions?

    public init(name: String = "novigrad", loadWaitS: Double = 45, warmupS: Double = 20, measureS: Double = 60, runs: Int = 3,
                manualLoad: Bool = false, manualLoadCountdownS: Double = 60, loadKey: InputInjector.Key = .return,
                menuTimeoutS: Double = 180, menu: SmokeCriteria = SmokeCriteria(requireScreenshot: false),
                cooldownS: Double = 15, target: BenchTarget? = .witcher3, preconditions: BenchPreconditions? = nil) {
        self.name = name
        self.loadWaitS = loadWaitS
        self.warmupS = warmupS
        self.measureS = measureS
        self.runs = runs
        self.manualLoad = manualLoad
        self.manualLoadCountdownS = manualLoadCountdownS
        self.loadKey = loadKey
        self.menuTimeoutS = menuTimeoutS
        self.menu = menu
        self.cooldownS = cooldownS
        self.target = target
        self.preconditions = preconditions
    }

    /// Hierarch Square, Novigrad: 45 s load, 20 s warm-up, 60 s measure, 3 runs, with the
    /// Witcher 3 save and settings preconditions.
    public static let novigrad = BenchProfile(preconditions: .witcher3)

    public func validate() throws {
        guard runs >= 1 else { throw OssoverError.invalid("bench profile \(name): runs must be ≥ 1") }
        guard measureS > 0 else { throw OssoverError.invalid("bench profile \(name): measureS must be > 0") }
        for (label, value) in [("loadWaitS", loadWaitS), ("warmupS", warmupS), ("cooldownS", cooldownS),
                               ("manualLoadCountdownS", manualLoadCountdownS), ("menuTimeoutS", menuTimeoutS)] where value < 0 {
            throw OssoverError.invalid("bench profile \(name): \(label) must be ≥ 0")
        }
    }
}

/// One run of a benchmark (or the single measurement of `attach`).
public struct BenchRunResult: Sendable, Equatable, Codable {
    public var run: Int
    public var startedAt: Date
    public var pid: Int?
    public var exitStatus: Int32?
    public var menuReachedAfterS: Double?
    public var measureStart: Date?
    public var measureEnd: Date?
    /// The interval statistics of the measured window (avg, 1% low, p50, GPU time). Nil when
    /// the window produced no `(interval, gpu)` pairs: the run failed, or only the unified log's
    /// header fields were available (`counter` alone then).
    public var stats: MetalHUDStats?
    /// The frame-counter rate over the same window: `stats.avgFPS`'s cross-check, and the only
    /// reading a header-only source gives.
    public var counter: MetalHUDCounterStats?
    public var hudSource: HUDSource?
    public var meetsTarget: Bool?
    public var screenshotNonBlack: Bool?
    public var meanLuminance: Double?
    public var hudLogURL: URL
    public var wineLogURL: URL?
    public var screenshotURL: URL?
    /// `pmset -g therm` at the end of the run.
    public var thermal: String?
    public var notes: [String]

    public init(run: Int, startedAt: Date, hudLogURL: URL) {
        self.run = run
        self.startedAt = startedAt.secondPrecision
        self.hudLogURL = hudLogURL
        self.notes = []
    }

    enum CodingKeys: String, CodingKey {
        case run, startedAt, pid, exitStatus, menuReachedAfterS, measureStart, measureEnd, stats, counter, hudSource, meetsTarget,
             screenshotNonBlack, meanLuminance
        case hudLogURL = "hudLog"
        case wineLogURL = "wineLog"
        case screenshotURL = "screenshot"
        case thermal, notes
    }

    /// The run measured something: frames with intervals, or at least the counter's rate.
    public var ok: Bool { (stats?.frames ?? 0) > 0 || (counter?.frames ?? 0) > 0 }

    /// Both readings as one.
    public var reading: MetalHUDReading { MetalHUDReading(stats: stats, counter: counter) }
}

public enum BenchKind: String, Codable, Sendable {
    /// `ossover bench run`: launched by us.
    case run
    /// `ossover bench attach`: an externally launched game (the CrossOver reference).
    case attach
}

/// `results/<ts>/result.json` of `ossover bench`.
public struct BenchResult: Sendable, Equatable, Codable, SchemaDocument {
    public static let currentSchema = "ossover.bench-result/1"

    public var schema: String
    public var kind: BenchKind
    public var createdAt: Date
    public var bottle: String?
    public var program: String?
    public var engineID: String?
    /// The engine manifest's Wine release ("11.16").
    public var wineVersion: String?
    /// What the engine's `wine --version` printed ("wine-11.0-8726-g2e2f5fca349"), when probed.
    public var wineVersionString: String?
    /// The renderer pack that served the runs (nil for wined3d).
    public var rendererID: String?
    /// The renderer kind that ran (`dxmt`, `dxvk`, `d3dmetal`, `wined3d`); before `record` the
    /// bottle's setting (`auto`, …).
    public var renderer: String?
    /// What was asked for: the bottle's setting or `bench run --renderer`.
    public var rendererChoice: String?
    public var rendererVersion: String?
    /// Overlay strategy letter: `B` (prefix copy), `C` (`WINEDLLPATH_PREPEND`), `-` (wined3d).
    public var rendererStrategy: String?
    /// The sync mode the engine really gave (`msync`, `esync`, `none`), after the engine's
    /// capabilities downgraded the bottle's (or `bench run --sync`'s) choice.
    public var sync: String?
    /// Free text for `attach` ("crossover-26.3 witcher3").
    public var label: String?
    public var profile: BenchProfile?
    public var sysInfo: SysInfo
    public var thermalBefore: String
    public var thermalAfter: String?
    /// The variables the harness added to every launch: the HUD rows (`MTL_HUD_ENABLED`,
    /// `MTL_HUD_LOG_ENABLED`, `MTL_HUD_HIDDEN` unless `--hud-visible`) and `WINEDEBUG=-all`.
    public var environment: [String: String]
    public var runs: [BenchRunResult]
    /// Component-wise median of the runs that produced frames with intervals.
    public var median: MetalHUDStats?
    /// Component-wise median of the runs' frame-counter readings.
    public var medianCounter: MetalHUDCounterStats?
    /// Whether the median meets `profile.target`; nil without a target or a median (a
    /// header-only source gives no 1% low to judge).
    public var meetsTarget: Bool?
    public var resultsDirectory: URL

    public init(kind: BenchKind, createdAt: Date, bottle: String?, program: String?, engineID: String?, rendererID: String?,
                renderer: String?, label: String?, profile: BenchProfile?, sysInfo: SysInfo, thermalBefore: String,
                environment: [String: String], resultsDirectory: URL) {
        self.schema = Self.currentSchema
        self.kind = kind
        self.createdAt = createdAt.secondPrecision
        self.bottle = bottle
        self.program = program
        self.engineID = engineID
        self.rendererID = rendererID
        self.renderer = renderer
        self.label = label
        self.profile = profile
        self.sysInfo = sysInfo
        self.thermalBefore = thermalBefore
        self.environment = environment
        self.runs = []
        self.resultsDirectory = resultsDirectory
    }

    enum CodingKeys: String, CodingKey {
        case schema, kind, createdAt, bottle, program
        case engineID = "engineId"
        case wineVersion, wineVersionString
        case rendererID = "rendererId"
        case renderer, rendererChoice, rendererVersion, rendererStrategy, sync, label, profile, sysInfo, thermalBefore, thermalAfter,
             environment, runs, median, medianCounter, meetsTarget, resultsDirectory
    }

    /// Fills the engine/renderer/sync rows from what the launches ran with (decision 35: the
    /// matrix is read back from `result.json` alone). Fields `launch` leaves nil keep their value.
    public mutating func record(_ launch: BenchLaunchInfo) {
        if let id = launch.engineID { engineID = id }
        wineVersion = launch.wineVersion ?? wineVersion
        wineVersionString = launch.wineVersionString ?? wineVersionString
        if let id = launch.rendererID { rendererID = id }
        if let kind = launch.rendererKind { renderer = kind.rawValue }
        rendererChoice = launch.rendererChoice?.rawValue ?? rendererChoice
        rendererVersion = launch.rendererVersion ?? rendererVersion
        rendererStrategy = launch.rendererStrategy?.letter ?? rendererStrategy
        sync = launch.sync?.rawValue ?? sync
    }

    /// Recomputes `median`, `medianCounter` and `meetsTarget` from `runs`.
    public mutating func summarise() {
        median = MetalHUDStats.median(of: runs.compactMap(\.stats))
        medianCounter = MetalHUDCounterStats.median(of: runs.compactMap(\.counter))
        if let median, let target = profile?.target {
            meetsTarget = target.met(by: median)
        } else {
            meetsTarget = nil
        }
    }

    public var passed: Bool { meetsTarget ?? false }
}

/// What the launches of one `bench`/`smoke` session run with, as `result.json` records them: the
/// engine and its Wine, the renderer that was resolved (kind, pack, version, strategy) and the
/// sync mode the engine really gives. Built from a `RendererSelection` by the CLI; tests build
/// it by hand.
public struct BenchLaunchInfo: Sendable, Equatable {
    public var engineID: String?
    public var wineVersion: String?
    public var wineVersionString: String?
    public var rendererChoice: RendererChoice?
    public var rendererKind: RendererKind?
    public var rendererID: String?
    public var rendererVersion: String?
    public var rendererStrategy: OverlayStrategy?
    public var sync: SyncMode?

    public init(engineID: String? = nil, wineVersion: String? = nil, wineVersionString: String? = nil,
                rendererChoice: RendererChoice? = nil, rendererKind: RendererKind? = nil, rendererID: String? = nil,
                rendererVersion: String? = nil, rendererStrategy: OverlayStrategy? = nil, sync: SyncMode? = nil) {
        self.engineID = engineID
        self.wineVersion = wineVersion
        self.wineVersionString = wineVersionString
        self.rendererChoice = rendererChoice
        self.rendererKind = rendererKind
        self.rendererID = rendererID
        self.rendererVersion = rendererVersion
        self.rendererStrategy = rendererStrategy
        self.sync = sync
    }

    /// From the engine, the bottle whose settings the launches use (its sync downgraded to what
    /// the engine has, as `WineEnvironment` does) and the resolved renderer. `wineVersionString`
    /// is what the caller saw `wine --version` print; the manifest's recorded string stands in.
    public init(engine: Engine, bottle: Bottle, renderer: RendererSelection, wineVersionString: String? = nil) {
        self.init(engineID: engine.id, wineVersion: engine.manifest.wineVersion,
                  wineVersionString: wineVersionString ?? engine.manifest.wineVersionString,
                  rendererChoice: renderer.choice, rendererKind: renderer.kind, rendererID: renderer.pack?.id,
                  rendererVersion: renderer.pack?.manifest.version, rendererStrategy: renderer.strategy,
                  sync: WineEnvironment.effectiveSync(bottle.settings.sync, capabilities: engine.capabilities))
    }
}

// MARK: - Harness

/// The benchmark harness (plan §4 "Benchmark harness"): `smoke`, `bench` and `attach`, built on
/// a `ProgramLauncher`, `HUDLogTail` + `LogStream` + `MetalHUDLog`, `WindowProbe`,
/// `Screenshot` and `InputInjector`. Results land in `bottles/<name>/results/<ts>/`.
///
/// Where the frames come from (probed on this Mac, DXMT bottle, macOS 26): the HUD writes its
/// full per-frame line to the process's stderr as NSLog text, i.e. into the bottle's wine log,
/// which the harness tails during the run (`HUDSource.wineLog`); the unified log (`log stream`,
/// `hud.ndjson`) carries the same lines with the frame list redacted to `<private>`, so it is
/// kept as the secondary, header-only source (`HUDSource.unifiedLog`, the only one `attach`
/// has without a log file). `MTL_HUD_ENABLED=1` is required: `MTL_HUD_LOG_ENABLED=1` alone logs
/// nothing. With the overlay drawn every frame is logged as two identical pairs, so the harness
/// hides it (`MTL_HUD_HIDDEN=1`) and, under `--hud-visible`, halves the pairs instead.
public struct BenchHarness: Sendable {
    /// Added to every smoke/bench launch, whatever the renderer: the HUD on (required for its
    /// log), its log on, the overlay hidden (one pair per frame), Wine's own chatter off
    /// (`WINEDEBUG=-all`, plan §4 env table). The HUD rows are read by Metal itself and, for
    /// D3DMetal, by D3DMetal too (`MTL_HUD_ENABLED` is a D3DMetal string), so they hold for dxmt,
    /// dxvk, d3dmetal and wined3d alike (REA L-58, decision 38).
    public static let benchEnvironment: [String: String] = benchEnvironment(hudVisible: false)

    /// `benchEnvironment` with the overlay drawn (`MTL_HUD_HIDDEN` left out) when `hudVisible`.
    public static func benchEnvironment(hudVisible: Bool) -> [String: String] {
        var env = [
            "MTL_HUD_ENABLED": "1",
            "MTL_HUD_LOG_ENABLED": "1",
            "WINEDEBUG": "-all",
        ]
        if !hudVisible { env["MTL_HUD_HIDDEN"] = "1" }
        return env
    }

    /// `avgFPS` (intervals) and the counter rate disagreeing by more than this fraction, or the
    /// pairs per counted frame straying this far from one, earns a note in the result.
    public static let crossCheckTolerance = 0.1
    public static let caffeinateExecutable = "/usr/bin/caffeinate"
    /// Display, idle, disk and system sleep all held off while a run lasts; `-w <pid>` ends the
    /// assertion when ossover itself goes (a Ctrl-C that skips the `defer` must not leave the
    /// Mac unable to sleep).
    public static func caffeinateArguments(waitingFor pid: pid_t) -> [String] { ["-dims", "-w", String(pid)] }
    public static let pmsetExecutable = "/usr/bin/pmset"
    public static let pmsetThermalArguments = ["-g", "therm"]
    public static let resultsDirectoryName = "results"
    public static let hudLogName = "hud.ndjson"
    public static let resultFileName = "result.json"
    public static let wineLogName = "wine.log"
    public static let screenshotName = "screenshot.png"

    public let paths: OssoverPaths
    public let launcher: any ProgramLauncher
    /// What the launches run with (engine, Wine, renderer, sync), recorded in every result.
    public let launch: BenchLaunchInfo
    /// Draw the HUD overlay (`MTL_HUD_HIDDEN` left out) and halve the duplicated pairs its log
    /// then carries. Off by default: hidden, one pair per frame.
    public let hudVisible: Bool
    /// Progress lines for a CLI ("window seen after 12.5 s").
    public let progress: (@Sendable (String) -> Void)?

    /// `launch` wins over `rendererID` when both are given; `rendererID` alone names only the pack.
    public init(paths: OssoverPaths, launcher: any ProgramLauncher, rendererID: String? = nil,
                launch: BenchLaunchInfo? = nil, hudVisible: Bool = false, progress: (@Sendable (String) -> Void)? = nil) {
        self.paths = paths
        self.launcher = launcher
        self.launch = launch ?? BenchLaunchInfo(rendererID: rendererID)
        self.hudVisible = hudVisible
        self.progress = progress
    }

    /// The materialised renderer pack, recorded in every result.
    public var rendererID: String? { launch.rendererID }

    /// The variables this harness adds to every launch (`benchEnvironment(hudVisible:)`).
    public var environment: [String: String] { Self.benchEnvironment(hudVisible: hudVisible) }

    /// Notes on a window whose two frame rates, or whose pairs per frame, do not agree
    /// (`crossCheckTolerance`): duplicated pairs, a halved hidden log, dropped lines. Empty when
    /// the readings agree or only one exists.
    public static func crossCheckNotes(_ reading: MetalHUDReading, hudVisible: Bool) -> [String] {
        var notes: [String] = []
        if let disagreement = reading.fpsDisagreement, disagreement > crossCheckTolerance,
           let avg = reading.stats?.avgFPS, let counter = reading.counter?.fps {
            notes.append(String(format: "interval fps %.1f and frame-counter fps %.1f disagree by %.0f%%", avg, counter, disagreement * 100))
        }
        if let ratio = reading.counter?.pairsPerFrame, abs(ratio - 1) > crossCheckTolerance {
            var note = String(format: "HUD lines carry %.2f pairs per counted frame", ratio)
            if ratio > 1.5 {
                note += hudVisible ? " (duplicated pairs not halved?)" : " (the overlay was drawn: run with --hud-visible)"
            } else if ratio < 0.75 {
                note += hudVisible ? " (--hud-visible given but the overlay was hidden?)" : " (lines dropped?)"
            }
            notes.append(note)
        }
        return notes
    }

    // MARK: Paths

    /// `bottles/<name>/results/`.
    public static func resultsRoot(for layout: BottleLayout) -> URL {
        layout.root.appending(path: resultsDirectoryName, directoryHint: .isDirectory)
    }

    /// `<root>/<yyyyMMdd-HHmmss>/`.
    public static func resultsDirectory(under root: URL, at date: Date = Date()) -> URL {
        root.appending(path: timestamp(date), directoryHint: .isDirectory)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func makeDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: Smoke

    /// Launches `program`, waits for a window, for `criteria.sustainS` seconds at
    /// `criteria.minFPS`, takes a screenshot, ends the program, and writes
    /// `results/<ts>/{hud.ndjson, wine.log, screenshot.png, result.json}`. The frames are read
    /// from `wine.log` as it is written (the unified log in `hud.ndjson` is the header-only
    /// fallback). A launch failure is a failed result, not a thrown error; I/O trouble and
    /// cancellation throw.
    public func smoke(bottle: Bottle, program: Program, timeout: TimeInterval = 180,
                      criteria: SmokeCriteria = SmokeCriteria()) async throws -> SmokeResult {
        let layout = paths.bottleLayout(bottle.name)
        let started = Date()
        let dir = Self.resultsDirectory(under: Self.resultsRoot(for: layout), at: started)
        try Self.makeDirectory(dir)
        var result = SmokeResult(bottle: bottle.name, program: program.id, engineID: bottle.engineID, rendererID: rendererID,
                                 startedAt: started, timeoutS: timeout, criteria: criteria, environment: environment)
        let stream = try LogStream.start(ndjson: dir.appending(path: Self.hudLogName))
        result.hudLogURL = stream.ndjsonURL

        let request = LaunchRequest(bottle: bottle, layout: layout, program: program,
                                    extraEnvironment: environment, logFile: dir.appending(path: Self.wineLogName))
        let process: any LaunchedProcess
        do {
            process = try await launcher.launch(request)
        } catch {
            result.reasons.append("launch failed: \(error.localizedDescription)")
            await stream.stop()
            result.evaluate()
            try JSONDocument.save(result, to: dir.appending(path: Self.resultFileName))
            return result
        }
        result.launched = true
        result.pid = Int(process.pid)
        result.logURL = process.logFile
        report("launched \(program.id) as pid \(process.pid); log \(process.logFile.path)")

        let live = LiveRun(process: process, layout: layout, stream: stream, tail: startTail(process.logFile), startedAt: started)
        do {
            try await observeMenu(live, deadline: started.addingTimeInterval(timeout), criteria: criteria, into: &result)
            if result.windowSeen {
                await captureScreenshot(live, to: dir.appending(path: Self.screenshotName), threshold: criteria.blackThreshold, into: &result)
            }
        } catch {
            result.exitStatus = await end(live)
            throw error
        }
        result.exitStatus = await end(live)
        await copyWineLog(from: process.logFile, to: dir.appending(path: Self.wineLogName), notes: &result.reasons)
        result.evaluate()
        try JSONDocument.save(result, to: dir.appending(path: Self.resultFileName))
        report("smoke \(result.verdict.rawValue)" + (result.reasons.isEmpty ? "" : ": " + result.reasons.joined(separator: "; ")))
        return result
    }

    // MARK: Bench

    /// `profile.runs` launches of `program`: preconditions → main menu → load the save →
    /// `loadWaitS` → `warmupS` → `measureS` measured → screenshot → end. Each run writes
    /// `results/<ts>/run-<n>/{hud.ndjson, wine.log, screenshot.png, result.json}` plus the
    /// files `artifacts` returns after the run (the game's settings file, DXMT logs); the
    /// session's `result.json` carries SysInfo, `pmset -g therm` before and after,
    /// engine/renderer ids, every run and the median. `caffeinate -dims` runs as a child
    /// throughout. `preconditions` (the profile's, resolved by the caller) are checked before
    /// every run and throw `.invalid`/`.missing` when they do not hold.
    public func bench(bottle: Bottle, program: Program, profile: BenchProfile = .novigrad,
                      preconditions: ResolvedBenchPreconditions? = nil,
                      artifacts: @escaping @Sendable () -> [URL] = { [] }) async throws -> BenchResult {
        try profile.validate()
        if !profile.manualLoad { try InputInjector.requireAccessibility() }
        if let preconditions { for note in try Self.checkPreconditions(preconditions) { report(note) } }
        let layout = paths.bottleLayout(bottle.name)
        let started = Date()
        let dir = Self.resultsDirectory(under: Self.resultsRoot(for: layout), at: started)
        try Self.makeDirectory(dir)
        var result = BenchResult(kind: .run, createdAt: started, bottle: bottle.name, program: program.id, engineID: bottle.engineID,
                                 rendererID: rendererID, renderer: bottle.settings.renderer.rawValue, label: nil, profile: profile,
                                 sysInfo: await SysInfo.current(), thermalBefore: await thermalReport(),
                                 environment: environment, resultsDirectory: dir)
        result.record(launch)
        try bottle.save(to: dir.appending(path: Bottle.fileName))
        let resultURL = dir.appending(path: Self.resultFileName)
        try JSONDocument.save(result, to: resultURL)
        if !Screenshot.hasScreenRecordingAccess() {
            report("note: no Screen Recording access; screenshots will not be judged")
        }

        let caffeinate = try startCaffeinate(in: dir)
        defer { caffeinate.terminate() }
        for run in 1...profile.runs {
            report("run \(run)/\(profile.runs)")
            if let preconditions, run > 1 { for note in try Self.checkPreconditions(preconditions) { report(note) } }
            let runDir = dir.appending(path: "run-\(run)", directoryHint: .isDirectory)
            let runResult = try await benchRun(run, bottle: bottle, program: program, layout: layout, profile: profile,
                                               directory: runDir, artifacts: artifacts)
            result.runs.append(runResult)
            result.summarise()
            try JSONDocument.save(result, to: resultURL)
            if run < profile.runs, profile.cooldownS > 0 {
                report("cool-down \(Int(profile.cooldownS)) s")
                try await Self.sleep(profile.cooldownS)
            }
        }
        result.thermalAfter = await thermalReport()
        result.summarise()
        try JSONDocument.save(result, to: resultURL)
        if let median = result.median {
            report("median: \(median.summary)" + (result.medianCounter.map { "; \($0.summary)" } ?? "")
                   + (result.meetsTarget.map { $0 ? " (target met)" : " (target missed)" } ?? ""))
        } else if let counter = result.medianCounter {
            report("median: \(counter.summary) (header-only HUD lines: no intervals, target not judged)")
        } else {
            report("no run produced frames")
        }
        return result
    }

    func benchRun(_ run: Int, bottle: Bottle, program: Program, layout: BottleLayout, profile: BenchProfile, directory: URL,
                  artifacts: @Sendable () -> [URL]) async throws -> BenchRunResult {
        try Self.makeDirectory(directory)
        let started = Date()
        let stream = try LogStream.start(ndjson: directory.appending(path: Self.hudLogName))
        var result = BenchRunResult(run: run, startedAt: started, hudLogURL: stream.ndjsonURL)
        let request = LaunchRequest(bottle: bottle, layout: layout, program: program, extraEnvironment: environment,
                                    logFile: directory.appending(path: Self.wineLogName))
        let process: any LaunchedProcess
        do {
            process = try await launcher.launch(request)
        } catch {
            result.notes.append("launch failed: \(error.localizedDescription)")
            await stream.stop()
            try JSONDocument.save(result, to: directory.appending(path: Self.resultFileName))
            return result
        }
        result.pid = Int(process.pid)
        result.wineLogURL = process.logFile
        let live = LiveRun(process: process, layout: layout, stream: stream, tail: startTail(process.logFile), startedAt: started)

        do {
            try await measure(live, profile: profile, directory: directory, into: &result)
        } catch {
            result.exitStatus = await end(live)
            throw error
        }
        result.exitStatus = await end(live)
        result.thermal = await thermalReport()
        await copyWineLog(from: process.logFile, to: directory.appending(path: Self.wineLogName), notes: &result.notes)
        for artifact in artifacts() {
            if let note = Self.copy(artifact, into: directory) { result.notes.append(note) }
        }
        if let stats = result.stats {
            result.meetsTarget = profile.target?.met(by: stats)
            report("run \(run): \(result.reading.summary)")
        } else if let counter = result.counter {
            report("run \(run): \(counter.summary) (no intervals: target not judged)")
        } else {
            report("run \(run) failed: \(result.notes.joined(separator: "; "))")
        }
        try JSONDocument.save(result, to: directory.appending(path: Self.resultFileName))
        return result
    }

    /// Follows the program's log (its stderr) for the HUD's full lines.
    func startTail(_ logFile: URL, fromEnd: Bool = false) -> HUDLogTail {
        HUDLogTail.start(file: logFile, halvesPairs: hudVisible, fromEnd: fromEnd)
    }

    /// The readings of `window` from the wine log, or from the unified log (narrowed to `pids`)
    /// when the wine log held no HUD line at all; nil when neither has anything.
    func reading(of live: LiveRun, window: ClosedRange<Date>, pids: Set<pid_t>) -> (reading: MetalHUDReading, source: HUDSource)? {
        live.tail.poll()
        let primary = live.tail.trace
        if !primary.isEmpty {
            let reading = primary.reading(window: window)
            if !reading.isEmpty { return (reading, .wineLog) }
        }
        let secondary = live.stream.trace.filtered(processIDs: Set(pids.map { Int($0) })).reading(window: window)
        return secondary.isEmpty ? nil : (secondary, .unifiedLog)
    }

    /// Fills a run's `stats`, `counter`, `hudSource` and notes from `window`.
    func record(_ live: LiveRun, window: ClosedRange<Date>, pids: Set<pid_t>, into result: inout BenchRunResult) {
        guard let (reading, source) = reading(of: live, window: window, pids: pids) else {
            result.notes.append("no HUD frames from the prefix's processes in the measurement window (wine log \(live.tail.sampleCount) HUD lines, unified log \(live.stream.sampleCount))")
            return
        }
        result.stats = reading.stats
        result.counter = reading.counter
        result.hudSource = source
        if reading.stats == nil {
            result.notes.append("only the unified log's header fields were available (the frame list is <private>): frame-counter rate only, no 1% low")
        }
        result.notes.append(contentsOf: Self.crossCheckNotes(reading, hudVisible: hudVisible))
        if hudVisible, live.tail.unpairedLineCount > 0 {
            result.notes.append("\(live.tail.unpairedLineCount) HUD lines did not carry duplicated pairs although --hud-visible halved them")
        }
    }

    /// Menu → load → wait → warm up → measure → screenshot, filling `result`. Returns early
    /// (with a note) when the program dies or the menu never shows.
    func measure(_ live: LiveRun, profile: BenchProfile, directory: URL, into result: inout BenchRunResult) async throws {
        var menu = SmokeResult(bottle: "", program: "", engineID: nil, rendererID: nil, startedAt: live.startedAt,
                               timeoutS: profile.menuTimeoutS, criteria: profile.menu)
        menu.launched = true
        try await observeMenu(live, deadline: live.startedAt.addingTimeInterval(profile.menuTimeoutS), criteria: profile.menu, into: &menu)
        result.exitStatus = menu.exitStatus
        guard menu.windowSeen, menu.sustainedFPS != nil else {
            result.notes.append("main menu not reached: " + menu.reasons.joined(separator: "; "))
            return
        }
        result.menuReachedAfterS = Date().timeIntervalSince(live.startedAt)

        if profile.manualLoad {
            report("load the benchmark save now: \(Int(profile.manualLoadCountdownS)) s")
            guard try await waitWhileAlive(live, seconds: profile.manualLoadCountdownS, phase: "manual load") else {
                result.notes.append("program exited during the manual-load countdown")
                return
            }
        } else {
            // The window may belong to another process of the prefix than the one launched
            // (the loader re-execs); the key goes to whoever owns it.
            let target = menu.window?.ownerPID ?? live.process.pid
            report("pressing \(profile.loadKey.rawValue) in pid \(target) to load the save")
            do {
                try await InputInjector.press(profile.loadKey, inApplication: target)
            } catch let error as OssoverError where error != .cancelled {
                // A blind key press would hit the terminal and the run would measure the main
                // menu as if it were the save: a failed run, not a measurement.
                result.notes.append("save not loaded: \(error.errorDescription ?? "\(error)")")
                return
            }
        }
        guard try await waitWhileAlive(live, seconds: profile.loadWaitS, phase: "loading") else {
            result.notes.append("program exited while loading")
            return
        }
        guard try await waitWhileAlive(live, seconds: profile.warmupS, phase: "warm-up") else {
            result.notes.append("program exited during warm-up")
            return
        }
        let measureStart = Date()
        result.measureStart = measureStart.secondPrecision
        var pids = await live.pids()
        let alive = try await waitWhileAlive(live, seconds: profile.measureS, phase: "measuring")
        let measureEnd = Date()
        result.measureEnd = measureEnd.secondPrecision
        pids.formUnion(await live.pids())
        if !alive { result.notes.append("program exited during the measurement") }
        // A line stamped just before the end reaches the file a moment later.
        await LogStream.pause(0.5)
        // The wine log holds only this launch's stderr; the HUD predicate of the unified log is
        // system-wide, so that fallback is narrowed to the prefix's processes.
        record(live, window: measureStart...measureEnd, pids: pids, into: &result)
        if alive {
            var shot = menu
            await captureScreenshot(live, to: directory.appending(path: Self.screenshotName), threshold: profile.menu.blackThreshold, into: &shot)
            result.screenshotNonBlack = shot.screenshotNonBlack
            result.meanLuminance = shot.meanLuminance
            result.screenshotURL = shot.screenshotURL
            result.notes.append(contentsOf: shot.reasons.dropFirst(menu.reasons.count))
        }
    }

    // MARK: Attach

    /// Measures an externally launched process (a CrossOver run with `MTL_HUD_ENABLED=1
    /// MTL_HUD_LOG_ENABLED=1` set through `launchctl setenv`) for `measureS`, screenshots its
    /// window, and writes `result.json` under `resultsRoot` (default `logs/attach/<ts>/`). The
    /// unified log gives only the header fields (frame-counter rate, no 1% low); `logFile`, the
    /// process's stderr when something captures it, is tailed from its current end for the full
    /// lines.
    public func attach(pid: pid_t, measureS: TimeInterval = 60, label: String? = nil, resultsRoot: URL? = nil,
                       logFile: URL? = nil) async throws -> BenchResult {
        guard measureS > 0 else { throw OssoverError.invalid("measureS must be > 0") }
        guard ProcessTable.isAlive(pid) else { throw OssoverError.missing("process \(pid) is not running") }
        if let logFile, !FileManager.default.fileExists(atPath: logFile.path) {
            throw OssoverError.missing("log file \(logFile.path)")
        }
        let started = Date()
        let root = resultsRoot ?? paths.logs.appending(path: "attach", directoryHint: .isDirectory)
        let dir = Self.resultsDirectory(under: root, at: started)
        try Self.makeDirectory(dir)
        var profile = BenchProfile(name: label ?? "attach", loadWaitS: 0, warmupS: 0, measureS: measureS, runs: 1, manualLoad: true)
        profile.cooldownS = 0
        var result = BenchResult(kind: .attach, createdAt: started, bottle: nil, program: nil, engineID: nil, rendererID: nil,
                                 renderer: nil, label: label, profile: profile, sysInfo: await SysInfo.current(),
                                 thermalBefore: await thermalReport(), environment: [:], resultsDirectory: dir)
        let resultURL = dir.appending(path: Self.resultFileName)
        try JSONDocument.save(result, to: resultURL)

        let caffeinate = try startCaffeinate(in: dir)
        defer { caffeinate.terminate() }
        let stream = try LogStream.start(ndjson: dir.appending(path: Self.hudLogName), processID: pid)
        let tail = logFile.map { startTail($0, fromEnd: true) }
        var run = BenchRunResult(run: 1, startedAt: started, hudLogURL: stream.ndjsonURL)
        run.pid = Int(pid)
        run.wineLogURL = logFile
        let arguments = ProcessTable.commandLineAndEnvironment(of: pid)?.arguments ?? []
        if !arguments.isEmpty { run.notes.append("command: " + arguments.joined(separator: " ")) }
        report("attached to pid \(pid); measuring \(Int(measureS)) s" + (logFile.map { "; tailing \($0.path)" } ?? " (unified log: header fields only)"))

        let measureStart = Date()
        run.measureStart = measureStart.secondPrecision
        var alive = true
        do {
            alive = try await waitWhile(seconds: measureS, phase: "measuring") { ProcessTable.isAlive(pid) }
        } catch {
            tail?.stop()
            await stream.stop()
            throw error
        }
        let measureEnd = Date()
        run.measureEnd = measureEnd.secondPrecision
        if !alive { run.notes.append("process \(pid) exited during the measurement") }
        await LogStream.pause(0.5)
        tail?.stop()
        await stream.stop()
        let window = measureStart...measureEnd
        let fromLog = tail.map { $0.trace.reading(window: window) }
        if let fromLog, !fromLog.isEmpty {
            run.stats = fromLog.stats
            run.counter = fromLog.counter
            run.hudSource = .wineLog
            run.notes.append(contentsOf: Self.crossCheckNotes(fromLog, hudVisible: hudVisible))
        } else {
            let reading = stream.trace.reading(window: window)
            run.stats = reading.stats
            run.counter = reading.counter
            run.hudSource = reading.isEmpty ? nil : .unifiedLog
            if reading.counter != nil, reading.stats == nil {
                run.notes.append("only the unified log's header fields were available (the frame list is <private>): frame-counter rate only, no 1% low")
            }
        }
        if !run.ok { run.notes.append("no HUD frames from pid \(pid) (are MTL_HUD_ENABLED=1 and MTL_HUD_LOG_ENABLED=1 in its environment?)") }
        if alive, Screenshot.hasScreenRecordingAccess(), let window = WindowProbe.largestWindow(ownedBy: pid) {
            let url = dir.appending(path: Self.screenshotName)
            do {
                try await Screenshot.capture(windowID: window.id, to: url)
                let luminance = try Screenshot.meanLuminance(ofPNG: url)
                run.screenshotURL = url
                run.meanLuminance = luminance
                run.screenshotNonBlack = !Screenshot.isBlack(luminance)
            } catch {
                run.notes.append("screenshot failed: \(error.localizedDescription)")
            }
        }
        run.thermal = await thermalReport()
        run.exitStatus = nil
        result.runs = [run]
        result.thermalAfter = run.thermal
        result.summarise()
        try JSONDocument.save(result, to: resultURL)
        if run.ok { report("attach: \(run.reading.summary)") }
        return result
    }

    // MARK: Phases

    /// A launched program with its prefix, the tail of its log (the HUD's full lines) and the
    /// unified-log stream (header fields).
    struct LiveRun: Sendable {
        let process: any LaunchedProcess
        let layout: BottleLayout
        let stream: LogStream
        let tail: HUDLogTail
        let startedAt: Date

        /// The launched pid plus whatever else runs in the prefix (a child the loader spawned).
        func pids() async -> Set<pid_t> {
            var pids: Set<pid_t> = [process.pid]
            if let more = try? await ProcessTable.processes(ofPrefix: layout.prefix) { pids.formUnion(more) }
            return pids
        }
    }

    /// Waits for a window, then for `criteria.sustainS` seconds at `criteria.minFPS`; the
    /// program exiting ends the wait with a reason.
    func observeMenu(_ live: LiveRun, deadline: Date, criteria: SmokeCriteria, into result: inout SmokeResult) async throws {
        let windowDeadline = min(deadline, live.startedAt.addingTimeInterval(criteria.windowTimeoutS))
        var pids: Set<pid_t> = [live.process.pid]
        var lastPIDRefresh = Date.distantPast
        while true {
            if let status = live.process.exitStatus {
                result.exitStatus = status
                result.reasons.append("exited with status \(status) before a window appeared")
                return
            }
            if Date().timeIntervalSince(lastPIDRefresh) >= 2 {
                pids = await live.pids()
                lastPIDRefresh = Date()
            }
            if let window = WindowProbe.largestWindow(ownedByAny: pids) {
                result.windowSeen = true
                result.windowSeenAfterS = (Date().timeIntervalSince(live.startedAt) * 10).rounded() / 10
                result.window = window
                report("window after \(result.windowSeenAfterS ?? 0) s: \(window.summary)")
                break
            }
            guard Date() < windowDeadline else {
                result.reasons.append("no window within \(Int(criteria.windowTimeoutS)) s")
                return
            }
            try await Self.sleep(0.5)
        }

        while true {
            if let status = live.process.exitStatus {
                result.exitStatus = status
                result.reasons.append("exited with status \(status) before \(criteria.sustainS) s at ≥\(Int(criteria.minFPS)) fps")
                return
            }
            if Date().timeIntervalSince(lastPIDRefresh) >= 2 {
                pids.formUnion(await live.pids())
                lastPIDRefresh = Date()
            }
            // The wine log is this launch's own stderr. The unified log's predicate is
            // system-wide, so that fallback keeps only this prefix's frames: another Metal
            // app's HUD lines must not pass the menu check.
            live.tail.poll()
            let primary = live.tail.trace
            var source = HUDSource.wineLog
            var reading = primary.sustained(minFPS: criteria.minFPS, seconds: Double(criteria.sustainS))
            if reading == nil, primary.isEmpty {
                source = .unifiedLog
                reading = live.stream.trace.filtered(processIDs: Set(pids.map { Int($0) }))
                    .sustained(minFPS: criteria.minFPS, seconds: Double(criteria.sustainS))
            }
            if let reading, let fps = reading.fps {
                result.sustainedFPS = (fps * 10).rounded() / 10
                result.sustainedStats = reading.stats
                result.sustainedCounter = reading.counter
                result.hudSource = source
                // The smoke result has no notes row: a cross-check finding is a reason without a verdict.
                result.reasons.append(contentsOf: Self.crossCheckNotes(reading, hudVisible: hudVisible).map { "note: " + $0 })
                report("sustained \(reading.summary)" + (source == .unifiedLog ? " (unified log: header fields only)" : ""))
                return
            }
            guard Date() < deadline else {
                result.reasons.append("no \(criteria.sustainS) s at ≥\(Int(criteria.minFPS)) fps before the timeout (\(primary.samples.count) HUD lines in the wine log, \(live.stream.sampleCount) in the unified log)")
                return
            }
            try await Self.sleep(1)
        }
    }

    // MARK: Preconditions

    /// Checks (and where it can, establishes) the plan's bench preconditions; returns notes on
    /// what it did. The newest `*.<ext>` in `savesDirectory` must hash the same as
    /// `benchmarkSave`, else the benchmark save is copied in with a fresh mtime (so "Continue"
    /// loads it); the settings file must hold every `requiredSettings` pair. Throws `.missing`
    /// for an absent benchmark save, save directory or settings file and `.invalid` for a
    /// settings value that is off (re-run the game's recipe).
    public static func checkPreconditions(_ preconditions: ResolvedBenchPreconditions) throws -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        if let save = preconditions.benchmarkSave {
            guard fm.fileExists(atPath: save.path) else {
                throw OssoverError.missing("benchmark save \(save.path): create it in-game once (plan §3 Phase 3 step 4) and put it there")
            }
            guard let saves = preconditions.savesDirectory else { throw OssoverError.invalid("preconditions name a benchmark save but no save directory") }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: saves.path, isDirectory: &isDir), isDir.boolValue else {
                throw OssoverError.missing("save directory \(saves.path) (start the game once so it creates it)")
            }
            let wanted = try SHA256Hasher.hex(ofFile: save)
            let newest = try newestFile(in: saves, extension: preconditions.saveExtension)
            if let newest, (try? SHA256Hasher.hex(ofFile: newest)) == wanted {
                notes.append("benchmark save is the newest in \(saves.lastPathComponent) (\(newest.lastPathComponent))")
            } else {
                let destination = saves.appending(path: save.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: save, to: destination)
                    try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                } catch {
                    throw OssoverError.io("cannot place the benchmark save at \(destination.path): \(error.localizedDescription)")
                }
                notes.append("benchmark save copied to \(destination.path) (newest was \(newest?.lastPathComponent ?? "none"))")
            }
        }
        if let settings = preconditions.settingsFile, !preconditions.requiredSettings.isEmpty {
            guard fm.fileExists(atPath: settings.path) else {
                throw OssoverError.missing("settings file \(settings.path): apply the game's recipe first")
            }
            let ini = try IniFile.load(from: settings)
            let wrong = preconditions.requiredSettings.keys.sorted().compactMap { key -> String? in
                let have = ini.value(key: key)
                return have == preconditions.requiredSettings[key] ? nil : "\(key)=\(have ?? "<absent>") (wanted \(preconditions.requiredSettings[key] ?? ""))"
            }
            guard wrong.isEmpty else {
                throw OssoverError.invalid("\(settings.lastPathComponent) is not the benchmark profile: " + wrong.joined(separator: ", ") + "; re-apply the game's recipe")
            }
            notes.append("\(settings.lastPathComponent) holds the benchmark profile (" + preconditions.requiredSettings.keys.sorted().joined(separator: ", ") + ")")
        }
        return notes
    }

    /// The most recently modified `*.<ext>` directly in `directory`, nil when there is none.
    public static func newestFile(in directory: URL, extension ext: String) throws -> URL? {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])
        } catch {
            throw OssoverError.io("cannot list \(directory.path): \(error.localizedDescription)")
        }
        return entries.filter { $0.pathExtension.lowercased() == ext.lowercased() && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) }
            .max { a, b in
                let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ad == bd ? a.lastPathComponent < b.lastPathComponent : ad < bd
            }
    }

    /// Screenshots the program's largest window and judges it; every failure is a reason, not an error.
    func captureScreenshot(_ live: LiveRun, to url: URL, threshold: Double, into result: inout SmokeResult) async {
        guard Screenshot.hasScreenRecordingAccess() else {
            result.reasons.append("screenshot skipped: no Screen Recording access")
            return
        }
        guard let window = WindowProbe.largestWindow(ownedByAny: await live.pids()) else {
            result.reasons.append("screenshot skipped: the window is gone")
            return
        }
        do {
            try await Screenshot.capture(windowID: window.id, to: url)
            let luminance = try Screenshot.meanLuminance(ofPNG: url)
            result.screenshotURL = url
            result.meanLuminance = (luminance * 10000).rounded() / 10000
            result.screenshotNonBlack = !Screenshot.isBlack(luminance, threshold: threshold)
            if result.screenshotNonBlack == false {
                result.reasons.append(String(format: "screenshot is black (mean luminance %.4f)", luminance))
            }
            report(String(format: "screenshot mean luminance %.3f", luminance))
        } catch {
            result.reasons.append("screenshot failed: \(error.localizedDescription)")
        }
    }

    /// Sleeps `seconds` in one-second steps while the program runs; false when it exited first.
    func waitWhileAlive(_ live: LiveRun, seconds: TimeInterval, phase: String) async throws -> Bool {
        try await waitWhile(seconds: seconds, phase: phase) { live.process.isRunning }
    }

    func waitWhile(seconds: TimeInterval, phase: String, _ condition: @Sendable () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var nextReport = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard condition() else { return false }
            let now = Date()
            if now >= nextReport {
                report("\(phase): \(Int(deadline.timeIntervalSince(now).rounded(.up))) s left")
                nextReport = now.addingTimeInterval(10)
            }
            try await Self.sleep(min(1, deadline.timeIntervalSince(Date())))
        }
        return condition()
    }

    /// SIGTERM the program, give it 5 s, SIGKILL, then the launcher's shutdown and a sweep of
    /// the prefix; stops the HUD stream. Returns the program's exit status.
    func end(_ live: LiveRun) async -> Int32? {
        if live.process.isRunning {
            live.process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while live.process.isRunning, Date() < deadline {
                await LogStream.pause(0.2)   // still waits when the task was cancelled (Ctrl-C)
            }
            if live.process.isRunning { live.process.forceKill() }
        }
        try? await launcher.shutdown(live.layout)
        if let leftover = try? await ProcessTable.processes(ofPrefix: live.layout.prefix), !leftover.isEmpty {
            ProcessTable.terminate(leftover, grace: 3)
        }
        live.tail.stop()
        await live.stream.stop()
        return live.process.exitStatus
    }

    // MARK: Helpers

    func report(_ line: String) { progress?(line) }

    static func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            throw OssoverError.cancelled
        }
    }

    /// `caffeinate -dims -w <our pid>`, logging to `caffeinate.log` in `directory`.
    func startCaffeinate(in directory: URL) throws -> ShellProcess {
        try Shell.runStreaming(executable: Self.caffeinateExecutable, args: Self.caffeinateArguments(waitingFor: getpid()),
                               logFile: directory.appending(path: "caffeinate.log"))
    }

    /// `pmset -g therm`, trimmed; never throws (the report is a note, not a gate).
    func thermalReport() async -> String {
        do {
            let result = try await Shell.run(executable: Self.pmsetExecutable, args: Self.pmsetThermalArguments, timeout: 10)
            return result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unavailable: \(error.localizedDescription)"
        }
    }

    /// Copies the launcher's log to `destination` unless it already is that file.
    func copyWineLog(from source: URL, to destination: URL, notes: inout [String]) async {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            notes.append("wine log not copied: \(error.localizedDescription)")
        }
    }

    /// Copies a file into `directory`; returns a note on failure.
    static func copy(_ file: URL, into directory: URL) -> String? {
        let destination = directory.appending(path: file.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
            return nil
        } catch {
            return "\(file.lastPathComponent) not copied: \(error.localizedDescription)"
        }
    }
}
