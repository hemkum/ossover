// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors
// Adapted from highball Sources/HighballKit/Bottle.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// The Windows version `winecfg -v` sets for a prefix.
public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win7, win8, win81, win10, win11

    public var displayName: String {
        switch self {
        case .win7: return "Windows 7"
        case .win8: return "Windows 8"
        case .win81: return "Windows 8.1"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
}

/// Wine's synchronisation primitive backend.
///
/// Which variables a mode sets is `WineEnvironment.syncVariables` (REA L-30, L-32): msync is
/// `WINEMSYNC=1` alone — CrossOver sets only that, never `WINEESYNC` beside it (esync is not
/// compiled into the 26.3.0 tree, so a CX-derived engine gets no `WINEESYNC` row at all);
/// `none` is an explicit `WINEMSYNC=0`, equal to unset. The engine-aware default is
/// `BottleSettings.defaultSync(for:)` (decision 20); `BottleSettings()` alone says `msync`.
public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// wineserver round trips only; works everywhere, slowest. CrossOver's own fresh-bottle default.
    case none
    /// `WINEESYNC`; only an upstream build compiled with esync reads it (`EngineCapabilities.esync`).
    case esync
    /// `WINEMSYNC` (Mach semaphores); CrossOver-derived engines only (`EngineCapabilities.msync`).
    /// One value per wineserver lifetime: see `WineRunner.checkServerSync`.
    case msync
}

/// The renderer a bottle asks for. `auto` lets the launcher pick the best the engine has
/// (DXMT → DXVK → wined3d, D3DMetal only when chosen explicitly).
public enum RendererChoice: String, Codable, CaseIterable, Sendable {
    case auto, dxmt, dxvk, d3dmetal, wined3d

    /// The concrete kind, nil for `auto`.
    public var kind: RendererKind? {
        switch self {
        case .auto: return nil
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        case .d3dmetal: return .d3dmetal
        case .wined3d: return .wined3d
        }
    }

    public init(_ kind: RendererKind) {
        switch kind {
        case .dxmt: self = .dxmt
        case .dxvk: self = .dxvk
        case .d3dmetal: self = .d3dmetal
        case .wined3d: self = .wined3d
        }
    }
}

/// Per-bottle settings, stored inside `bottle.json`. Defaults are the plan's Witcher 3 profile
/// (win10, msync, retina at 96 dpi, AVX advertised, user folders isolated) with the renderer
/// left on `auto`.
public struct BottleSettings: Codable, Equatable, Sendable {
    public var windowsVersion: WindowsVersion
    public var sync: SyncMode
    public var renderer: RendererChoice
    /// `HKCU\Software\Wine\Mac Driver\RetinaMode`.
    public var retina: Bool
    /// `HKCU\Control Panel\Desktop\LogPixels`.
    public var dpi: Int
    /// `ROSETTA_ADVERTISE_AVX=1`.
    public var advertiseAVX: Bool
    /// `MTL_HUD_ENABLED=1`.
    public var metalHUD: Bool
    /// `MTL_HUD_LOG_ENABLED=1` (per-second `metal-HUD:` lines in the unified log; the bench reads them).
    public var metalHUDLog: Bool
    /// DLSS → MetalFX upscaling (`DXMT_ENABLE_NVEXT` / `D3DM_ENABLE_METALFX`).
    public var dlssMetalFX: Bool
    /// `HKCU\Software\Wine\Mac Driver\CaptureDisplaysForFullscreen`.
    public var captureDisplaysForFullscreen: Bool
    /// Keep `drive_c/users/<u>/Documents` & co. inside the prefix instead of symlinks to ~/.
    public var isolateUserFolders: Bool
    /// Extra `WINEDLLOVERRIDES` fragments ("amd_ags_x64=", "dxgi=n,b"), appended after the renderer's.
    public var dllOverrides: [String]
    /// Extra environment, merged above the engine's `baseEnv` and below a program's `env`.
    public var env: [String: String]

