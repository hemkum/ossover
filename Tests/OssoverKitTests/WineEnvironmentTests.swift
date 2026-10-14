// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// Golden snapshots of the plan §4 env table per renderer × sync × overlay strategy, as settled
/// by `docs/rea/decisions.md` 1–11. Every dictionary is spelled out in full: a new row or a
/// changed value must change a test. Row labels: `LC_ALL` is ossover-specific (REA L-14, not
/// CrossOver parity); `WINESERVER`/`WINELOADER` are the fixed rows of decision 6 (REA L-10);
/// `GST_REGISTRY` is per engine under `<home>/cache` (REA L-08); sync rows follow REA L-30/L-32
/// (no `WINEESYNC` on an engine without esync); `CX_*` rows exist only on CX-derived engines.
@Suite struct WineEnvironmentGoldenTests {
    static let prefix = "/ossover-test/bottles/golden/prefix"
    static let logs = #"Z:\ossover-test\bottles\golden\logs"#
    static let wineserver = "/ossover-test/engines/test-engine/wine/bin/wineserver"
    static let wineloader = "/ossover-test/engines/test-engine/wine/bin/wine"
    static let gstPlugins = "/ossover-test/engines/test-engine/wine/lib/gstreamer-1.0"
    static let gstRegistry = "/ossover-test/cache/gstreamer-registry-test-engine.x86_64.bin"
    static let gptkRoot = URL(fileURLWithPath: "/ossover-test/renderers/d3dmetal-3.0", isDirectory: true)
    static let libd3dshared = "/ossover-test/renderers/d3dmetal-3.0/external/libd3dshared.dylib"

    /// Resolves the bottle's renderer against `packs` (pure) and builds the table.
    func environment(capabilities: EngineCapabilities, settings: BottleSettings, packs: [RendererPack],
                     program: Program? = nil, extra: [String: String] = [:], baseEnv: [String: String] = [:],
                     frameworks: String? = nil, gptkPack: URL? = nil) throws -> [String: String] {
        let engine = Fixtures.engine(capabilities: capabilities, baseEnv: baseEnv, frameworks: frameworks)
        let bottle = Bottle(name: "golden", engineID: engine.id, settings: settings)
        let selection = try RendererResolver.resolve(choice: settings.renderer, engine: engine, packs: packs)
        return WineEnvironment.make(engine: engine, bottle: bottle, layout: Fixtures.paths.bottleLayout("golden"),
                                    program: program, renderer: selection, gptkPack: gptkPack, extra: extra)
    }

