// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/UserFolders.swift and WineRunner.swift (wineboot, setDpi)
//   (GPL-3.0), Copyright © 2026 Gauthier Piarrette
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors (RetinaMode, LogPixels)

import Foundation

/// One user folder the prefix now owns instead of linking to `~`.
public struct IsolatedFolder: Codable, Equatable, Sendable {
    /// `Documents`, `Desktop`, …
    public var name: String
    /// Where wineboot's symlink pointed (`/Users/h/Documents`), kept so the link can be restored.
    public var linkTarget: String

    public init(name: String, linkTarget: String) {
        self.name = name
        self.linkTarget = linkTarget
    }
}

/// `bottles/<name>/.user-folders.json`: which links user-folder isolation replaced, and where
/// they pointed, so `restoreUserFolders` can put them back.
public struct UserFolderRecord: Codable, Equatable, Sendable, SchemaDocument {
    public static let currentSchema = "ossover.user-folders/1"

    public var schema: String
    public var userName: String
    public var isolatedAt: Date
    public var folders: [IsolatedFolder]

    public init(userName: String, folders: [IsolatedFolder], isolatedAt: Date = Date()) {
        self.schema = Self.currentSchema
        self.userName = userName
        self.folders = folders
        self.isolatedAt = isolatedAt.secondPrecision
    }

    public static func load(from url: URL) throws -> UserFolderRecord { try JSONDocument.loadDocument(UserFolderRecord.self, from: url) }
    public func save(to url: URL) throws { try JSONDocument.save(self, to: url) }
}

/// Prefix initialisation (plan §4 "Process model"): `WINEARCH=win64 wineboot -u` →
/// `wineserver -w` → `winecfg -v` → one `.reg` batch (RetinaMode, CaptureDisplaysForFullscreen,
/// LogPixels, the wined3d fallback knob) → user-folder isolation.
///
/// One init path for every bottle, parameterised by `settings.windowsVersion` × arch, and the
/// arch is always `win64`: CrossOver's 13 templates are full copies that differ only in the
/// Windows version and `winearch` (REA L-39), and 32-bit prefixes are not emulated (REA L-43;
/// decision 26). The same steps re-run idempotently when the bottle's engine stamp no longer
/// matches its engine (`BottleStore.ensureInitialized`, REA L-42).
public enum Prefix {
    public static let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#
    public static let desktopKey = #"HKCU\Control Panel\Desktop"#
    public static let direct3DKey = #"HKCU\Software\Wine\Direct3D"#
    /// Every bottle is a 64-bit prefix (REA L-43).
    public static let wineArch = "win64"
    /// `LogPixels` for "High Resolution Mode" (`bottle create --hires`): 192 = 2 × 96, the plan's
    /// value. U-6: what CrossOver's own toggle writes (the DPI value, and whether it uses this key
    /// or `HKLM\…\Hardware Profiles\Current\Software\Fonts\LogPixels`) is unverified — the writer
    /// is the GUI and no plain-text artifact carries it (REA L-40, SH-TT-65).
    public static let highResolutionDPI = 192
    /// The folders wineboot links to the Mac's own; isolation makes them real directories.
    public static let userFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos"]
    public static let recordFileName = ".user-folders.json"
    /// The user wineboot creates on a CrossOver-derived tree (CW HACK); upstream uses the login name.
    public static let crossOverUserName = "crossover"

    public struct InitReport: Sendable, Equatable {
        public var userName: String
        public var windowsVersion: WindowsVersion
        public var registryEntries: [RegistryEntry]
        public var isolated: [IsolatedFolder]
        public var notes: [String]
        public var shutdown: WineServer.ShutdownReport?
        /// The engine that ran these steps; what `bottle.json.engineStamp` should now say (REA L-42).
        public var engineStamp: EngineStamp?

        public init(userName: String, windowsVersion: WindowsVersion, registryEntries: [RegistryEntry], isolated: [IsolatedFolder],
                    notes: [String], shutdown: WineServer.ShutdownReport?, engineStamp: EngineStamp? = nil) {
            self.userName = userName
            self.windowsVersion = windowsVersion
            self.registryEntries = registryEntries
            self.isolated = isolated
            self.notes = notes
            self.shutdown = shutdown
            self.engineStamp = engineStamp
        }
    }

    // MARK: Pure