    public init(windowsVersion: WindowsVersion = .win10, sync: SyncMode = .msync, renderer: RendererChoice = .auto,
                retina: Bool = true, dpi: Int = 96, advertiseAVX: Bool = true, metalHUD: Bool = false,
                metalHUDLog: Bool = false, dlssMetalFX: Bool = false, captureDisplaysForFullscreen: Bool = false,
                isolateUserFolders: Bool = true, dllOverrides: [String] = [], env: [String: String] = [:]) {
        self.windowsVersion = windowsVersion
        self.sync = sync
        self.renderer = renderer
        self.retina = retina
        self.dpi = dpi
        self.advertiseAVX = advertiseAVX
        self.metalHUD = metalHUD
        self.metalHUDLog = metalHUDLog
        self.dlssMetalFX = dlssMetalFX
        self.captureDisplaysForFullscreen = captureDisplaysForFullscreen
        self.isolateUserFolders = isolateUserFolders
        self.dllOverrides = dllOverrides
        self.env = env
    }

    enum CodingKeys: String, CodingKey {
        case windowsVersion, sync, renderer, retina, dpi, advertiseAVX, metalHUD, metalHUDLog, dlssMetalFX,
             captureDisplaysForFullscreen, isolateUserFolders, dllOverrides, env
    }

    /// Missing keys take the defaults, so a bottle.json written before a setting existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BottleSettings()
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? d.windowsVersion
        sync = try c.decodeIfPresent(SyncMode.self, forKey: .sync) ?? d.sync
        renderer = try c.decodeIfPresent(RendererChoice.self, forKey: .renderer) ?? d.renderer
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? d.retina
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? d.dpi
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? d.advertiseAVX
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        metalHUDLog = try c.decodeIfPresent(Bool.self, forKey: .metalHUDLog) ?? d.metalHUDLog
        dlssMetalFX = try c.decodeIfPresent(Bool.self, forKey: .dlssMetalFX) ?? d.dlssMetalFX
        captureDisplaysForFullscreen = try c.decodeIfPresent(Bool.self, forKey: .captureDisplaysForFullscreen) ?? d.captureDisplaysForFullscreen
        isolateUserFolders = try c.decodeIfPresent(Bool.self, forKey: .isolateUserFolders) ?? d.isolateUserFolders
        dllOverrides = try c.decodeIfPresent([String].self, forKey: .dllOverrides) ?? d.dllOverrides
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
    }

    public static let dpiRange = 72...480

    /// The sync a new bottle on an engine with `capabilities` gets (decision 20, REA L-30, L-33,
    /// L-34): `msync` for every bottle on an engine that has it, `none` where the engine lacks it
    /// (`WineEnvironment.effectiveSync` downgrades the same way at launch). The model has no
    /// game/non-game distinction, so there is no "games only" qualifier. This is a deliberate
    /// divergence from CrossOver, whose fresh bottle has msync **off** (a GUI toggle, "Enable
    /// MSync") and which turns it on for every Steam install through its "Enable MSync" tie;
    /// `bottle create` surfaces CrossOver's own warning (`msyncWarning`) and recipes override per
    /// workload. An esync-only engine is not promoted to esync here: that is an explicit choice.
    public static func defaultSync(for capabilities: EngineCapabilities) -> SyncMode {
        capabilities.msync ? .msync : .none
    }

    /// CrossOver's GUI warning for the toggle ossover turns on by default (REA L-33, SH-TT-61).
    public static let msyncWarning = "Some Windows applications will not work correctly with MSync enabled."

    public func validate() throws {
        guard Self.dpiRange.contains(dpi) else { throw OssoverError.invalid("dpi \(dpi) is outside \(Self.dpiRange)") }
        for key in env.keys where key.isEmpty || key.contains("=") {
            throw OssoverError.invalid("env has an invalid variable name '\(key)'")
        }
        for entry in dllOverrides where entry.isEmpty || !entry.contains("=") {
            throw OssoverError.invalid("dllOverrides entry '\(entry)' is not '<dll[,dll]>=<order>'")
        }
    }
}