    @Test("A: dxmt × msync × strategy B (bootstrap engine)")
    func dxmtMsyncPrefixCopy() throws {
        let env = try environment(capabilities: Fixtures.crossOver,
                                  settings: BottleSettings(sync: .msync, renderer: .dxmt),
                                  packs: [Fixtures.dxmtPack])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n,b",
            "WINEMSYNC": "1",   // no WINEESYNC row: esync is not compiled in (REA L-32)
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH": "/ossover-test/renderers/dxmt-0.80/wine",
            "DXMT_LOG_PATH": Self.logs,
            "DXMT_LOG_LEVEL": "info",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt",
        ])
    }

    @Test("B: dxmt × msync × strategy C (WINEDLLPATH_PREPEND engine)")
    func dxmtMsyncPrepend() throws {
        let env = try environment(capabilities: Fixtures.crossOverPrepend,
                                  settings: BottleSettings(sync: .msync, renderer: .dxmt),
                                  packs: [Fixtures.dxmtPack])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",   // no renderer override under strategy C (REA L-05, L-20, L-26; decision 39)
            "WINEMSYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH_PREPEND": "/ossover-test/renderers/dxmt-0.80/wine",
            "DXMT_LOG_PATH": Self.logs,
            "DXMT_LOG_LEVEL": "info",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt",
        ])
    }

    @Test("C: dxvk × esync × strategy B (vanilla engine with esync: both sync rows, no CX rows)")
    func dxvkEsyncPrefixCopy() throws {
        let env = try environment(capabilities: Fixtures.vanillaEsync,
                                  settings: BottleSettings(sync: .esync, renderer: .dxvk),
                                  packs: [Fixtures.dxvkPack])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;d3d9,d3d10core,d3d11,dxgi=n,b",
            "WINEMSYNC": "0",
            "WINEESYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH": "/ossover-test/renderers/dxvk-macos-1.10.3/wine",
            "DXVK_LOG_PATH": Self.logs,
        ])
    }

    @Test("D: wined3d × none × no overlay (CrossOver engine): explicit WINEMSYNC=0, nothing else")
    func wined3dNone() throws {
        let env = try environment(capabilities: Fixtures.crossOver,
                                  settings: BottleSettings(sync: .none, renderer: .wined3d),
                                  packs: [Fixtures.dxmtPack])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "WINEMSYNC": "0",   // equals unset; documents intent (REA L-30)
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "CX_ACTIVE_GRAPHICS_BACKEND": "wined3d",
        ])
    }

    @Test("E: d3dmetal on an engine without WINEDLLPATH_PREPEND is refused, never env-only")
    func d3dmetalNeedsPrepend() throws {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        #expect(throws: OssoverError.self) {
            try environment(capabilities: Fixtures.crossOver,
                            settings: BottleSettings(sync: .msync, renderer: .d3dmetal, dlssMetalFX: true),
                            packs: [Fixtures.d3dmetalPack])
        }
        #expect(RendererResolver.strategy(for: .d3dmetal, engine: engine) == .prepend, "D3DMetal has one strategy")
        #expect(RendererResolver.unmet(pack: Fixtures.d3dmetalPack, engine: engine).contains(RendererResolver.d3dmetalPrependReason))
        let selection = RendererSelection(choice: .d3dmetal, kind: .d3dmetal, pack: Fixtures.d3dmetalPack,
                                          dllPath: Fixtures.d3dmetalPack.wineDir, strategy: .prepend)
        #expect(RendererMaterializer.unmet(selection: selection, engine: engine).contains(RendererResolver.d3dmetalPrependReason))
        let reason = RendererResolver.unavailableReason(kind: .d3dmetal, engine: engine, packs: [Fixtures.d3dmetalPack])
        #expect(reason.contains("dllPathPrepend"))
        // The prepend engine still takes it (test H has the full table).
        #expect(RendererResolver.unmet(pack: Fixtures.d3dmetalPack, engine: Fixtures.engine(capabilities: Fixtures.crossOverPrepend)).isEmpty)
    }

    @Test("F: dxmt × msync requested on an esync-only engine degrades to esync (both rows, engine reads esync)")
    func dxmtMsyncDegradesToEsync() throws {
        let env = try environment(capabilities: Fixtures.vanillaEsyncMacdrv,
                                  settings: BottleSettings(sync: .msync, renderer: .dxmt),
                                  packs: [Fixtures.dxmtPack])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n,b",
            "WINEMSYNC": "0",
            "WINEESYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH": "/ossover-test/renderers/dxmt-0.80/wine",
            "DXMT_LOG_PATH": Self.logs,
            "DXMT_LOG_LEVEL": "info",
        ])
    }

    @Test("G: dxmt × msync × B with baseEnv, bottle env, program env, bench extra and KEY+ appends")
    func dxmtWithLayeredEnvironment() throws {
        let settings = BottleSettings(sync: .msync, renderer: .dxmt, advertiseAVX: false, metalHUD: true, metalHUDLog: true,
                                      dlssMetalFX: true, dllOverrides: ["nvapi64=n"],
                                      env: ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;", "WINEDLLOVERRIDES+": "amd_ags_x64="])
        let program = Program(id: "game", name: "Game", exe: #"C:\Games\game.exe"#, env: ["WINEDEBUG": "+loaddll"])
        let env = try environment(capabilities: Fixtures.crossOver, settings: settings, packs: [Fixtures.dxmtPack],
                                  program: program, extra: ["WINEDEBUG": "-all", "MTL_HUD_ENABLED": "1"],
                                  baseEnv: ["OSSOVER_ENGINE_LIB": "${engine}/wine/lib", "WINEDEBUG": "warn+all"])
        #expect(env == [
            "OSSOVER_ENGINE_LIB": "/ossover-test/engines/test-engine/wine/lib",
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n,b;nvapi64=n;amd_ags_x64=",
            "WINEMSYNC": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "MTL_HUD_ENABLED": "1",
            "MTL_HUD_LOG_ENABLED": "1",
            "WINEDLLPATH": "/ossover-test/renderers/dxmt-0.80/wine",
            "DXMT_LOG_PATH": Self.logs,
            "DXMT_LOG_LEVEL": "info",
            "DXMT_ENABLE_NVEXT": "1",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt",
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
        ])
    }

    @Test("I: a plain WINEDLLOVERRIDES in bottle env, program env or --env appends, never replaces")
    func plainOverridesKeyAppends() throws {
        let settings = BottleSettings(sync: .msync, renderer: .dxmt, env: ["WINEDLLOVERRIDES": "version=n,b"])
        let program = Program(id: "game", name: "Game", exe: #"C:\Games\game.exe"#, env: ["WINEDLLOVERRIDES": "amd_ags_x64="])
        let env = try environment(capabilities: Fixtures.crossOver, settings: settings, packs: [Fixtures.dxmtPack],
                                  program: program, extra: ["WINEDLLOVERRIDES": "dinput8=n,b;version=n,b"],
                                  baseEnv: ["WINEDLLOVERRIDES": "mscoree=d"])
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree=d;dxgi,d3d11,d3d10core=n,b;version=n,b;amd_ags_x64=;dinput8=n,b",
            "WINEMSYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH": "/ossover-test/renderers/dxmt-0.80/wine",
            "DXMT_LOG_PATH": Self.logs,
            "DXMT_LOG_LEVEL": "info",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt",
        ])
    }

    @Test("H: d3dmetal × msync × C: libd3dshared row from the selection's pack, no DYLD_* rows even with bundled frameworks")
    func d3dmetalWithFrameworks() throws {
        let env = try environment(capabilities: Fixtures.crossOverPrepend,
                                  settings: BottleSettings(sync: .msync, renderer: .d3dmetal),
                                  packs: [Fixtures.d3dmetalPack], frameworks: "frameworks")
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",   // the pack's manifest overrides are ignored under strategy C (decision 39)
            "WINEMSYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH_PREPEND": "/ossover-test/renderers/d3dmetal-3.0/wine",
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": Self.libd3dshared,
            "CX_ACTIVE_GRAPHICS_BACKEND": "d3dmetal",
        ])
        #expect(env.keys.filter { $0.hasPrefix("DYLD_") }.isEmpty, "REA L-54: CrossOver never sets DYLD_*; dyld ignores it under hardened runtime")
    }

    @Test("H2: d3dmetal × msync × C with dlssMetalFX: D3DM_ENABLE_METALFX=1 and never the DXMT spelling (REA L-58)")
    func d3dmetalWithMetalFX() throws {
        let env = try environment(capabilities: Fixtures.crossOverPrepend,
                                  settings: BottleSettings(sync: .msync, renderer: .d3dmetal, dlssMetalFX: true),
                                  packs: [Fixtures.d3dmetalPack], frameworks: "frameworks")
        #expect(env == [
            "WINEPREFIX": Self.prefix,
            "WINESERVER": Self.wineserver,
            "WINELOADER": Self.wineloader,
            "WINEDEBUG": "fixme-all",
            "LC_ALL": "en_US.UTF-8",   // ossover-specific (REA L-14)
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "WINEMSYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
            "GST_PLUGIN_SYSTEM_PATH": Self.gstPlugins,
            "GST_REGISTRY": Self.gstRegistry,
            "WINEDLLPATH_PREPEND": "/ossover-test/renderers/d3dmetal-3.0/wine",
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": Self.libd3dshared,
            "CX_ACTIVE_GRAPHICS_BACKEND": "d3dmetal",
            "D3DM_ENABLE_METALFX": "1",   // a D3DMetal string (REA L-58); its effect is unverified (U-12)
        ])
        #expect(env["DXMT_ENABLE_NVEXT"] == nil, "DXMT_ENABLE_NVEXT is a string of the DXMT DLLs alone (REA L-59)")
    }

    @Test("J: an accepted GPTK pack is exported for every process of a CX-derived bottle, whatever the renderer")
    func gptkRowIsRendererIndependent() throws {
        let wined3d = try environment(capabilities: Fixtures.crossOver, settings: BottleSettings(sync: .msync, renderer: .wined3d),
                                      packs: [], gptkPack: Self.gptkRoot)
        #expect(wined3d["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == Self.libd3dshared)
        #expect(wined3d["CX_ACTIVE_GRAPHICS_BACKEND"] == "wined3d")
        let dxmt = try environment(capabilities: Fixtures.crossOver, settings: BottleSettings(sync: .msync, renderer: .dxmt),
                                   packs: [Fixtures.dxmtPack], gptkPack: Self.gptkRoot)
        #expect(dxmt["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == Self.libd3dshared)
        #expect(dxmt["CX_ACTIVE_GRAPHICS_BACKEND"] == "dxmt")
        let tool = try environment(capabilities: Fixtures.crossOver, settings: BottleSettings(sync: .none, renderer: .wined3d),
                                   packs: [], gptkPack: nil)
        #expect(tool["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil, "nil = no accepted pack")
        let vanilla = try environment(capabilities: Fixtures.vanillaEsyncMacdrv, settings: BottleSettings(sync: .none, renderer: .wined3d),
                                      packs: [], gptkPack: Self.gptkRoot)
        #expect(vanilla["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil, "only a CX-derived engine has the loader hook")
        #expect(vanilla["CX_ACTIVE_GRAPHICS_BACKEND"] == nil)
        // A d3dmetal selection with an explicit (other) pack: the explicit one wins, as the caller resolved it.
        let other = URL(fileURLWithPath: "/ossover-test/renderers/d3dmetal-3.1", isDirectory: true)
        let explicit = try environment(capabilities: Fixtures.crossOverPrepend, settings: BottleSettings(sync: .msync, renderer: .d3dmetal),
                                       packs: [Fixtures.d3dmetalPack], gptkPack: other)
        #expect(explicit["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == "/ossover-test/renderers/d3dmetal-3.1/external/libd3dshared.dylib")
    }

    @Test("K: PYTHONPATH never reaches Wine, from any layer (REA L-05); WINEDLLOVERRIDES is not wiped")
    func pythonPathIsStripped() throws {
        let settings = BottleSettings(sync: .msync, renderer: .wined3d, dllOverrides: ["version=n,b"],
                                      env: ["PYTHONPATH": "/Users/h/py", "PYTHONPATH+": "/opt/py"])
        let program = Program(id: "game", name: "Game", exe: #"C:\Games\game.exe"#, env: ["PYTHONPATH": "/game/py"])
        let env = try environment(capabilities: Fixtures.crossOver, settings: settings, packs: [], program: program,
                                  extra: ["PYTHONPATH": "/extra/py", "KEEP": "1"], baseEnv: ["PYTHONPATH": "${engine}/py"])
        #expect(env["PYTHONPATH"] == nil)
        #expect(env["KEEP"] == "1")
        #expect(env["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;version=n,b", "the bottle's dllOverrides survive")
        #expect(WineEnvironment.strippedKeys == ["PYTHONPATH"])
    }

    @Test("L: the log header carries the fixed WINESERVER/WINELOADER rows and never a bottle secret")
    func headerShowsFixedRows() throws {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        let bottle = Bottle(name: "golden", engineID: engine.id, settings: BottleSettings(env: ["STEAM_TOKEN": "secret"]))
        let env = WineEnvironment.make(engine: engine, bottle: bottle, layout: Fixtures.paths.bottleLayout("golden"),
                                       program: nil, renderer: .wined3d)
        let header = WineRunner.header(engine: engine, bottle: bottle, program: "p", renderer: .wined3d, env: env, command: "wine p.exe")
        #expect(header.contains("# WINESERVER=\(Self.wineserver)\n"))
        #expect(header.contains("# WINELOADER=\(Self.wineloader)\n"))
        #expect(header.contains("# WINEMSYNC=1\n"))
        #expect(!header.contains("WINEESYNC"))
        #expect(!header.contains("secret"))
    }
}