    /// The Mac driver and desktop values a bottle's settings imply — what a `retina`, `dpi` or
    /// `captureDisplaysForFullscreen` change has to rewrite (`applyDisplaySettings`).
    ///
    /// * `RetinaMode` goes on the **global** `Mac Driver` key, never under `AppDefaults\<exe>`:
    ///   `winemac.drv` reads it with `appkey == NULL`, once per process at `macdrv_init`, so the
    ///   DPI and monitor sizes stay consistent for every process of the prefix (REA L-40).
    /// * `CaptureDisplaysForFullscreen`: value name confirmed from `macdrv_main.c:326-327`
    ///   (`get_config_key(hkey, appkey, …)` + `IS_OPTION_TRUE`), a `y`/`n` string. Unlike
    ///   `RetinaMode` it also honours a per-app key, which ossover does not write (REA L-41;
    ///   U-7 resolved).
    /// * `LogPixels` under `HKCU\Control Panel\Desktop`, winecfg's own key; `wine.inf` seeds
    ///   the `HKCC\Software\Fonts\LogPixels` fallback with 96 (REA L-40).
    public static func displayEntries(for settings: BottleSettings) -> [RegistryEntry] {
        [
            .string(macDriverKey, "RetinaMode", settings.retina ? "y" : "n"),
            .string(macDriverKey, "CaptureDisplaysForFullscreen", settings.captureDisplaysForFullscreen ? "y" : "n"),
            .dword(desktopKey, "LogPixels", settings.dpi),
        ]
    }

    /// The one value kept from CrossOver's `crossover.inf` `[WineSettingsReg]`, labelled for what
    /// it is: a **wined3d fallback knob**. `cb_access_map_w=1` is read as a DWORD by
    /// `dlls/wined3d/wined3d_main.c:483-486` (CX's inf comment: "Rocket League performance") and
    /// is inert under DXMT/D3DMetal, which replace wined3d. The rest of that section is not
    /// carried: `Systray\Hidden` has no reader in the 26.3.0 tree and `X11 Driver\ShowSystray`
    /// is not a key it reads (the only `ShowSystray` reader is
    /// `HKCU\Software\Wine\Explorer\ShowSystray`, `programs/explorer/desktop.c:959-973`).
    /// Nothing version-related is copied either: `winecfg -v win10` on the CX tree writes
    /// `CurrentBuild(Number)=19045`, `CurrentVersion=6.3`, `UBR=5796` and `ProductType` itself
    /// (`WinVersion`). REA L-38; decision 24.
    public static let wined3dFallbackEntries: [RegistryEntry] = [
        .dword(direct3DKey, "cb_access_map_w", 1),
    ]

    /// The whole init batch: the display values plus the fixed defaults.
    public static func registryEntries(for settings: BottleSettings) -> [RegistryEntry] {
        displayEntries(for: settings) + wined3dFallbackEntries
    }

    /// The extra environment `wineboot` runs with: 64-bit prefixes only (REA L-43).
    public static let winebootEnvironment: [String: String] = ["WINEARCH": wineArch]

    // MARK: Steps

    /// The whole sequence; every step is idempotent, so this is also the re-init path an engine
    /// change takes (`BottleStore.ensureInitialized`). Refuses (`.invalid`, `requireIdle`) while
    /// anything of the prefix is alive: `wineboot -u` under running programs is not the
    /// idempotent re-init, and the `wineserver -w` after it would wait for them, not for the
    /// boot — the caller ends them first (`WineServer.shutdown`, `ossover bottle stop`). That
    /// wait is capped at `bootWait`; on expiry the error lists what still runs. `shutdownAfter`
    /// stops the server at the end so the hives are flushed to `system.reg`/`user.reg` before
    /// the caller looks at them, and so the next launch starts a server that reads the values
    /// written here.
    public static func initialize(bottle: Bottle, engine: Engine, layout: BottleLayout, shutdownAfter: Bool = true,
                                  bootWait: TimeInterval = WineServer.bootWait,
                                  log: (@Sendable (String) -> Void)? = nil) async throws -> InitReport {
        try layout.ensureDirectories()
        try await requireIdle(bottle: bottle, engine: engine, layout: layout)
        let runner = WineRunner(engine: engine, bottle: bottle, layout: layout)
        let notes: [String] = []

        log?("wineboot -u (WINEARCH=win64) in \(layout.prefix.path)")
        try await wineboot(runner: runner)
        log?("waiting for the boot to settle (wineserver -w, up to \(Int(bootWait)) s)")
        try await WineServer.waitForExit(engine: engine, bottle: bottle, layout: layout, timeout: bootWait)
        guard layout.prefixInitialised else {
            throw OssoverError.io("wineboot finished but \(layout.systemReg.path) does not exist")
        }

        let version = bottle.settings.windowsVersion
        log?("winecfg -v \(version.rawValue)")
        try await WinVersion.set(version, runner: runner)

        let entries = registryEntries(for: bottle.settings)
        log?("registry: " + entries.map { "\($0.name)=\($0.data)" }.joined(separator: ", "))
        try await Registry(runner: runner).apply(entries)

        let userName = userName(layout: layout, engine: engine)
        var isolated: [IsolatedFolder] = []
        if bottle.settings.isolateUserFolders {
            isolated = try isolateUserFolders(layout: layout, userName: userName)
            log?(isolated.isEmpty ? "user folders: nothing to isolate" : "user folders isolated: " + isolated.map(\.name).joined(separator: ", "))
        }

        var shutdown: WineServer.ShutdownReport?
        if shutdownAfter {
            shutdown = try await WineServer.shutdown(engine: engine, bottle: bottle, layout: layout)
            log?(shutdown?.summary ?? "")
        }
        return InitReport(userName: userName, windowsVersion: version, registryEntries: entries, isolated: isolated,
                          notes: notes, shutdown: shutdown, engineStamp: EngineStamp(engine: engine))
    }

