// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Bottle.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (sync variables, `KEY+` merge, renderer env rows)
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors (settings → env mapping)

import Foundation

/// The environment a Wine process in a bottle starts with: plan §4 "Env table", assembled by a
/// pure function so it can be golden-tested per renderer × sync × strategy. Nothing here reads
/// the filesystem or the parent environment; `Shell` adds PATH/HOME when it spawns.
///
/// Every row is justified by `docs/rea/decisions.md` 1–11; a `REA L-nn` comment cites the
/// `docs/rea/ledger.md` row it rests on.
public enum WineEnvironment {
    /// REA L-09: CrossOver's own default is `-all`; ossover keeps fixmes, the bench passes `-all`
    /// and renderer verification adds `+loaddll`.
    public static let defaultDebug = "fixme-all"
    /// ossover-specific (REA L-14): CrossOver never sets a global `LC_ALL`; it sets one per app
    /// through `HKCU\Software\Wine\LC_ALL` under a locale condition, the pattern recipes should
    /// use for per-app locales.
    public static let locale = "en_US.UTF-8"
    /// Wine's menu builder writes .lnk files and app bundles onto the macOS Desktop; off always.
    public static let menuBuilderOverride = "winemenubuilder.exe=d"
    public static let dxmtLogLevel = "info"
    /// Keys never handed to Wine, whichever layer carries them (REA L-05): CrossOver's launcher
    /// deletes `PYTHONPATH` unconditionally so a host Python setup cannot trickle down. Its wipe
    /// of `WINEDLLOVERRIDES`/`CX_WINDOWS_VERSION` is a launcher artefact and is **not** copied:
    /// the bottle's `dllOverrides` must survive.
    public static let strippedKeys: Set<String> = ["PYTHONPATH"]
    public static let msyncKey = "WINEMSYNC"
    public static let esyncKey = "WINEESYNC"
    /// What `CX_APPLEGPTK_LIBD3DSHARED_PATH` names inside a GPTK pack: `external/libd3dshared.dylib`.
    public static let libd3dsharedRelativePath = "external/libd3dshared.dylib"

    /// Builds the whole table. Merge order (REA L-03, compatible with CrossOver's global < user <
    /// bottle < launcher < `--env` precedence): engine `baseEnv` (`${engine}` expanded) → fixed
    /// rows → bottle env → program env → `extra`; a key ending in `+` appends to the existing value
    /// with `:` (`;` for `WINEDLLOVERRIDES`). `WINEDLLOVERRIDES` itself is append-only at every
    /// layer: a plain key in `baseEnv`, the bottle's env, a program's env or `extra` adds its
    /// fragments after `winemenubuilder.exe=d` and the renderer's, never replaces them (a
    /// replaced string would silently drop the `n,b` a strategy-B overlay needs).
    ///
    /// `gptkPack` is the accepted GPTK (D3DMetal) pack's root, nil when none is installed
    /// (`WineRunner.gptkPack(paths:)`); it drives `CX_APPLEGPTK_LIBD3DSHARED_PATH` for every
    /// process of the bottle whatever the renderer. A d3dmetal selection supplies its own pack
    /// when the caller passes nil. `strippedKeys` are removed last. Deterministic for the same inputs.
    public static func make(engine: Engine, bottle: Bottle, layout: BottleLayout, program: Program?,
                            renderer: RendererSelection, gptkPack: URL? = nil, extra: [String: String] = [:]) -> [String: String] {
        let settings = bottle.settings
        var env = expandEngineVariables(engine.manifest.baseEnv, engine: engine)

        env["WINEPREFIX"] = layout.prefix.path
        // REA L-10, L-50: CrossOver exports both. Without them Wine derives bin_dir from dll_dir and
        // the loader exports WINELOADER itself, which a relocated or symlinked engine may get wrong;
        // fixed rows also keep the allowlisted log header deterministic.
        env["WINESERVER"] = engine.wineserver.path
        env["WINELOADER"] = engine.wine.path
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = defaultDebug }
        env["LC_ALL"] = locale   // ossover-specific, REA L-14
        env["WINEDLLOVERRIDES"] = overridesString(renderer: renderer, settings: settings, baseEnv: env)
        merge(&env, syncVariables(effectiveSync(settings.sync, capabilities: engine.capabilities), capabilities: engine.capabilities))
        // REA L-06: `1` or absent, never `0` — Rosetta treats any value as on, so CrossOver deletes a
        // pre-set `0` instead of exporting it.
        if settings.advertiseAVX, engine.manifest.requiresRosetta { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        // REA L-07: the CrossOver launcher's "Fix for .NET 7/8 apps under Rosetta"; always.
        env["DOTNET_EnableWriteXorExecute"] = "0"
        merge(&env, gstreamerVariables(engine: engine, layout: layout, baseEnv: env))
        // REA L-58: MTL_HUD_ENABLED is a D3DMetal string too, so the HUD rows hold for every renderer.
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.metalHUDLog { env["MTL_HUD_LOG_ENABLED"] = "1" }
        merge(&env, rendererVariables(renderer, engine: engine, layout: layout, settings: settings))
        merge(&env, gptkVariables(pack: gptkPack ?? (renderer.kind == .d3dmetal ? renderer.pack?.root : nil), engine: engine))
        // CX_ROOT stays unset (REA L-15, U-11): winemac.so reads it for icon lookup and localspl for
        // printing; the effect of leaving it unset is unknown and no visible defect has appeared, so
        // the row is not emulated until one does.

        merge(&env, settings.env)
        if let program { merge(&env, program.env) }
        merge(&env, extra)
        // REA L-06 (ordered last, as L-03's launcher normalisation is): Rosetta treats any value as
        // on, so a `0` from the bottle env, a program env or `--env` would advertise AVX while the
        // table reads off. CrossOver deletes a pre-set `0`/empty value; ossover deletes anything
        // but `1`, so the row is exactly `1` or absent.
        if let value = env["ROSETTA_ADVERTISE_AVX"], value != "1" { env["ROSETTA_ADVERTISE_AVX"] = nil }
        for key in strippedKeys { env[key] = nil }
        return env
    }