@Suite struct WineEnvironmentHelperTests {
    @Test func effectiveSyncDegradesOnlyWhenMissing() {
        #expect(WineEnvironment.effectiveSync(.msync, capabilities: Fixtures.crossOver) == .msync)
        #expect(WineEnvironment.effectiveSync(.msync, capabilities: Fixtures.vanillaEsync) == .esync)
        #expect(WineEnvironment.effectiveSync(.msync, capabilities: EngineCapabilities()) == .none)
        #expect(WineEnvironment.effectiveSync(.esync, capabilities: Fixtures.crossOver) == .none)
        #expect(WineEnvironment.effectiveSync(.none, capabilities: Fixtures.crossOver) == .none)
    }

    @Test("sync rows: WINEMSYNC alone without esync (REA L-32), both rows explicit with it")
    func syncVariablesFollowTheEngine() {
        #expect(WineEnvironment.syncVariables(.none, capabilities: Fixtures.crossOver) == ["WINEMSYNC": "0"])
        #expect(WineEnvironment.syncVariables(.msync, capabilities: Fixtures.crossOver) == ["WINEMSYNC": "1"])
        #expect(WineEnvironment.syncVariables(.esync, capabilities: Fixtures.crossOver) == ["WINEMSYNC": "0"], "esync cannot be effective there; still no WINEESYNC row")
        #expect(WineEnvironment.syncVariables(.none, capabilities: EngineCapabilities()) == ["WINEMSYNC": "0"])
        #expect(WineEnvironment.syncVariables(.none, capabilities: Fixtures.vanillaEsync) == ["WINEMSYNC": "0", "WINEESYNC": "0"])
        #expect(WineEnvironment.syncVariables(.esync, capabilities: Fixtures.vanillaEsync) == ["WINEMSYNC": "0", "WINEESYNC": "1"])
        #expect(WineEnvironment.syncVariables(.msync, capabilities: Fixtures.vanillaEsync) == ["WINEMSYNC": "1", "WINEESYNC": "0"])
        #expect(WineEnvironment.winemsyncValue(.msync, capabilities: Fixtures.crossOver) == "1")
        #expect(WineEnvironment.winemsyncValue(.msync, capabilities: Fixtures.vanillaEsync) == "0", "degraded to esync")
        #expect(WineEnvironment.winemsyncValue(.none, capabilities: Fixtures.crossOver) == "0")
    }

