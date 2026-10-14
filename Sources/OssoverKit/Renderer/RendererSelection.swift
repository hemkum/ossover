// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Bottle.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
// (renderer availability, fallback order and the strategy split).

import Foundation

/// How a renderer's files are put in front of Wine's own Direct3D (plan §4, "Renderer overlay").
public enum OverlayStrategy: String, Codable, Sendable, Equatable {
    /// Nothing to place: wined3d is the engine's own.
    case none
    /// Strategy B: the pack's Direct3D DLLs (`d3d11`, `dxgi`, `d3d10core`, …) are copied into
    /// the prefix's `system32`/`syswow64` with the builtin mark stripped; `WINEDLLPATH` names
    /// the pack so a `winemetal.{dll,so}` pair the engine's own `lib/wine` lacks can still
    /// resolve (`WINEDLLPATH` can never shadow a name `lib/wine` ships: `dll_paths[0]` is
    /// always `dll_dir`, REA L-20). For engines whose ntdll knows only `WINEDLLPATH` (the
    /// bootstrap engine); a bootstrap-only compromise, fully revertible (REA L-26).
    case prefixCopy
    /// Strategy C: `WINEDLLPATH_PREPEND=<overlay>`; the prefix is never touched. For engines
    /// carrying highball patch 0003 (`EngineCapabilities.dllPathPrepend`): the open equivalent
    /// of what CrossOver gets from `prepend_dll_path()` called by `cxcompatdb.so`, and the only
    /// prefix-neutral mechanism (REA L-20, L-21, L-26). The only strategy D3DMetal can use.
    case prepend

    /// The plan's letter for log headers.
    public var letter: String {
        switch self {
        case .none: return "-"
        case .prefixCopy: return "B"
        case .prepend: return "C"
        }
    }
}

/// A resolved renderer for one launch: what was asked, what was picked, where its files are and
/// how they reach Wine. Built by `RendererResolver`; consumed by `WineEnvironment` (pure) and
/// `RendererMaterializer` (files).
public struct RendererSelection: Sendable, Equatable {
    /// What the bottle (or caller) asked for.
    public let choice: RendererChoice
    /// What was picked.
    public let kind: RendererKind
    /// The pack the files come from; nil for wined3d.
    public let pack: RendererPack?
    /// The directory holding `x86_64-unix/` and `x86_64-windows/` (`<pack>/wine` or an engine
    /// overlay); what `WINEDLLPATH` (B) or `WINEDLLPATH_PREPEND` (C) names. Nil for wined3d.
    public let dllPath: URL?
    public let strategy: OverlayStrategy
    /// Set when `kind` differs from what was asked (auto, or a fallback), for the log header.
    public let note: String?

    public init(choice: RendererChoice, kind: RendererKind, pack: RendererPack?, dllPath: URL?,
                strategy: OverlayStrategy, note: String? = nil) {
        self.choice = choice
        self.kind = kind
        self.pack = pack
        self.dllPath = dllPath
        self.strategy = strategy
        self.note = note
    }

    /// Wine's own Direct3D: nothing placed, no renderer env. What tools (`wineboot`, `reg`,
    /// `winecfg`) run with.
    public static let wined3d = RendererSelection(choice: .wined3d, kind: .wined3d, pack: nil, dllPath: nil, strategy: .none)

    /// `<pack>/external`, for a D3DMetal pack.
    public var externalDir: URL? { kind == .d3dmetal ? pack?.externalDir : nil }

    /// `WINEDLLOVERRIDES` fragments, only under strategy B (`.prefixCopy`): the pack's own, else
    /// the kind's defaults. The `n,b` override exists for the mark-stripped copies in `system32`
    /// (a native file there needs `n` first: `load_builtin` → `LO_NATIVE_BUILTIN`). Under
    /// strategy C the builtin-marked overlay wins by DLL path and CrossOver itself uses no
    /// renderer override for any backend — the Perl launcher deletes `WINEDLLOVERRIDES` and the
    /// DXVK tie sets only `CX_GRAPHICS_BACKEND` — so nothing is emitted (REA L-05, L-20, L-26;
    /// decision 39). Nothing for wined3d either.
    public var overrides: [String] {
        guard strategy == .prefixCopy else { return [] }
        if let pack, !pack.manifest.overrides.isEmpty { return pack.manifest.overrides }
        return RendererResolver.defaultOverrides(kind)
    }