    /// `make` for a bottle under `paths` (the layout is derived from the bottle's name).
    public static func make(engine: Engine, bottle: Bottle, program: Program?, renderer: RendererSelection,
                            gptkPack: URL? = nil, extra: [String: String] = [:], paths: OssoverPaths = OssoverPaths()) -> [String: String] {
        make(engine: engine, bottle: bottle, layout: paths.bottleLayout(bottle.name), program: program, renderer: renderer,
             gptkPack: gptkPack, extra: extra)
    }

    // MARK: Rows

    /// `baseEnv` with `${engine}` replaced by the engine directory.
    public static func expandEngineVariables(_ baseEnv: [String: String], engine: Engine) -> [String: String] {
        baseEnv.mapValues { $0.replacingOccurrences(of: "${engine}", with: engine.root.path) }
    }

    /// The mode a launch really gets: msync and esync only where the engine has them. Wine
    /// ignores an unknown variable, but a bottle must not claim a sync it is not getting.
    public static func effectiveSync(_ wanted: SyncMode, capabilities: EngineCapabilities) -> SyncMode {
        switch wanted {
        case .msync where !capabilities.msync: return capabilities.esync ? .esync : .none
        case .esync where !capabilities.esync: return .none
        default: return wanted
        }
    }

    /// The sync rows the engine can read (REA L-30, L-32). On an engine without esync (every
    /// CrossOver-derived tree: esync is not compiled into 26.3.0, `WINEESYNC` is a dead variable
    /// there) only `WINEMSYNC=1|0` is emitted and no `WINEESYNC` row at all — CrossOver sets
    /// `WINEMSYNC` alone, never the Whisky "both =1" pair. `WINEMSYNC=0` for `none` equals unset
    /// (ntdll's `do_msync` is `getenv && atoi`, compiled-in default off) and documents intent. An
    /// engine with esync gets both rows, explicit.
    public static func syncVariables(_ mode: SyncMode, capabilities: EngineCapabilities) -> [String: String] {
        guard capabilities.esync else { return [msyncKey: mode == .msync ? "1" : "0"] }
        switch mode {
        case .none: return [msyncKey: "0", esyncKey: "0"]
        case .esync: return [msyncKey: "0", esyncKey: "1"]
        case .msync: return [msyncKey: "1", esyncKey: "0"]
        }
    }