    @Test("decision 20: msync by default where the engine has it, none elsewhere")
    func defaultSyncFollowsTheEngine() {
        #expect(BottleSettings.defaultSync(for: Fixtures.crossOver) == .msync)
        #expect(BottleSettings.defaultSync(for: Fixtures.crossOverPrepend) == .msync)
        #expect(BottleSettings.defaultSync(for: Fixtures.vanillaEsync) == .none, "esync is not promoted")
        #expect(BottleSettings.defaultSync(for: EngineCapabilities()) == .none)
        #expect(BottleSettings().sync == .msync, "the model's own default stays msync")
        #expect(BottleSettings.msyncWarning.contains("MSync"))
    }

    @Test func mergeAppendsWithPlusAndSkipsDuplicates() {
        var env = ["WINEDLLPATH": "/a", "WINEDLLOVERRIDES": "x=n"]
        WineEnvironment.merge(&env, ["WINEDLLPATH+": "/b", "WINEDLLOVERRIDES+": "y=b;x=n", "NEW": "1"])
        #expect(env == ["WINEDLLPATH": "/a:/b", "WINEDLLOVERRIDES": "x=n;y=b", "NEW": "1"])
        WineEnvironment.merge(&env, ["WINEDLLOVERRIDES": "z=d", "WINEDLLPATH": "/c"])
        #expect(env == ["WINEDLLPATH": "/c", "WINEDLLOVERRIDES": "x=n;y=b;z=d", "NEW": "1"], "a plain WINEDLLOVERRIDES appends; other plain keys replace")
        #expect(WineEnvironment.append(nil, "/only", separator: ":") == "/only")
        #expect(WineEnvironment.append("/a:/b", "/a", separator: ":") == "/a:/b")
    }