    /// "dxmt (pack dxmt-0.80, strategy B)" for log headers.
    public var summary: String {
        var out = kind.rawValue
        if let pack { out += " (pack \(pack.id), strategy \(strategy.letter))" }
        return out
    }
}

/// Maps a bottle's `RendererChoice` onto a `RendererSelection` given the engine and the packs
/// on disk. The planning functions are pure; `installedPacks` and `bundledPacks` touch the
/// filesystem so the CLI and tests can hand `resolve` whatever set they like.
public enum RendererResolver {
    /// The order `auto` tries: DXMT first (the plan's default), DXVK, then Wine's own. D3DMetal
    /// is never picked automatically (licence, stretch goal).
    public static let autoOrder: [RendererKind] = [.dxmt, .dxvk, .wined3d]

    /// The pe/unix file names a pack of each kind is expected to carry, used when an engine
    /// bundles a renderer without a pack manifest.
    public static func defaultLayout(_ kind: RendererKind) -> RendererLayout {
        switch kind {
        case .dxmt:
            // DXMT 0.80's asset: x86_64-unix/winemetal.so, x86_64-windows/{d3d10core,d3d11,dxgi,
            // winemetal,nvapi64,nvngx}.dll, i386-windows/{d3d10core,d3d11,dxgi,winemetal}.dll
            // (`renderers/dxmt-0.80.json`; REA L-65, U-13 closed — the same file set as CrossOver's
            // lib/dxmt); a bundle without a layout gets the 64-bit core.
            return RendererLayout(unix: ["winemetal.so"], pe: ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"])
        case .dxvk:
            return RendererLayout(unix: [], pe: ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        case .d3dmetal:
            return RendererLayout(unix: [], pe: ["d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"])
        case .wined3d:
            return RendererLayout()
        }
    }

    /// `WINEDLLOVERRIDES` fragments a kind needs under strategy B when its pack manifest does
    /// not say; `RendererSelection.overrides` applies them only for `.prefixCopy` (decision 39).
    public static func defaultOverrides(_ kind: RendererKind) -> [String] {
        switch kind {
        case .dxmt: return ["dxgi,d3d11,d3d10core=n,b"]
        case .dxvk: return ["dxgi,d3d9,d3d10core,d3d11=n,b"]
        // D3DMetal has no strategy-B form and CrossOver sets no override for it: activation is
        // the prepended overlay plus the CX_* rows alone (REA L-05, L-20, L-26; decisions 14, 39).
        case .d3dmetal: return []
        case .wined3d: return []
        }
    }

    /// Overlay strategy for a kind on an engine (pure).
    public static func strategy(for kind: RendererKind, engine: Engine) -> OverlayStrategy {
        switch kind {
        case .wined3d:
            return .none
        case .d3dmetal:
            // D3DMetal's DLLs are builtin-marked and have to shadow the engine's own d3d11/dxgi/
            // d3d12 by DLL path: `set_dll_path` searches the engine's dll_dir first, so only a
            // prepended path can win (REA L-20). There is no environment-only activation —
            // `CX_APPLEGPTK_LIBD3DSHARED_PATH` only drives Rosetta non-native-region
            // registration, and the fake DLLs of wine.inf are atidxx64/nvapi64/nvngx, not D3D
            // (REA L-53, L-55, L-63) — so `unmet` refuses an engine without `dllPathPrepend`.
            return .prepend
        case .dxmt, .dxvk:
            return engine.capabilities.dllPathPrepend ? .prepend : .prefixCopy
        }
    }

    public static let d3dmetalPrependReason = "D3DMetal needs WINEDLLPATH_PREPEND (engine patch 0003; capability dllPathPrepend)"

    /// Reasons `pack` cannot serve on `engine`; empty when it can. Pure except for the
    /// strategy-B winemetal check (`winemetalCoupling`), which hashes two files when both exist.
    public static func unmet(pack: RendererPack, engine: Engine) -> [String] {
        var reasons = pack.manifest.unmet(by: engine.manifest)
        if pack.kind == .d3dmetal {
            if !engine.capabilities.d3dmetalHost {
                reasons.append("D3DMetal needs an engine with CrossOver's D3DMetal glue (capability d3dmetalHost), which engine \(engine.id) lacks")
            }
            if !engine.capabilities.dllPathPrepend { reasons.append(d3dmetalPrependReason) }
        }
        if let coupling = winemetalCoupling(pack: pack, engine: engine) { reasons.append(coupling) }
        return reasons
    }

    /// Strategy B runs a DXMT pack's `d3d11`/`dxgi`/`d3d10core` against whatever `winemetal.so`
    /// the engine's own `lib/wine` ships (`WINEDLLPATH` can never shadow it: `dll_dir` is
    /// searched first and a builtin pairs its PE and `.so` from the same directory; REA L-20,
    /// L-24). That is fine for the engine-bundled pack, built against that `winemetal.so`; any
    /// other pack is **refused unless** the pairing is proven (decision 12(c) is a refuse-unless
    /// gate): the engine's declared bundled DXMT version must equal the pack's, and when both
    /// `winemetal.so` files can be hashed their bytes must agree as well (the stricter gate; on
    /// the frankea engine the versions agree at 0.80 while the bytes differ, REA U-20). An
    /// engine that declares no bundled DXMT can prove the pairing only by identical bytes, so a
    /// missing or unreadable `winemetal.so` on either side refuses. Nil when there is no
    /// coupling (strategy C, no engine winemetal, a non-DXMT pack, the bundled pack).
    public static func winemetalCoupling(pack: RendererPack, engine: Engine) -> String? {
        guard pack.kind == .dxmt, strategy(for: .dxmt, engine: engine) == .prefixCopy, !isBundled(pack, in: engine) else { return nil }
        let engineSO = engine.unixLibDir.appending(path: winemetalUnixName)
        guard FileManager.default.fileExists(atPath: engineSO.path) else { return nil }
        let engineVersion = engine.manifest.bundledRenderer(.dxmt)?.version
        // Refuse until proven otherwise: a declared version that differs settles it; an equal one
        // (or none declared) still asks the bytes, and only when both files can be read.
        var differs = true
        if let engineVersion { differs = engineVersion != pack.manifest.version }
        let packSO = pack.unixDir.appending(path: winemetalUnixName)
        if engineVersion == nil || !differs, FileManager.default.fileExists(atPath: packSO.path),
           let engineHash = try? SHA256Hasher.hex(ofFile: engineSO), let packHash = try? SHA256Hasher.hex(ofFile: packSO) {
            differs = engineHash != packHash
        }
        guard differs else { return nil }
        let have = engineVersion.map { "DXMT \($0)" } ?? "engine \(engine.id), which declares no bundled DXMT version"
        return "strategy B runs the pack's D3D DLLs against the engine's winemetal (\(have)); use the engine-bundled pack or an engine with WINEDLLPATH_PREPEND"
    }

    public static let winemetalUnixName = "winemetal.so"

    /// The best pack of `kind` among `packs` for `engine`: engine-bundled packs first (they are
    /// built against that engine), then by version descending, then by id. Nil when none fits.
    public static func pack(of kind: RendererKind, engine: Engine, packs: [RendererPack]) -> RendererPack? {
        let fitting = packs.filter { $0.kind == kind && unmet(pack: $0, engine: engine).isEmpty }
        return fitting.sorted { a, b in
            let aBundled = isBundled(a, in: engine), bBundled = isBundled(b, in: engine)
            if aBundled != bBundled { return aBundled }
            let av = Version(a.manifest.version), bv = Version(b.manifest.version)
            switch (av, bv) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.id < b.id
            }
        }.first
    }

    /// Whether a pack lives inside the engine directory.
    public static func isBundled(_ pack: RendererPack, in engine: Engine) -> Bool {
        pack.root.path.hasPrefix(engine.root.path + "/")
    }

    /// Resolves `choice` against `packs` (pure). An explicit choice that cannot be served throws
    /// with the reason; `auto` takes the first of `autoOrder` that can be, wined3d at worst.
    public static func resolve(choice: RendererChoice, engine: Engine, packs: [RendererPack]) throws -> RendererSelection {
        if let kind = choice.kind {
            guard kind != .wined3d else { return RendererSelection.wined3d }
            guard let pack = pack(of: kind, engine: engine, packs: packs) else {
                throw OssoverError.missing(unavailableReason(kind: kind, engine: engine, packs: packs))
            }
            return selection(choice: choice, kind: kind, pack: pack, engine: engine, note: nil)
        }
        for kind in autoOrder {
            if kind == .wined3d {
                return RendererSelection(choice: .auto, kind: .wined3d, pack: nil, dllPath: nil, strategy: .none,
                                         note: "auto: no DXMT or DXVK pack fits engine \(engine.id); using WineD3D")
            }
            if let pack = pack(of: kind, engine: engine, packs: packs) {
                return selection(choice: .auto, kind: kind, pack: pack, engine: engine, note: "auto: \(kind.displayName) (\(pack.id))")
            }
        }
        return RendererSelection.wined3d
    }

    static func selection(choice: RendererChoice, kind: RendererKind, pack: RendererPack, engine: Engine, note: String?) -> RendererSelection {
        RendererSelection(choice: choice, kind: kind, pack: pack, dllPath: pack.wineDir,
                          strategy: strategy(for: kind, engine: engine), note: note)
    }

    /// One sentence saying why `kind` is not available on `engine`.
    public static func unavailableReason(kind: RendererKind, engine: Engine, packs: [RendererPack]) -> String {
        let candidates = packs.filter { $0.kind == kind }
        if candidates.isEmpty {
            if kind == .d3dmetal {
                return "no D3DMetal pack is installed: import Apple's Game Porting Toolkit with `ossover renderer import-gptk <dmg>` and accept its licence with `ossover renderer accept`"
            }
            return "no \(kind.displayName) pack is installed (`ossover renderer install \(kind.rawValue)`) and engine \(engine.id) bundles none"
        }
        let reasons = candidates.map { "\($0.id): " + unmet(pack: $0, engine: engine).joined(separator: "; ") }
        return "\(kind.displayName) cannot run on engine \(engine.id): " + reasons.joined(separator: " / ")
    }

    // MARK: Disk

    /// Every pack under `renderers/` whose manifest loads; unreadable ones are skipped (the
    /// store's `verify` reports them).
    public static func installedPacks(paths: OssoverPaths) -> [RendererPack] {
        paths.installedRendererIDs().compactMap { try? RendererPack.load(root: paths.renderer($0)) }
    }

    /// Packs the engine ships inside its own directory (`manifest.bundledRenderers`), either as a
    /// pack-shaped tree with a `manifest.json` or as bare `x86_64-{unix,windows}/` directories
    /// described by the bundle's `layout`, in which case a manifest is synthesised.
    public static func bundledPacks(engine: Engine) -> [RendererPack] {
        engine.manifest.bundledRenderers.compactMap { bundled -> RendererPack? in
            guard let root = engine.bundledRendererURL(bundled.kind) else { return nil }
            if FileManager.default.fileExists(atPath: root.appending(path: RendererPack.manifestFileName).path) {
                return try? RendererPack.load(root: root)
            }
            guard let packRoot = packRoot(containing: root) else { return nil }
            let manifest = RendererPackManifest(
                id: "\(engine.id)-\(bundled.kind.rawValue)", kind: bundled.kind, version: bundled.version ?? "",
                builtinMarked: bundled.builtinMarked ?? (bundled.kind == .dxmt),
                requires: RendererRequires(macdrvExports: bundled.kind == .dxmt || bundled.kind == .d3dmetal),
                layout: bundled.layout ?? defaultLayout(bundled.kind), overrides: defaultOverrides(bundled.kind),
                notes: ["synthesised from engine \(engine.id) bundledRenderers"])
            return RendererPack(root: packRoot, manifest: manifest)
        }
    }

    /// The pack root for a bundled renderer directory: `root` when it is pack-shaped
    /// (`root/wine/x86_64-windows` exists) or bare in CrossOver's shape (`root/x86_64-windows`,
    /// what `engine/package.sh` lays out under `overlays/<kind>/` and what `EngineStore.install`
    /// makes of Whisky's `DXMT/{x64,x32}`), or `root`'s parent when `root` is itself a `wine`
    /// directory holding `x86_64-windows`. Nil when none of the shapes is there. A pack root is
    /// "a directory containing `x86_64-windows/` or `wine/x86_64-windows/`" (REA L-23, L-65).
    static func packRoot(containing root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appending(path: "wine/\(EngineArch.x86_64.pe64LibDir)").path) { return root }
        if fm.fileExists(atPath: root.appending(path: EngineArch.x86_64.pe64LibDir).path) {
            return root.lastPathComponent == "wine" ? root.deletingLastPathComponent() : root
        }
        return nil
    }

    /// Installed and bundled packs together, for `resolve`.
    public static func availablePacks(engine: Engine, paths: OssoverPaths) -> [RendererPack] {
        bundledPacks(engine: engine) + installedPacks(paths: paths)
    }

    /// `resolve` against everything on disk.
    public static func resolve(choice: RendererChoice, engine: Engine, paths: OssoverPaths) throws -> RendererSelection {
        try resolve(choice: choice, engine: engine, packs: availablePacks(engine: engine, paths: paths))
    }
}
