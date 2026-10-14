// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/highball/main.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (bottle create/list/delete shape, key=value settings editing)

import ArgumentParser
import Foundation
import OssoverKit

struct BottleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle",
        abstract: "Create, list, configure, clone, stop and delete bottles (Wine prefixes).",
        subcommands: [Create.self, List.self, Settings.self, Clone.self, Stop.self, Delete.self])

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a bottle and boot its prefix (wineboot, winecfg -v, registry).")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Bottle name (a directory name under bottles/).") var name: String
        @Option(help: "Engine id (default: the only installed engine).") var engine: String?
        @Option(help: "Windows version (\(WindowsVersion.allCases.map(\.rawValue).joined(separator: ", "))).") var winver: WindowsVersion = .win10
        @Option(help: "Sync backend (\(SyncMode.allCases.map(\.rawValue).joined(separator: ", "))); default: msync when the engine has it, else none.") var sync: SyncMode?
        @Option(help: "Renderer (\(RendererChoice.allCases.map(\.rawValue).joined(separator: ", "))).") var renderer: RendererChoice = .auto
        @Flag(inversion: .prefixedNo, help: "RetinaMode in Wine's Mac driver.") var retina = true
        @Option(help: "LogPixels (\(BottleSettings.dpiRange.lowerBound)...\(BottleSettings.dpiRange.upperBound)); default 96, or \(Prefix.highResolutionDPI) with --hires.")
        var dpi: Int?
        // U-6: 192 dpi for CrossOver's "High Resolution Mode" is an analyst assumption — the GUI writes the
        // toggle and no plain-text artifact shows its LogPixels value (REA L-40); RetinaMode=y is confirmed.
        @Flag(help: "High Resolution Mode: RetinaMode on and LogPixels \(Prefix.highResolutionDPI) (implies --retina; --dpi still wins).")
        var hires = false
        @Flag(name: .customLong("isolate-user-folders"), inversion: .prefixedNo,
              help: "Keep Documents, Desktop, ... inside the prefix instead of symlinks into ~.") var isolateUserFolders = true
        @Flag(name: .customLong("no-init"), help: "Write bottle.json and the directories only; skip wineboot.") var noInit = false

        func run() async throws {
            let paths = global.paths
            let engineID = try engine ?? Self.defaultEngine(EngineStore(paths: paths))
            // Decision 20: msync wherever the engine has it (CrossOver's fresh bottle has it off).
            let sync = try sync ?? BottleSettings.defaultSync(for: EngineStore(paths: paths).engine(engineID).capabilities)
            let settings = BottleSettings(windowsVersion: winver, sync: sync, renderer: renderer, retina: retina || hires,
                                          dpi: dpi ?? (hires ? Prefix.highResolutionDPI : 96), isolateUserFolders: isolateUserFolders)
            let bottle = try BottleStore(paths: paths).create(name: name, engineID: engineID, settings: settings)
            let session = try BottleSession.open(name, paths: paths)
            print("created bottle \(bottle.name) with engine \(engineID) at \(session.layout.root.path)")
            session.warnAboutSync()
            if sync == .msync {
                Console.note("sync=msync (CrossOver's default is off; --sync none to match it). CrossOver's own warning: " + BottleSettings.msyncWarning)
            }
            if noInit {
                Console.note("prefix not booted (--no-init); the first run or recipe boots it")
                return
            }
            Console.note("booting the prefix (wineboot -u, winecfg -v \(winver.rawValue), registry); the first boot takes about a minute")
            // The same path a launch takes (engine stamp, REA L-42): a boot that fails drops the stamp so the next run retries.
            let result = try await BottleStore(paths: paths).ensureInitialized(bottle, engine: session.engine, log: Console.logger)
            guard let report = result.report else { return }
            for note in report.notes { Console.warn(note) }
            var summary = "prefix ready: user \(report.userName), \(report.windowsVersion.rawValue), "
            summary += report.registryEntries.map { "\($0.name)=\($0.data)" }.joined(separator: ", ")
            if !report.isolated.isEmpty { summary += ", isolated " + report.isolated.map(\.name).joined(separator: ", ") }
            print(summary)
        }

        static func defaultEngine(_ store: EngineStore) throws -> String {
            let ids = store.list().map(\.id)
            switch ids.count {
            case 0: throw OssoverError.missing("no engine installed: ossover engine install <id or manifest.json>")
            case 1: return ids[0]
            default: throw ValidationError("several engines are installed; pass --engine (one of: \(ids.joined(separator: ", ")))")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Bottles and their main settings.")

        @OptionGroup var global: GlobalOptions
        @Flag(help: "Print every bottle.json as JSON.") var json = false

        func run() async throws {
            let store = BottleStore(paths: global.paths)
            let bottles = store.list(log: Console.logger)
            if json { return try Console.json(bottles) }
            guard !bottles.isEmpty else {
                print("no bottles (ossover bottle create <name> --engine <id>)")
                return
            }
            Console.table(["Name", "Engine", "Winver", "Sync", "Renderer", "Prefix", "Programs", "Recipes", "Steam"], bottles.map { bottle in
                let steam = bottle.steam.map { "\($0.appID)" + ($0.branch.map { "@" + $0 } ?? "") } ?? "-"
                return [bottle.name, bottle.engineID, bottle.settings.windowsVersion.rawValue, bottle.settings.sync.rawValue,
                        bottle.settings.renderer.rawValue, store.layout(bottle.name).prefixInitialised ? "booted" : "new",
                        Format.list(bottle.programs.map(\.id)), Format.list(bottle.recipesApplied), steam]
            })
        }
    }

    struct Settings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a bottle's settings, or change them with --set key=value (engine=<id> switches the engine).",
            discussion: "Keys: " + SettingsEditor.keyHelp + ". Changes to winver, retina, dpi and captureDisplaysForFullscreen "
                + "are pushed into a booted prefix at once (winecfg -v, registry) unless --no-apply. A change of sync stops a "
                + "running wineserver (wineserver -k, -w): every process of a prefix must use the sync mode its server started with.\n\n"
                + "engine=<id> moves the bottle to another installed engine (the same game on two engines, for an A/B): refused "
                + "while the bottle has live Wine processes (ossover bottle stop <name> first); a renderer overlay the previous "
                + "engine placed in the prefix is reverted; bottle.json is saved with the new engine and no engine stamp, so the "
                + "next launch runs wineboot -u, winecfg -v and the display registry batch on the new engine. wineboot -u refreshes "
                + "the prefix's Wine builtins (system32, fake DLLs, the registry defaults) for that engine; programs, recipes and "
                + "the Steam state stay. Other --set keys given alongside are saved too, and reach the prefix at that re-init.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Bottle name.") var name: String
        @Option(name: .customLong("set"), parsing: .upToNextOption, help: "key=value assignments (engine=<id> switches the engine).")
        var set: [String] = []
        @Flag(name: .customLong("no-apply"), help: "Save only; do not touch the prefix now.") var noApply = false
        @Flag(help: "Print the settings as JSON.") var json = false

        func run() async throws {
            let store = BottleStore(paths: global.paths)
            // The engine switch goes first, with its live-process gate: when it is refused nothing
            // is saved. Once through, nothing runs in the prefix for the edits below either.
            let (engineID, assignments) = try EngineSwitch.partition(set)
            var engineSwitched = false
            if let engineID {
                let result = try await store.switchEngine(name, to: engineID, log: Console.logger)
                if result.changed {
                    engineSwitched = true
                    Console.note("bottle.json saved without an engine stamp: the next launch runs wineboot -u, winecfg -v and the "
                        + "display registry batch on engine \(engineID), refreshing the prefix's Wine builtins")
                    warnAboutEngineFit(engineID)
                } else {
                    Console.note("bottle \(name) already runs on engine \(engineID)")
                }
            }
            var bottle = try store.load(name)
            let previousSync = bottle.settings.sync
            var touchesWine = false
            for assignment in assignments {
                touchesWine = try SettingsEditor.apply(assignment, to: &bottle.settings) || touchesWine
            }
            if !assignments.isEmpty {
                try store.save(bottle)
                Console.note("saved \(assignments.count) change(s) to \(store.layout(name).bottleJSON.path)")
            }
            if bottle.settings.sync != previousSync, !noApply, !engineSwitched {
                // Decision 19: one WINEMSYNC per wineserver lifetime; a server started with the old
                // mode is stopped now so the next launch (or the winecfg below) starts a fresh one.
                let session = try BottleSession.open(name, paths: global.paths)
                let check = try await session.runner.checkServerSync(restartServer: true)
                Console.note("sync \(previousSync.rawValue) → \(bottle.settings.sync.rawValue): \(check.summary)")
            }
            if touchesWine, engineSwitched {
                // The prefix-init steps the next launch runs on the new engine apply winver and the registry values.
                Console.note("winver/registry values apply at the prefix re-init on the next launch")
            } else if touchesWine, !noApply {
                let session = try BottleSession.open(name, paths: global.paths)
                if session.layout.prefixInitialised {
                    Console.note("applying winver and registry values to the prefix, then rebooting it (RetinaMode is read once per process)")
                    let report = try await Prefix.applySettings(bottle: session.bottle, engine: session.engine, layout: session.layout,
                                                                restart: true, log: Console.logger)
                    if let report { Console.note(report.summary) }
                } else {
                    Console.note("prefix not booted yet; the values apply at the first boot")
                }
            }
            if json {
                try Console.json(bottle.settings)
            } else {
                Console.pairs(SettingsEditor.rows(bottle.settings))
            }
        }

        /// The settings were chosen against the old engine: warn when the new one lacks the sync
        /// mode or cannot run the renderer (the launch would fail or fall back later).
        func warnAboutEngineFit(_ engineID: String) {
            guard let session = try? BottleSession.open(name, paths: global.paths) else { return }
            session.warnAboutSync()
            do {
                _ = try session.resolveRenderer()
            } catch {
                Console.warn("renderer \(session.bottle.settings.renderer.rawValue) on engine \(engineID): \(error.localizedDescription) "
                    + "(ossover bottle settings \(name) --set renderer=...)")
            }
        }
    }

    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clone a bottle, sharing the prefix's blocks on APFS (clonefile), for an A/B on another engine.",
            discussion: "The prefix is copied with cp -c -R (clonefile): on APFS the clone shares the game's blocks with the source "
                + "until one of them writes, so a tens-of-GB install costs no second copy; cp copies bytes by itself where the volume "
                + "cannot clone, and a cp -c that fails outright is retried as plain cp -R with a warning. bottle.json is copied under "
                + "the new name (programs, recipes and Steam state kept, created=now); logs/ and steamcmd/ start empty; a renderer "
                + "overlay the source's engine placed is reverted in the clone and placed again at its first launch. With --engine "
                + "the clone starts without an engine stamp, so its first launch runs wineboot -u, winecfg -v and the display "
                + "registry batch on that engine. Refused while the source has live Wine processes (ossover bottle stop <src>) and "
                + "when the destination exists.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Source bottle name.") var source: String
        @Argument(help: "Name of the new bottle.") var destination: String
        @Option(help: "Engine id for the clone (default: the source's; must be installed).") var engine: String?

        func run() async throws {
            let store = BottleStore(paths: global.paths)
            let result = try await store.clone(source, to: destination, engineID: engine, log: Console.logger)
            let layout = store.layout(destination)
            print("cloned bottle \(source) to \(destination) (engine \(result.bottle.engineID)) at \(layout.root.path)")
            if !result.usedCloneFlag {
                Console.warn("the prefix was copied byte by byte (cp -R); it shares no space with \(source)")
            }
            if result.bottle.engineStamp == nil {
                Console.note(layout.prefixInitialised
                    ? "no engine stamp: the first launch re-initialises the prefix on engine \(result.bottle.engineID) (wineboot -u, winecfg -v, registry)"
                    : "prefix not booted; the first launch boots it on engine \(result.bottle.engineID)")
            }
            // The settings came from the source: warn when the clone's engine lacks the sync mode or the renderer.
            if let session = try? BottleSession.open(destination, paths: global.paths) {
                session.warnAboutSync()
                do {
                    _ = try session.resolveRenderer()
                } catch {
                    Console.warn("renderer \(session.bottle.settings.renderer.rawValue) on engine \(session.engine.id): \(error.localizedDescription)")
                }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a bottle directory (prefix, logs, results).")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Bottle name.") var name: String
        @Flag(help: "Stop the bottle's Wine processes first.") var force = false

        func run() async throws {
            let store = BottleStore(paths: global.paths)
            let running = try await store.runningProcesses(of: name)
            if !running.isEmpty {
                guard force else {
                    throw OssoverError.invalid("bottle \(name) has \(running.count) running Wine process(es); pass --force to stop them")
                }
                if let session = try? BottleSession.open(name, paths: global.paths) {
                    let report = try await session.runner.shutdown()
                    Console.note(report.summary)
                } else {
                    let killed = ProcessTable.terminate(running)
                    Console.note("stopped \(running.count) process(es)" + (killed.isEmpty ? "" : ", \(killed.count) with SIGKILL"))
                }
            }
            try await store.delete(name)
            print("deleted bottle \(name)")
        }
    }
}