    @Test func joinOverridesDropsEmptiesAndDuplicates() {
        #expect(WineEnvironment.joinOverrides(["a=n", "", "b=b; a=n", "c="]) == "a=n;b=b;c=")
    }

    @Test func linesAreSortedKeyValuePairs() {
        #expect(WineEnvironment.lines(["B": "2", "A": "1"]) == ["A=1", "B=2"])
    }

    @Test func rosettaRowFollowsTheEngineRequirement() throws {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver, requires: [])
        let bottle = Bottle(name: "golden", engineID: engine.id)
        let env = WineEnvironment.make(engine: engine, bottle: bottle, layout: Fixtures.paths.bottleLayout("golden"),
                                       program: nil, renderer: .wined3d)
        #expect(env["ROSETTA_ADVERTISE_AVX"] == nil)
    }

    @Test("REA L-06: ROSETTA_ADVERTISE_AVX is 1 or absent whatever a later layer says; a 0 never reaches Wine")
    func rosettaRowIsNeverZero() {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        let layout = Fixtures.paths.bottleLayout("golden")
        func row(_ settings: BottleSettings, program: Program? = nil, extra: [String: String] = [:]) -> String? {
            WineEnvironment.make(engine: engine, bottle: Bottle(name: "golden", engineID: engine.id, settings: settings),
                                 layout: layout, program: program, renderer: .wined3d, extra: extra)["ROSETTA_ADVERTISE_AVX"]
        }
        // The setting says on, the bottle env says 0: Rosetta would read the 0 as on, so the row goes.
        #expect(row(BottleSettings(env: ["ROSETTA_ADVERTISE_AVX": "0"])) == nil)
        #expect(row(BottleSettings(advertiseAVX: false, env: ["ROSETTA_ADVERTISE_AVX": "0"])) == nil)
        #expect(row(BottleSettings(env: ["ROSETTA_ADVERTISE_AVX": ""])) == nil)
        let program = Program(id: "game", name: "Game", exe: #"C:\Games\game.exe"#, env: ["ROSETTA_ADVERTISE_AVX": "0"])
        #expect(row(BottleSettings(), program: program) == nil)
        #expect(row(BottleSettings(), extra: ["ROSETTA_ADVERTISE_AVX": "0"]) == nil)
        // A 1 from a later layer, or the setting alone, keeps the row.
        #expect(row(BottleSettings(advertiseAVX: false, env: ["ROSETTA_ADVERTISE_AVX": "1"])) == "1")
        #expect(row(BottleSettings()) == "1")
        #expect(row(BottleSettings(advertiseAVX: false)) == nil)
    }

    @Test("GStreamer rows: engine plugins, per-engine registry under <home>/cache, baseEnv wins")
    func gstreamerRowsArePerEngine() {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        let layout = Fixtures.paths.bottleLayout("golden")
        let rows = WineEnvironment.gstreamerVariables(engine: engine, layout: layout, baseEnv: [:])
        #expect(rows == ["GST_PLUGIN_SYSTEM_PATH": WineEnvironmentGoldenTests.gstPlugins,
                         "GST_REGISTRY": WineEnvironmentGoldenTests.gstRegistry])
        let other = Fixtures.engine(id: "other-engine", capabilities: Fixtures.crossOver)
        #expect(WineEnvironment.gstreamerVariables(engine: other, layout: layout, baseEnv: [:])["GST_REGISTRY"]
                == "/ossover-test/cache/gstreamer-registry-other-engine.x86_64.bin")
        #expect(WineEnvironment.gstreamerVariables(engine: engine, layout: layout, baseEnv: ["GST_REGISTRY": "/x"]).keys.contains("GST_REGISTRY") == false)
        #expect(OssoverPaths(containing: layout) == Fixtures.paths)
        #expect(Fixtures.paths.allDirectories.contains(Fixtures.paths.cache))
        #expect(Fixtures.paths.gstreamerRegistry(for: engine).path == WineEnvironmentGoldenTests.gstRegistry)
    }

    @Test func explicitRendererWithoutPackIsMissing() {
        let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
        #expect(throws: OssoverError.self) {
            try RendererResolver.resolve(choice: .dxvk, engine: engine, packs: [Fixtures.dxmtPack])
        }
        let auto = try? RendererResolver.resolve(choice: .auto, engine: engine, packs: [Fixtures.dxvkPack])
        #expect(auto?.kind == .dxvk)
        let fallback = try? RendererResolver.resolve(choice: .auto, engine: engine, packs: [])
        #expect(fallback?.kind == .wined3d)
        #expect(fallback?.strategy == OverlayStrategy.none)
    }
}