    /// `wineboot -u` (`-fu` with `force`) with `WINEARCH=win64`; `winemenubuilder.exe=d` is in
    /// the env table already.
    public static func wineboot(runner: WineRunner, force: Bool = false) async throws {
        try await runner.runToolChecked(["wineboot", force ? "-fu" : "-u"], extra: winebootEnvironment)
    }

    /// Re-applies the Windows version and the whole registry batch (after a settings change).
    /// Writes only; `applySettings(bottle:engine:layout:restart:)` adds the reboot.
    public static func applySettings(runner: WineRunner) async throws {
        try await WinVersion.set(runner.bottle.settings.windowsVersion, runner: runner)
        try await Registry(runner: runner).apply(registryEntries(for: runner.bottle.settings))
    }

    /// `winecfg -v` plus `applyDisplaySettings` (and its reboot with `restart`): what a
    /// `winver`/`retina`/`dpi`/`captureDisplaysForFullscreen` edit on a booted prefix needs.
    @discardableResult
    public static func applySettings(bottle: Bottle, engine: Engine, layout: BottleLayout, restart: Bool = true,
                                     log: (@Sendable (String) -> Void)? = nil) async throws -> WineServer.ShutdownReport? {
        try requireInitialised(bottle: bottle, layout: layout)
        let runner = WineRunner(engine: engine, bottle: bottle, layout: layout)
        log?("winecfg -v \(bottle.settings.windowsVersion.rawValue)")
        try await WinVersion.set(bottle.settings.windowsVersion, runner: runner)
        return try await applyDisplaySettings(bottle: bottle, engine: engine, layout: layout, restart: restart, log: log)
    }

    /// Rewrites the Mac driver and desktop values (`displayEntries`) after a `retina`, `dpi` or
    /// `captureDisplaysForFullscreen` change. `RetinaMode` is read once per process at
    /// `macdrv_init`, so nothing already running picks the change up: with `restart` the bottle
    /// is rebooted (`wineserver -k` → `-w` → leftovers, `WineServer.shutdown`) and the next
    /// launch starts a server and processes that see the new values — what CrossOver's "Reboot
    /// Bottle and Enable High Resolution Mode" does (REA L-40; decision 22). With `restart ==
    /// false` the caller owns that reboot before the next launch. Returns the shutdown report
    /// when one ran. Throws `.missing` for a prefix that was never booted: its first boot writes
    /// the same batch.
    @discardableResult
    public static func applyDisplaySettings(bottle: Bottle, engine: Engine, layout: BottleLayout, restart: Bool = true,
                                            log: (@Sendable (String) -> Void)? = nil) async throws -> WineServer.ShutdownReport? {
        try requireInitialised(bottle: bottle, layout: layout)
        let runner = WineRunner(engine: engine, bottle: bottle, layout: layout)
        let entries = displayEntries(for: bottle.settings)
        log?("registry: " + entries.map { "\($0.name)=\($0.data)" }.joined(separator: ", "))
        try await Registry(runner: runner).apply(entries)
        guard restart else { return nil }
        log?("rebooting the bottle so every process reads the new display values")
        let report = try await WineServer.shutdown(engine: engine, bottle: bottle, layout: layout)
        log?(report.summary)
        return report
    }

    static func requireInitialised(bottle: Bottle, layout: BottleLayout) throws {
        guard layout.prefixInitialised else {
            throw OssoverError.missing("bottle \(bottle.name): prefix \(layout.prefix.path) is not initialised; the values apply at its first boot")
        }
    }