    /// The `WINEMSYNC` value every process of a launch gets ("1" or "0") for the bottle's wanted
    /// mode on `capabilities`; what `WineServer` compares against a live server's (decision 19).
    public static func winemsyncValue(_ wanted: SyncMode, capabilities: EngineCapabilities) -> String {
        syncVariables(effectiveSync(wanted, capabilities: capabilities), capabilities: capabilities)[msyncKey] ?? "0"
    }

    /// `winemenubuilder.exe=d` first, then whatever the engine's `baseEnv` carries, the
    /// renderer's fragments, then the bottle's own, so a later (user) entry wins in Wine's
    /// last-one-wins parse.
    public static func overridesString(renderer: RendererSelection, settings: BottleSettings, baseEnv: [String: String] = [:]) -> String {
        let fromEngine = [baseEnv[overridesKey], baseEnv[overridesKey + "+"]].compactMap { $0 }
        return joinOverrides([menuBuilderOverride] + fromEngine + renderer.overrides + settings.dllOverrides)
    }

    public static let overridesKey = "WINEDLLOVERRIDES"

    /// `GST_PLUGIN_SYSTEM_PATH=<engine>/lib/gstreamer-1.0` and `GST_REGISTRY=<OSSOVER_HOME>/cache/
    /// gstreamer-registry-<engineId>.<arch>.bin` unless `baseEnv` set them (REA L-08). CrossOver
    /// keeps one per-user registry because it has one engine; here the registry is per engine,
    /// because two engines sharing one would poison each other's plugin cache, and it lives in the
    /// home's `cache/` rather than the bottle so `engines/<id>` stays verifiable and a bottle is
    /// not tied to its engine's scan. The home is the one the bottle sits under
    /// (`<home>/bottles/<name>`, `OssoverPaths.init(containing:)`); `WineRunner` creates `cache/`
    /// before a launch.
    public static func gstreamerVariables(engine: Engine, layout: BottleLayout, baseEnv: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        if baseEnv["GST_PLUGIN_SYSTEM_PATH"] == nil { out["GST_PLUGIN_SYSTEM_PATH"] = engine.gstreamerPlugins.path }
        if baseEnv["GST_REGISTRY"] == nil { out["GST_REGISTRY"] = OssoverPaths(containing: layout).gstreamerRegistry(for: engine).path }
        return out
    }

    /// Whether the engine is a CrossOver-derived tree: msync and the D3DMetal loader glue exist
    /// nowhere else. The one definition every CX-only row (`CX_ACTIVE_GRAPHICS_BACKEND`,
    /// `CX_APPLEGPTK_LIBD3DSHARED_PATH`) and `Prefix.userName` go through.
    public static func isCrossOverDerived(_ engine: Engine) -> Bool {
        engine.capabilities.msync || engine.capabilities.d3dmetalHost
    }

    /// `CX_APPLEGPTK_LIBD3DSHARED_PATH=<pack>/external/libd3dshared.dylib` (REA L-53, L-55, L-57):
    /// the absolute path ntdll's `init_non_native_support` reads verbatim (macOS ≥ 14, no
    /// fallback) to register Rosetta non-native code regions. CrossOver exports it for every
    /// process of a bottle whenever the file exists, "regardless of whether D3DMetal is enabled",
    /// so the row is independent of the selected renderer: `pack` is the accepted GPTK pack's
    /// root, nil when none is installed. Only a CX-derived engine carries the hook. No `DYLD_*`
    /// rows go with it (REA L-54): CrossOver never sets them, its hardened-runtime loaders lack
    /// the dyld entitlement so dyld would ignore them, and `libd3dshared.dylib` finds
    /// `D3DMetal.framework` through its own `LC_RPATH @loader_path`.
    public static func gptkVariables(pack: URL?, engine: Engine) -> [String: String] {
        guard let pack, isCrossOverDerived(engine) else { return [:] }
        return ["CX_APPLEGPTK_LIBD3DSHARED_PATH": pack.appending(path: libd3dsharedRelativePath).path]
    }