/// Decision 19 (REA L-30, L-31): one `WINEMSYNC` per wineserver lifetime.
@Suite struct WineServerSyncTests {
    static let layout = Fixtures.paths.bottleLayout("w")
    static let env = " WINEPREFIX=/ossover-test/bottles/w/prefix HOME=/Users/h"

    @Test("WINEMSYNC is read like atoi: unset, empty, 0 and text are off")
    func msyncParsing() {
        #expect(!WineServer.msyncEnabled(nil))
        #expect(!WineServer.msyncEnabled(""))
        #expect(!WineServer.msyncEnabled("0"))
        #expect(!WineServer.msyncEnabled("abc"))
        #expect(!WineServer.msyncEnabled(" 0 "))
        #expect(WineServer.msyncEnabled("1"))
        #expect(WineServer.msyncEnabled(" 2"))
        #expect(WineServer.msyncEnabled("1abc"))
        #expect(WineServer.msyncEnabled("-1"))
    }

    @Test("the prefix's wineserver is found by executable name among its processes")
    func serverEntries() {
        let entries = [
            ProcessEntry(pid: 10, command: "-zsh" + Self.env),
            ProcessEntry(pid: 12, command: "/ossover-test/engines/e/wine/bin/wineserver" + Self.env),
            ProcessEntry(pid: 13, command: "/ossover-test/engines/e/wine/lib/wine/x86_64-unix/wine C:\\Games\\x.exe" + Self.env),
            ProcessEntry(pid: 14, command: "wineserver -p" + Self.env),
            ProcessEntry(pid: 15, command: "/ossover-test/engines/e/wine/bin/wineserver WINEPREFIX=/ossover-test/bottles/wb/prefix"),
        ]
        #expect(WineServer.serverEntries(entries, layout: Self.layout).map(\.pid) == [12, 14])
        #expect(WineServer.isWineserver(ProcessEntry(pid: 1, command: "wineserver")))
        #expect(!WineServer.isWineserver(ProcessEntry(pid: 1, command: "/x/wine notepad.exe")))
        #expect(!WineServer.isWineserver(ProcessEntry(pid: 1, command: "-zsh WINESERVER=/x/wineserver")))
    }