    /// Throws `.invalid` naming pid + command of whatever runs in the prefix (`WINEPREFIX` exact
    /// match, or an exe inside the prefix by Unix path: `WineServer.liveProcesses`) and the stop
    /// hint; `wineboot` never starts under them.
    public static func requireIdle(bottle: Bottle, engine: Engine, layout: BottleLayout) async throws {
        let live = try await WineServer.liveProcesses(layout: layout, engineRoot: engine.root)
        guard live.isEmpty else {
            throw OssoverError.invalid("bottle \(bottle.name): wineboot must not run while " + WineServer.busyClause(bottle: bottle.name, live: live))
        }
    }

    // MARK: Users

    /// Every real user directory under `drive_c/users` (Wine's `Public` skipped), sorted.
    public static func userDirectories(driveC: URL) -> [URL] {
        let users = driveC.appending(path: "users", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            url.lastPathComponent != "Public" && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The Windows user name of the prefix: the login name when wineboot used it, else
    /// `crossover` (CrossOver-derived trees), else the first user directory. For a prefix not
    /// booted yet the name wineboot will use: `crossover` on a CrossOver-derived `engine`
    /// (`WineEnvironment.isCrossOverDerived`; an engine carrying highball patch 0001 uses the
    /// login name instead, which only booting can tell), else the login name.
    public static func userName(layout: BottleLayout, engine: Engine? = nil) -> String {
        let names = userDirectories(driveC: layout.driveC).map(\.lastPathComponent)
        let login = NSUserName()
        if names.contains(login) { return login }
        if names.contains(crossOverUserName) { return crossOverUserName }
        if let first = names.first { return first }
        if let engine, WineEnvironment.isCrossOverDerived(engine) { return crossOverUserName }
        return login
    }

    public static func recordURL(layout: BottleLayout) -> URL { layout.root.appending(path: recordFileName) }

    public static func userFolderRecord(layout: BottleLayout) -> UserFolderRecord? {
        try? UserFolderRecord.load(from: recordURL(layout: layout))
    }

    /// Replaces the symlinked user folders under `drive_c/users/<userName>` with real directories
    /// and records what was replaced. Folders already real, or missing, are left alone.
    @discardableResult
    public static func isolateUserFolders(layout: BottleLayout, userName: String) throws -> [IsolatedFolder] {
        let fm = FileManager.default
        let user = layout.userDirectory(userName)
        var done = userFolderRecord(layout: layout)?.folders ?? []
        for name in userFolders {
            let folder = user.appending(path: name, directoryHint: .isDirectory)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: folder.path) else { continue }
            do {
                try fm.removeItem(at: folder)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw OssoverError.io("cannot isolate \(folder.path): \(error.localizedDescription)")
            }
            done.removeAll { $0.name == name }
            done.append(IsolatedFolder(name: name, linkTarget: target))
        }
        if !done.isEmpty {
            try UserFolderRecord(userName: userName, folders: done).save(to: recordURL(layout: layout))
        }
        return done
    }

    /// Puts the links back where the record says they were. A folder with files in it is kept
    /// beside the link as `<name> (bottle)` — `<name> (bottle 2)`, `(bottle 3)`, … when earlier
    /// restores already left one — and never deleted. Returns what was restored.
    @discardableResult
    public static func restoreUserFolders(layout: BottleLayout) throws -> [IsolatedFolder] {
        guard let record = userFolderRecord(layout: layout) else { return [] }
        let fm = FileManager.default
        let user = layout.userDirectory(record.userName)
        var restored: [IsolatedFolder] = []
        for folder in record.folders {
            let url = user.appending(path: folder.name, directoryHint: .isDirectory)
            do {
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil, fm.fileExists(atPath: url.path) {
                    let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                    if contents.isEmpty {
                        try fm.removeItem(at: url)
                    } else {
                        try fm.moveItem(at: url, to: keptFolderURL(for: folder.name, in: user))
                    }
                }
                if !fm.fileExists(atPath: url.path), (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil {
                    try fm.createSymbolicLink(atPath: url.path, withDestinationPath: folder.linkTarget)
                }
            } catch {
                throw OssoverError.io("cannot restore \(url.path): \(error.localizedDescription)")
            }
            restored.append(folder)
        }
        try? fm.removeItem(at: recordURL(layout: layout))
        return restored
    }

    /// `<name> (bottle)` under `user`, or the first of `<name> (bottle 2)`, `(bottle 3)`, … that
    /// does not exist yet (a symlink of that name counts as existing).
    public static func keptFolderURL(for name: String, in user: URL) -> URL {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        }
        var candidate = user.appending(path: "\(name) (bottle)", directoryHint: .isDirectory)
        var counter = 2
        while exists(candidate) {
            candidate = user.appending(path: "\(name) (bottle \(counter))", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
    }
}