    /// The rows a renderer selection contributes (`KEY+` keys append).
    public static func rendererVariables(_ renderer: RendererSelection, engine: Engine, layout: BottleLayout,
                                         settings: BottleSettings) -> [String: String] {
        var out: [String: String] = [:]
        if let dllPath = renderer.dllPath {
            switch renderer.strategy {
            case .prefixCopy: out["WINEDLLPATH+"] = dllPath.path
            case .prepend: out["WINEDLLPATH_PREPEND+"] = dllPath.path
            case .none: break
            }
        }
        let logDir = WindowsPath.toWindows(layout.logs, prefix: layout.prefix)
        switch renderer.kind {
        case .dxmt:
            // REA L-59: DXMT_LOG_PATH, DXMT_LOG_LEVEL, DXMT_CONFIG and DXMT_ENABLE_NVEXT are strings in
            // the DXMT PE DLLs (d3d11.dll, dxgi.dll); winemetal.so reads none, so they belong in the
            // Wine process env exactly like this. `<exe>_d3d11.log` beside the Wine logs is the one
            // artifact that says DXMT served a process.
            out["DXMT_LOG_PATH"] = logDir
            out["DXMT_LOG_LEVEL"] = dxmtLogLevel
            // DXMT_CONFIG (`d3d11.preferredMaxFrameRate=N;`, never in bench) and
            // DXMT_METALFX_SPATIAL_SWAPCHAIN come from the bottle's or program's env.
            if settings.dlssMetalFX { out["DXMT_ENABLE_NVEXT"] = "1" }
        case .dxvk:
            out["DXVK_LOG_PATH"] = logDir
            // DXVK_ASYNC / DXVK_HUD are opt-in through the bottle's env (async skips draws; see highball).
        case .d3dmetal:
            // Activation (REA L-55) is the overlay prepended (strategy C) + CX_ACTIVE_GRAPHICS_BACKEND
            // below + CX_APPLEGPTK_LIBD3DSHARED_PATH (`gptkVariables`, from this selection's pack when
            // the caller passed none); nothing else is required by evidence.
            // REA L-58: D3DM_ENABLE_METALFX is a D3DMetal string; its effect is unverified (U-12).
            if settings.dlssMetalFX { out["D3DM_ENABLE_METALFX"] = "1" }
            // D3DM_SUPPORT_DXR is opt-in through the bottle's env.
        case .wined3d:
            break
        }
        if isCrossOverDerived(engine) {
            // REA L-17, L-18, L-19: read by win32u (`vulkan.c`: `wined3d` gates CX_LIBVULKAN;
            // `d3dkmt.c`: `d3dmetal` flips the WDDM 2.7 HwSch caps); the values are exactly
            // wined3d|dxvk|dxmt|d3dmetal, the literals in cxcompatdb.so. CX_GRAPHICS_BACKEND — the
            // bottle *setting* CrossOver's cxcompatdb.so reads — is not emulated: nothing in Wine reads
            // it; the ossover `renderer` setting drives the overlay instead.
            out["CX_ACTIVE_GRAPHICS_BACKEND"] = renderer.kind.rawValue
        }
        return out
    }

    // MARK: Merge

    /// Applies `add` to `env`: a plain key replaces, `KEY+` appends to `KEY` with `:` (`;` for
    /// `WINEDLLOVERRIDES`), skipping a value already present. A plain `WINEDLLOVERRIDES` is
    /// treated as `WINEDLLOVERRIDES+`: its fragments are appended, never replacing the composed
    /// string (see `make`).
    public static func merge(_ env: inout [String: String], _ add: [String: String]) {
        for key in add.keys.sorted() {
            guard let value = add[key] else { continue }
            if key.hasSuffix("+") || key == overridesKey {
                let base = key.hasSuffix("+") ? String(key.dropLast()) : key
                env[base] = append(env[base], value, separator: base == overridesKey ? ";" : ":")
            } else {
                env[key] = value
            }
        }
    }

    /// `existing<sep>value`, without duplicates or empty parts.
    public static func append(_ existing: String?, _ value: String, separator: Character) -> String {
        let parts = ((existing ?? "") + String(separator) + value).split(separator: separator).map(String.init).filter { !$0.isEmpty }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: String(separator))
    }

    /// Joins `WINEDLLOVERRIDES` fragments with `;`, dropping empties and duplicates.
    public static func joinOverrides(_ fragments: [String]) -> String {
        var seen = Set<String>()
        return fragments.flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ";")
    }

    // MARK: Output

    /// `KEY=value` lines sorted by key: the golden-test and log-header form.
    public static func lines(_ env: [String: String]) -> [String] {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }
}