    @Test("compare: live environment first, then the record, then unknown")
    func compare() {
        let state = WineServer.SyncState(sync: .none, winemsync: "0", engineID: "e")
        #expect(WineServer.compareSync(wanted: "1", server: nil, recorded: state) == .noServer)
        #expect(WineServer.compareSync(wanted: "1", server: .init(pid: 5, environment: ["WINEMSYNC": "1"]), recorded: state) == .matches(pid: 5))
        #expect(WineServer.compareSync(wanted: "0", server: .init(pid: 5, environment: ["WINEPREFIX": "/p"]), recorded: nil) == .matches(pid: 5),
                "an unset WINEMSYNC in the server is off (REA L-30)")
        #expect(WineServer.compareSync(wanted: "1", server: .init(pid: 5, environment: ["WINEPREFIX": "/p"]), recorded: nil)
                == .mismatch(pid: 5, server: nil, wanted: "1"))
        #expect(WineServer.compareSync(wanted: "0", server: .init(pid: 5, environment: ["WINEMSYNC": "1"]), recorded: state)
                == .mismatch(pid: 5, server: "1", wanted: "0"), "the live environment wins over a stale record")
        #expect(WineServer.compareSync(wanted: "0", server: .init(pid: 5, environment: nil), recorded: state) == .matches(pid: 5))
        #expect(WineServer.compareSync(wanted: "1", server: .init(pid: 5, environment: nil), recorded: state)
                == .mismatch(pid: 5, server: "0", wanted: "1"))
        #expect(WineServer.compareSync(wanted: "1", server: .init(pid: 5, environment: nil), recorded: nil) == .unknown(pid: 5))
        #expect(WineServer.SyncCheck.mismatch(pid: 5, server: nil, wanted: "1").summary.contains("WINEMSYNC=unset"))
    }

    @Test("the sync-state record round-trips, is rewritten only when the lifetime changes, and goes with the server")
    func record() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = OssoverPaths(home: home).bottleLayout("b")
        try layout.ensureDirectories()
        #expect(WineServer.syncState(layout: layout) == nil)
        let first = WineServer.SyncState(sync: .msync, winemsync: "1", engineID: "e", startedAt: Date(timeIntervalSince1970: 1_000))
        try WineServer.recordSyncState(first, layout: layout)
        #expect(WineServer.syncStateURL(layout: layout).lastPathComponent == ".sync-state.json")
        #expect(WineServer.syncState(layout: layout) == first)
        let again = WineServer.SyncState(sync: .msync, winemsync: "1", engineID: "e", startedAt: Date(timeIntervalSince1970: 2_000))
        try WineServer.recordSyncState(again, layout: layout)
        #expect(WineServer.syncState(layout: layout) == first, "same lifetime: the first start time stays")
        let changed = WineServer.SyncState(sync: .none, winemsync: "0", engineID: "e", startedAt: Date(timeIntervalSince1970: 3_000))
        try WineServer.recordSyncState(changed, layout: layout)
        #expect(WineServer.syncState(layout: layout) == changed)
        let text = try String(contentsOf: WineServer.syncStateURL(layout: layout), encoding: .utf8)
        #expect(text.contains("\"schema\" : \"ossover.sync-state/1\"") && text.contains("\"winemsync\" : \"0\"") && text.contains("\"engineId\" : \"e\""))
        WineServer.clearSyncState(layout: layout)
        #expect(WineServer.syncState(layout: layout) == nil)
    }
}