/// `--set key=value` on `BottleSettings`.
enum SettingsEditor {
    static let keyHelp = "winver|windowsVersion, sync, renderer, retina, dpi, advertiseAVX, metalHUD, metalHUDLog, dlssMetalFX, "
        + "captureDisplaysForFullscreen, isolateUserFolders, dllOverrides (';'-separated), dllOverrides+ (append), env.NAME (empty removes)"

    /// Applies one assignment. Returns true when the change has to reach the prefix (winecfg/registry).
    static func apply(_ assignment: String, to settings: inout BottleSettings) throws -> Bool {
        guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
            throw ValidationError("--set expects key=value, got '\(assignment)'")
        }
        let rawKey = String(assignment[..<equals])
        let value = String(assignment[assignment.index(after: equals)...])
        if rawKey.hasPrefix("env.") {
            let name = String(rawKey.dropFirst("env.".count))
            guard !name.isEmpty, !name.contains("=") else { throw ValidationError("bad environment variable name in '\(rawKey)'") }
            settings.env[name] = value.isEmpty ? nil : value
            return false
        }
        let key = rawKey.lowercased().filter { $0 != "-" && $0 != "_" }
        switch key {
        case "winver", "windowsversion":
            settings.windowsVersion = try parse(value, as: WindowsVersion.self, key: rawKey)
            return true
        case "sync":
            settings.sync = try parse(value, as: SyncMode.self, key: rawKey)
        case "renderer":
            settings.renderer = try parse(value, as: RendererChoice.self, key: rawKey)
        case "retina":
            settings.retina = try bool(value, key: rawKey)
            return true
        case "dpi":
            guard let dpi = Int(value), BottleSettings.dpiRange.contains(dpi) else {
                throw ValidationError("dpi must be an integer in \(BottleSettings.dpiRange), got '\(value)'")
            }
            settings.dpi = dpi
            return true
        case "advertiseavx":
            settings.advertiseAVX = try bool(value, key: rawKey)
        case "metalhud":
            settings.metalHUD = try bool(value, key: rawKey)
        case "metalhudlog":
            settings.metalHUDLog = try bool(value, key: rawKey)
        case "dlssmetalfx":
            settings.dlssMetalFX = try bool(value, key: rawKey)
        case "capturedisplaysforfullscreen":
            settings.captureDisplaysForFullscreen = try bool(value, key: rawKey)
            return true
        case "isolateuserfolders":
            settings.isolateUserFolders = try bool(value, key: rawKey)
        case "dlloverrides":
            settings.dllOverrides = overrides(value)
        case "dlloverrides+":
            for entry in overrides(value) where !settings.dllOverrides.contains(entry) { settings.dllOverrides.append(entry) }
        default:
            throw ValidationError("unknown setting '\(rawKey)' (keys: \(keyHelp))")
        }
        return false
    }

    static func overrides(_ value: String) -> [String] {
        value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parse<T: RawRepresentable & CaseIterable>(_ value: String, as type: T.Type, key: String) throws -> T where T.RawValue == String {
        guard let parsed = T(rawValue: value) else {
            throw ValidationError("\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")), got '\(value)'")
        }
        return parsed
    }

    static func bool(_ value: String, key: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on", "y": return true
        case "0", "false", "no", "off", "n": return false
        default: throw ValidationError("\(key) must be true or false, got '\(value)'")
        }
    }

    static func rows(_ settings: BottleSettings) -> [(String, String)] {
        [
            ("windowsVersion", settings.windowsVersion.rawValue),
            ("sync", settings.sync.rawValue),
            ("renderer", settings.renderer.rawValue),
            ("retina", Table.yesNo(settings.retina)),
            ("dpi", String(settings.dpi)),
            ("advertiseAVX", Table.yesNo(settings.advertiseAVX)),
            ("metalHUD", Table.yesNo(settings.metalHUD)),
            ("metalHUDLog", Table.yesNo(settings.metalHUDLog)),
            ("dlssMetalFX", Table.yesNo(settings.dlssMetalFX)),
            ("captureDisplaysForFullscreen", Table.yesNo(settings.captureDisplaysForFullscreen)),
            ("isolateUserFolders", Table.yesNo(settings.isolateUserFolders)),
            ("dllOverrides", settings.dllOverrides.isEmpty ? "-" : settings.dllOverrides.joined(separator: ";")),
            ("env", settings.env.isEmpty ? "-" : settings.env.keys.sorted().map { "\($0)=\(settings.env[$0] ?? "")" }.joined(separator: " ")),
        ]
    }
}
