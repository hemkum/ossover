// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// What `result.json` records about a benchmark session (decision 35: the matrix is read back
/// from the results alone) and the HUD rows every renderer gets (decision 38, REA L-58).
@Suite struct BenchResultTests {
    static func result(renderer: String? = "auto") -> BenchResult {
        BenchResult(kind: .run, createdAt: Date(timeIntervalSince1970: 1_800_000_000), bottle: "witcher3", program: "witcher3",
                    engineID: "test-engine", rendererID: nil, renderer: renderer, label: nil, profile: .novigrad,
                    sysInfo: SysInfo(macOSVersion: "26.0", macOSBuild: "25A000", chipBrand: "Apple M5 Pro", isAppleSilicon: true, cpuCount: 16, memoryGB: 48, rosettaInstalled: true), thermalBefore: "CPU_Scheduler_Limit = 100", environment: BenchHarness.benchEnvironment,
                    resultsDirectory: URL(fileURLWithPath: "/ossover-test/bottles/witcher3/results/20261014-120000"))
    }

    @Test("the launch info comes from the engine, the bottle and the resolved renderer")
    func launchInfoFromASelection() throws {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        let bottle = Bottle(name: "witcher3", engineID: engine.id, settings: BottleSettings(sync: .msync, renderer: .dxmt))
        let selection = try RendererResolver.resolve(choice: .dxmt, engine: engine, packs: [Fixtures.dxmtPack])
        let info = BenchLaunchInfo(engine: engine, bottle: bottle, renderer: selection, wineVersionString: "wine-11.0-8726-g2e2f5fca349")
        #expect(info == BenchLaunchInfo(engineID: "test-engine", wineVersion: "11.16", wineVersionString: "wine-11.0-8726-g2e2f5fca349",
                                        rendererChoice: .dxmt, rendererKind: .dxmt, rendererID: "dxmt-0.80", rendererVersion: "0.80",
                                        rendererStrategy: .prefixCopy, sync: .msync))

        // An override to dxvk on a prepend engine, and a sync the engine lacks, are recorded as they ran.
        let prepend = Fixtures.engine(capabilities: Fixtures.crossOverPrepend)
        let dxvk = try RendererResolver.resolve(choice: .dxvk, engine: prepend, packs: [Fixtures.dxmtPack, Fixtures.dxvkPack])
        let overridden = BenchLaunchInfo(engine: prepend, bottle: bottle, renderer: dxvk)
        #expect(overridden.rendererKind == .dxvk && overridden.rendererID == "dxvk-macos-1.10.3" && overridden.rendererStrategy == .prepend)
        #expect(overridden.wineVersionString == nil)
        let vanilla = Fixtures.engine(capabilities: Fixtures.vanillaEsync)
        #expect(BenchLaunchInfo(engine: vanilla, bottle: bottle, renderer: .wined3d).sync == .esync, "msync asked, esync is what runs")
        let wined3d = BenchLaunchInfo(engine: vanilla, bottle: bottle, renderer: .wined3d)
        #expect(wined3d.rendererKind == .wined3d && wined3d.rendererID == nil && wined3d.rendererStrategy == OverlayStrategy.none)
    }

    @Test("result.json carries renderer, sync, engine id and wine version; older files still load")
    func resultRecordsTheLaunch() throws {
        var result = Self.result()
        #expect(result.renderer == "auto" && result.sync == nil && result.rendererStrategy == nil)
        result.record(BenchLaunchInfo(engineID: "test-engine", wineVersion: "11.16", wineVersionString: "wine-11.0-8726-g2e2f5fca349",
                                      rendererChoice: .auto, rendererKind: .dxmt, rendererID: "dxmt-0.80", rendererVersion: "0.80",
                                      rendererStrategy: .prefixCopy, sync: .msync))
        #expect(result.renderer == "dxmt" && result.rendererChoice == "auto" && result.rendererID == "dxmt-0.80")
        #expect(result.rendererVersion == "0.80" && result.rendererStrategy == "B" && result.sync == "msync")
        #expect(result.wineVersion == "11.16" && result.wineVersionString == "wine-11.0-8726-g2e2f5fca349")
        #expect(result.environment == ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1", "MTL_HUD_HIDDEN": "1", "WINEDEBUG": "-all"],
                "the HUD rows are in the file")

        let data = try JSONDocument.encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in ["engineId": "test-engine", "wineVersion": "11.16", "wineVersionString": "wine-11.0-8726-g2e2f5fca349",
                             "renderer": "dxmt", "rendererChoice": "auto", "rendererId": "dxmt-0.80", "rendererVersion": "0.80",
                             "rendererStrategy": "B", "sync": "msync"] {
            #expect(object[key] as? String == value, Comment(rawValue: key))
        }
        #expect((object["environment"] as? [String: String])?["MTL_HUD_LOG_ENABLED"] == "1")
        #expect(try JSONDocument.decode(BenchResult.self, from: data) == result)

        // A result written before these rows existed decodes with them nil.
        var legacy = object
        for key in ["wineVersion", "wineVersionString", "rendererChoice", "rendererVersion", "rendererStrategy", "sync"] { legacy[key] = nil }
        let old = try JSONDocument.decode(BenchResult.self, from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(old.sync == nil && old.rendererStrategy == nil && old.wineVersion == nil && old.renderer == "dxmt")

        // A partial record keeps what it does not know.
        var partial = Self.result(renderer: "dxvk")
        partial.record(BenchLaunchInfo(sync: SyncMode.none))
        #expect(partial.renderer == "dxvk" && partial.sync == "none" && partial.engineID == "test-engine")
    }

    @Test("the harness records the launch it was given, and a bare rendererID still works")
    func harnessCarriesTheLaunch() {
        let launch = BenchLaunchInfo(engineID: "e", rendererKind: .dxvk, rendererID: "dxvk-macos-1.10.3", sync: SyncMode.none)
        let harness = BenchHarness(paths: Fixtures.paths, launcher: RecordingLauncher(), launch: launch)
        #expect(harness.launch == launch && harness.rendererID == "dxvk-macos-1.10.3")
        #expect(!harness.hudVisible && harness.environment == BenchHarness.benchEnvironment, "hidden overlay by default")
        let bare = BenchHarness(paths: Fixtures.paths, launcher: RecordingLauncher(), rendererID: "dxmt-0.80")
        #expect(bare.launch == BenchLaunchInfo(rendererID: "dxmt-0.80") && bare.rendererID == "dxmt-0.80")
        #expect(BenchHarness(paths: Fixtures.paths, launcher: RecordingLauncher()).rendererID == nil)
        let visible = BenchHarness(paths: Fixtures.paths, launcher: RecordingLauncher(), hudVisible: true)
        #expect(visible.hudVisible && visible.environment == BenchHarness.benchEnvironment(hudVisible: true))
        #expect(visible.environment["MTL_HUD_HIDDEN"] == nil && visible.environment["MTL_HUD_ENABLED"] == "1")
    }

    /// The probe's facts, as the environment table encodes them: `MTL_HUD_ENABLED=1` is required
    /// for any log line, `MTL_HUD_HIDDEN=1` keeps the overlay off (one pair per frame), and
    /// `--hud-visible` drops only that row.
    @Test("the bench environment hides the HUD unless asked otherwise")
    func environmentHidesTheHUD() {
        #expect(BenchHarness.benchEnvironment == ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1", "MTL_HUD_HIDDEN": "1", "WINEDEBUG": "-all"])
        #expect(BenchHarness.benchEnvironment(hudVisible: false) == BenchHarness.benchEnvironment)
        #expect(BenchHarness.benchEnvironment(hudVisible: true) == ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1", "WINEDEBUG": "-all"])
    }

    @Test("a run's result carries both readings and their source; older files still load")
    func runResultCarriesBothReadings() throws {
        let hud = URL(fileURLWithPath: "/ossover-test/bottles/witcher3/results/20261014-120000/run-1/hud.ndjson")
        var run = BenchRunResult(run: 1, startedAt: Date(timeIntervalSince1970: 1_800_000_000), hudLogURL: hud)
        #expect(!run.ok && run.reading.isEmpty)
        let counter = MetalHUDCounterStats(firstFrame: 100, lastFrame: 7300, wallS: 60, samples: 74, pairs: 7200,
                                           minSegmentFPS: 110, maxSegmentS: 0.9, processID: 41884)
        run.counter = counter
        run.hudSource = .unifiedLog
        #expect(run.ok, "a header-only source still measured the counter's rate")
        #expect(run.reading == MetalHUDReading(stats: nil, counter: counter))
        let stats = MetalHUDStats(frames: 7200, avgFPS: 119.9, p1LowFPS: 90, p50FPS: 120, gpuTimeMeanMs: 1, durationS: 60.05, samples: 74,
                                  p99IntervalMs: 11.1, maxIntervalMs: 20)
        run.stats = stats
        run.hudSource = .wineLog
        let data = try JSONDocument.encode(run)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hudSource"] as? String == "wine-log")
        let counterObject = try #require(object["counter"] as? [String: Any])
        #expect(counterObject["fps"] as? Double == 120 && counterObject["frames"] as? Int == 7200 && counterObject["wallS"] as? Double == 60)
        #expect((object["stats"] as? [String: Any])?["avgFPS"] as? Double == 119.9, "both frame rates are in the file")
        #expect(try JSONDocument.decode(BenchRunResult.self, from: data) == run)

        var legacy = object
        legacy["counter"] = nil
        legacy["hudSource"] = nil
        let old = try JSONDocument.decode(BenchRunResult.self, from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(old.counter == nil && old.hudSource == nil && old.stats == stats && old.ok)

        var session = Self.result()
        session.runs = [run, old]
        session.summarise()
        let medianCounter = try #require(session.medianCounter, "the median counter comes from the runs that have one")
        #expect(medianCounter.fps == 120 && medianCounter.frames == 7200 && medianCounter.wallS == 60 && medianCounter.samples == 74)
        #expect(session.median?.avgFPS == 119.9 && session.meetsTarget == true)
        let sessionObject = try #require(try JSONSerialization.jsonObject(with: try JSONDocument.encode(session)) as? [String: Any])
        #expect((sessionObject["medianCounter"] as? [String: Any])?["fps"] as? Double == 120)
        var headerOnly = Self.result()
        var bare = run
        bare.stats = nil
        headerOnly.runs = [bare]
        headerOnly.summarise()
        #expect(headerOnly.median == nil && headerOnly.medianCounter?.fps == 120 && headerOnly.meetsTarget == nil, "no intervals: the target is not judged")
    }

    @Test("the smoke result records the counter reading, the source and the environment; older files still load")
    func smokeResultCarriesTheCounter() throws {
        var result = SmokeResult(bottle: "test", program: "d3d11present", engineID: "e", rendererID: nil,
                                 startedAt: Date(timeIntervalSince1970: 1_800_000_000), timeoutS: 60, criteria: SmokeCriteria(),
                                 environment: BenchHarness.benchEnvironment)
        result.launched = true
        result.windowSeen = true
        let counter = MetalHUDCounterStats(firstFrame: 103, lastFrame: 701, wallS: 5.1, samples: 7, pairs: 598,
                                           minSegmentFPS: 118, maxSegmentS: 0.82, processID: 46721)
        result.sustainedFPS = (counter.fps * 10).rounded() / 10
        result.sustainedCounter = counter
        result.hudSource = .wineLog
        result.evaluate()
        #expect(result.verdict == .fail, "a screenshot is still required")
        result.screenshotNonBlack = true
        result.evaluate()
        #expect(result.passed)
        let data = try JSONDocument.encode(result)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hudSource"] as? String == "wine-log" && object["sustainedFPS"] as? Double == 117.3)
        #expect((object["environment"] as? [String: String])?["MTL_HUD_HIDDEN"] == "1")
        #expect((object["sustainedCounter"] as? [String: Any])?["frames"] as? Int == 598)
        #expect(try JSONDocument.decode(SmokeResult.self, from: data) == result)
        var legacy = object
        for key in ["sustainedCounter", "hudSource", "environment"] { legacy[key] = nil }
        let old = try JSONDocument.decode(SmokeResult.self, from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(old.sustainedCounter == nil && old.hudSource == nil && old.environment == nil && old.sustainedFPS == 117.3 && old.passed)
    }

    @Test("the cross-check notes name what disagrees")
    func crossCheckNotes() {
        func stats(_ avg: Double) -> MetalHUDStats {
            MetalHUDStats(frames: 600, avgFPS: avg, p1LowFPS: 50, p50FPS: avg, gpuTimeMeanMs: 1, durationS: 10, samples: 7, p99IntervalMs: 20, maxIntervalMs: 30)
        }
        func counter(frames: Int, pairs: Int) -> MetalHUDCounterStats {
            MetalHUDCounterStats(firstFrame: 0, lastFrame: frames, wallS: 10, samples: 7, pairs: pairs, minSegmentFPS: 50, maxSegmentS: 2, processID: 1)
        }
        #expect(BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: counter(frames: 600, pairs: 600)), hudVisible: false).isEmpty)
        #expect(BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(64), counter: counter(frames: 600, pairs: 600)), hudVisible: false).isEmpty, "within 10%")
        let slow = BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(40), counter: counter(frames: 600, pairs: 600)), hudVisible: false)
        #expect(slow == ["interval fps 40.0 and frame-counter fps 60.0 disagree by 33%"])
        let doubled = BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: counter(frames: 600, pairs: 1200)), hudVisible: false)
        #expect(doubled == ["HUD lines carry 2.00 pairs per counted frame (the overlay was drawn: run with --hud-visible)"])
        let unhalved = BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: counter(frames: 600, pairs: 1200)), hudVisible: true)
        #expect(unhalved == ["HUD lines carry 2.00 pairs per counted frame (duplicated pairs not halved?)"])
        let halvedHidden = BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: counter(frames: 600, pairs: 300)), hudVisible: true)
        #expect(halvedHidden == ["HUD lines carry 0.50 pairs per counted frame (--hud-visible given but the overlay was hidden?)"])
        let dropped = BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: counter(frames: 600, pairs: 300)), hudVisible: false)
        #expect(dropped == ["HUD lines carry 0.50 pairs per counted frame (lines dropped?)"])
        #expect(BenchHarness.crossCheckNotes(MetalHUDReading(stats: nil, counter: counter(frames: 600, pairs: 0)), hudVisible: false).isEmpty, "header-only: nothing to compare")
        #expect(BenchHarness.crossCheckNotes(MetalHUDReading(stats: stats(60), counter: nil), hudVisible: false).isEmpty)
    }

    @Test("the bench HUD rows reach the Wine process for every renderer (decision 38, REA L-58)")
    func hudRowsHoldForEveryRenderer() throws {
        let cases: [(RendererChoice, EngineCapabilities, [RendererPack])] = [
            (.dxmt, Fixtures.crossOver, [Fixtures.dxmtPack]),
            (.dxmt, Fixtures.crossOverPrepend, [Fixtures.dxmtPack]),
            (.dxvk, Fixtures.vanillaEsync, [Fixtures.dxvkPack]),
            (.d3dmetal, Fixtures.crossOverPrepend, [Fixtures.d3dmetalPack]),
            (.wined3d, Fixtures.vanillaEsync, []),
        ]
        for (choice, capabilities, packs) in cases {
            let engine = Fixtures.engine(capabilities: capabilities)
            let bottle = Bottle(name: "hud", engineID: engine.id, settings: BottleSettings(renderer: choice))
            let selection = try RendererResolver.resolve(choice: choice, engine: engine, packs: packs)
            #expect(selection.kind == choice.kind, Comment(rawValue: choice.rawValue))
            let env = WineEnvironment.make(engine: engine, bottle: bottle, layout: Fixtures.paths.bottleLayout("hud"), program: nil,
                                           renderer: selection, extra: BenchHarness.benchEnvironment)
            #expect(env["MTL_HUD_ENABLED"] == "1", Comment(rawValue: choice.rawValue))
            #expect(env["MTL_HUD_LOG_ENABLED"] == "1", Comment(rawValue: choice.rawValue))
            #expect(env["MTL_HUD_HIDDEN"] == "1", Comment(rawValue: choice.rawValue))
            #expect(env["WINEDEBUG"] == "-all", Comment(rawValue: choice.rawValue))
        }
        #expect(BenchHarness.benchEnvironment.keys.sorted() == ["MTL_HUD_ENABLED", "MTL_HUD_HIDDEN", "MTL_HUD_LOG_ENABLED", "WINEDEBUG"])
    }
}

/// A launcher that never launches: the harness is constructed, not run.
struct RecordingLauncher: ProgramLauncher {
    func launch(_ request: LaunchRequest) async throws -> any LaunchedProcess {
        throw OssoverError.unsupported("test launcher")
    }

    func shutdown(_ layout: BottleLayout) async throws {}
}
