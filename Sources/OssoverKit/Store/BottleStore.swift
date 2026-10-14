// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Bottle.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// Creates, lists, loads, saves and deletes bottles under `<home>/bottles/<name>/`.
///
/// A bottle here is its directory and `bottle.json`; the Wine prefix inside it is the Wine
/// stage's business (`Prefix.initialize` runs `wineboot`), so `create` never starts Wine.
public struct BottleStore: Sendable {
    public typealias Log = @Sendable (String) -> Void

    public let paths: OssoverPaths

    public init(paths: OssoverPaths = OssoverPaths()) { self.paths = paths }

    // MARK: Query

    public func names() -> [String] { paths.bottleNames() }

    public func layout(_ name: String) -> BottleLayout { paths.bottleLayout(name) }

    public func exists(_ name: String) -> Bool { layout(name).exists }

    /// Every bottle whose `bottle.json` loads, sorted by name; broken ones are named in `log`.
    public func list(log: Log? = nil) -> [Bottle] {
        names().compactMap { name in
            do {
                return try load(name)
            } catch {
                log?("warning: bottle \(name) skipped: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// `bottles/<name>/bottle.json`, validated. The document's `name` must match the directory.
    public func load(_ name: String) throws -> Bottle {
        guard Bottle.isValidName(name) else { throw OssoverError.invalid("bottle name '\(name)'") }
        let layout = layout(name)
        guard layout.exists else { throw OssoverError.missing("bottle \(name) (no \(Bottle.fileName) in \(layout.root.path))") }
        let bottle = try Bottle.load(from: layout.bottleJSON)
        guard bottle.name == name else {
            throw OssoverError.invalid("bottle \(name): \(Bottle.fileName) says name '\(bottle.name)'")
        }
        return bottle
    }

    /// Names of the bottles that run on `engineID` (what `engine remove` should know).
    public func bottles(usingEngine engineID: String) -> [String] {
        list().filter { $0.engineID == engineID }.map(\.name)
    }

    // MARK: Create

    /// Writes `bottles/<name>/{bottle.json, prefix/, logs/, steamcmd/}`. Does not run `wineboot`.
    /// With `requireEngine` (the default) the engine must be installed, and the bottle is stamped
    /// with it (`engineStamp`, REA L-42): the prefix that `Prefix.initialize` boots next belongs
    /// to that engine id + version. Without an engine check there is nothing to stamp; the first
    /// `ensureInitialized` stamps then.
    @discardableResult
    public func create(name: String, engineID: String, settings: BottleSettings = BottleSettings(),
                       requireEngine: Bool = true) throws -> Bottle {
        guard Bottle.isValidName(name) else { throw OssoverError.invalid("bottle name '\(name)' is not a valid directory name") }
        guard EngineManifest.isValidID(engineID) else { throw OssoverError.invalid("engine id '\(engineID)'") }
        try settings.validate()
        let layout = layout(name)
        guard !FileManager.default.fileExists(atPath: layout.root.path) else {
            throw OssoverError.alreadyExists("bottle \(name) at \(layout.root.path)")
        }
        var stamp: EngineStamp?
        if requireEngine {
            let engine = try EngineStore(paths: paths).engine(engineID)
            guard engine.isInstalled else { throw OssoverError.missing("engine \(engineID): wine loader at \(engine.wine.path)") }
            stamp = EngineStamp(engine: engine)
        }
        try paths.ensureLayout()
        let bottle = Bottle(name: name, engineID: engineID, settings: settings, engineStamp: stamp)
        try bottle.validate()
        do {
            try layout.ensureDirectories()
            try bottle.save(to: layout.bottleJSON)
        } catch {
            try? FileManager.default.removeItem(at: layout.root)
            throw error
        }
        return bottle
    }

    // MARK: Save

    /// Validates and writes `bottle.json` atomically. The bottle's directory must already exist.
    public func save(_ bottle: Bottle) throws {
        try bottle.validate()
        let layout = layout(bottle.name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: layout.root.path, isDirectory: &isDir), isDir.boolValue else {
            throw OssoverError.missing("bottle \(bottle.name) directory \(layout.root.path); create it first")
        }
        try bottle.save(to: layout.bottleJSON)
    }

    // MARK: Initialisation (engine stamp, REA L-42)

    /// Why `ensureInitialized` has to run the prefix-init steps.
    public enum InitializationReason: Equatable, Sendable, CustomStringConvertible {
        /// No `system.reg` yet: the prefix was never booted (`bottle create --no-init`, or a boot that failed).
        case prefixNotInitialised
        /// The prefix exists but `bottle.json` carries no stamp (written before stamps existed).
        case engineStampMissing
        /// The stamp names another engine id or version than the bottle runs on now.
        case engineChanged(from: EngineStamp, to: EngineStamp)

        public var description: String {
            switch self {
            case .prefixNotInitialised: return "prefix not initialised"
            case .engineStampMissing: return "prefix carries no engine stamp"
            case let .engineChanged(from, to): return "engine changed from \(from.summary) to \(to.summary)"
            }
        }
    }

    /// What `ensureInitialized` decides from the stamp, `system.reg` and the prefix's live
    /// processes (`initializationDecision`).
    public enum InitializationDecision: Equatable, Sendable, CustomStringConvertible {
        /// Nothing to run: the stamp matches and the prefix is initialised — `system.reg` exists,
        /// or a wineserver runs for it (the registry lives in that server, so a boot it is the
        /// product of is done whether or not the hive has been flushed yet).
        case upToDate
        /// Run `Prefix.initialize` for `reason`; nothing is alive in the prefix.
        case initialize(InitializationReason)
        /// The steps would have to run for `reason`, but `live` is what still runs in the prefix:
        /// `wineboot -u` under running programs is not the idempotent re-init, and the
        /// `wineserver -w` after it would wait for them, not for the boot (observed as a CLI hang
        /// on a stale `notepad.exe`). The caller stops them first, or fails with them listed.
        case blocked(InitializationReason, live: [ProcessEntry])

        public var description: String {
            switch self {
            case .upToDate: return "prefix up to date"
            case let .initialize(reason): return reason.description
            case let .blocked(reason, live): return "\(reason), but \(live.count) Wine process(es) still run in the prefix"
            }
        }
    }

    /// What `ensureInitialized` did.
    public struct InitializationResult: Sendable {
        /// The bottle as saved (stamped when init ran).
        public var bottle: Bottle
        /// Nil when nothing had to run.
        public var reason: InitializationReason?
        public var report: Prefix.InitReport?
        /// What ran in the prefix when the decision was taken (`WineServer.liveProcesses`). With
        /// `reason == nil` and a wineserver among them, the launch that follows reuses that
        /// server (and must carry its `WINEMSYNC`, `WineRunner.checkServerSync`).
        public var liveProcesses: [ProcessEntry]

        public init(bottle: Bottle, reason: InitializationReason? = nil, report: Prefix.InitReport? = nil,
                    liveProcesses: [ProcessEntry] = []) {
            self.bottle = bottle
            self.reason = reason
            self.report = report
            self.liveProcesses = liveProcesses
        }

        public var ran: Bool { reason != nil }

        /// The prefix's wineserver among `liveProcesses`, when one was running.
        public var runningWineserver: ProcessEntry? { liveProcesses.first(where: WineServer.isWineserver) }
    }

    /// The pure comparison: whether the prefix behind `bottle` must be (re)initialised for
    /// `engine`. CrossOver re-runs its template setup when `[Bottle] Timestamp` differs from the
    /// build's `BuildTimestamp` (REA L-42); here the stamp is the engine id + version.
    public static func initializationReason(bottle: Bottle, engine: Engine, prefixInitialised: Bool) -> InitializationReason? {
        guard prefixInitialised else { return .prefixNotInitialised }
        guard let stamp = bottle.engineStamp else { return .engineStampMissing }
        guard stamp.matches(engine) else { return .engineChanged(from: stamp, to: EngineStamp(engine: engine)) }
        return nil
    }

    /// `initializationReason` against the bottle's directory on disk.
    public func initializationReason(for bottle: Bottle, engine: Engine) -> InitializationReason? {
        Self.initializationReason(bottle: bottle, engine: engine, prefixInitialised: layout(bottle.name).prefixInitialised)
    }

    /// `initializationReason` with the prefix's live processes in the picture. Pure.
    ///
    /// * A running wineserver (`WineServer.isWineserver`) counts as an initialised prefix: the
    ///   registry is in that server, so with a matching stamp there is nothing to run and the
    ///   launch reuses it — never `wineboot -u` into a live prefix for a `system.reg` that is
    ///   merely not flushed yet.
    /// * When the steps do have to run (no boot yet, no stamp, another engine), anything alive
    ///   in the prefix blocks them: `.blocked` carries the reason and the processes, for the
    ///   caller to stop or to list in its error.
    public static func initializationDecision(bottle: Bottle, engine: Engine, prefixInitialised: Bool,
                                              liveProcesses: [ProcessEntry]) -> InitializationDecision {
        let serverRunning = liveProcesses.contains(where: WineServer.isWineserver)
        guard let reason = initializationReason(bottle: bottle, engine: engine, prefixInitialised: prefixInitialised || serverRunning) else {
            return .upToDate
        }
        return liveProcesses.isEmpty ? .initialize(reason) : .blocked(reason, live: liveProcesses)
    }

    /// The launch-time hook (decision 25): boots the prefix when it was never booted, and re-runs
    /// the idempotent init steps (`wineboot -u`, `winecfg -v`, the registry batch, user-folder
    /// isolation — `Prefix.initialize`) when the stamp is missing or names another engine id or
    /// version; then stamps and saves `bottle.json`. Returns at once when the stamp matches and
    /// the prefix is initialised — a wineserver already running for it counts as that, and is
    /// what the launch then reuses (`initializationDecision`). Processes still alive in a prefix
    /// whose steps must run are never booted under: the call fails (`.invalid`) listing them with
    /// the `ossover bottle stop` hint, unless `stopLiveProcesses`, in which case
    /// `WineServer.shutdown` ends them first. `bootWait` caps the `wineserver -w` after wineboot.
    /// `engine` must be the bottle's own (`bottle.engineID`).
    public func ensureInitialized(_ bottle: Bottle, engine: Engine, stopLiveProcesses: Bool = false,
                                  bootWait: TimeInterval = WineServer.bootWait, log: Log? = nil) async throws -> InitializationResult {
        guard engine.id == bottle.engineID else {
            throw OssoverError.invalid("bottle \(bottle.name) runs on engine \(bottle.engineID), not \(engine.id)")
        }
        let layout = layout(bottle.name)
        let live = try await WineServer.liveProcesses(layout: layout, engineRoot: engine.root)
        let reason: InitializationReason
        switch Self.initializationDecision(bottle: bottle, engine: engine, prefixInitialised: layout.prefixInitialised, liveProcesses: live) {
        case .upToDate:
            return InitializationResult(bottle: bottle, liveProcesses: live)
        case let .initialize(why):
            reason = why
        case let .blocked(why, live):
            guard stopLiveProcesses else {
                throw OssoverError.invalid("bottle \(bottle.name): the prefix must be (re)initialised (\(why)), but wineboot must not run while "
                    + WineServer.busyClause(bottle: bottle.name, live: live))
            }
            try requireInstalled(engine, for: bottle)
            log?("\(why), but \(live.count) Wine process(es) still run in the prefix (\(WineServer.describe(live))); stopping them first")
            let shutdown = try await WineRunner(engine: engine, bottle: bottle, paths: paths).shutdown()
            log?(shutdown.summary)
            reason = why
        }
        try requireInstalled(engine, for: bottle)
        log?("\(reason); running the prefix-init steps for engine \(EngineStamp(engine: engine).summary)")
        let report: Prefix.InitReport
        do {
            report = try await Prefix.initialize(bottle: bottle, engine: engine, layout: layout, bootWait: bootWait, log: log)
        } catch {
            // A boot that died after wineboot leaves system.reg behind; without this the stamp
            // written at creation would make the half-initialised prefix look complete.
            if var onDisk = try? Bottle.load(from: layout.bottleJSON), onDisk.engineStamp != nil {
                onDisk.engineStamp = nil
                try? onDisk.save(to: layout.bottleJSON, preservingStamp: false)
            }
            throw error
        }
        // The init path owns the stamp: it goes on the current document and is written as is,
        // never merged with what the file held.
        var stamped = (try? Bottle.load(from: layout.bottleJSON)) ?? bottle
        stamped.engineStamp = report.engineStamp ?? EngineStamp(engine: engine)
        try stamped.validate()
        try stamped.save(to: layout.bottleJSON, preservingStamp: false)
        return InitializationResult(bottle: stamped, reason: reason, report: report)
    }

    /// `ensureInitialized` for a bottle by name, with its engine loaded from the engine store.
    public func ensureInitialized(_ name: String, stopLiveProcesses: Bool = false, bootWait: TimeInterval = WineServer.bootWait,
                                  log: Log? = nil) async throws -> InitializationResult {
        let bottle = try load(name)
        let engine = try EngineStore(paths: paths).engine(bottle.engineID)
        return try await ensureInitialized(bottle, engine: engine, stopLiveProcesses: stopLiveProcesses, bootWait: bootWait, log: log)
    }

    func requireInstalled(_ engine: Engine, for bottle: Bottle) throws {
        guard engine.isInstalled else {
            throw OssoverError.missing("engine \(engine.id) of bottle \(bottle.name) is not installed (wine at \(engine.wine.path))")
        }
    }

    // MARK: Delete

    /// Pids of the Wine processes running in this bottle's prefix (`WineServer.liveProcesses`:
    /// `WINEPREFIX` exact match, or an exe inside the prefix by Unix path; the bottle's engine,
    /// when it loads, widens the match to anything running from its directory).
    public func runningProcesses(of name: String) async throws -> [pid_t] {
        let engineRoot = (try? load(name)).flatMap { try? EngineStore(paths: paths).engine($0.engineID).root }
        return try await WineServer.liveProcesses(layout: layout(name), engineRoot: engineRoot).map(\.pid)
    }

    /// Removes `bottles/<name>` entirely. Refuses while Wine processes of the prefix are alive;
    /// the Wine stage's shutdown (`wineserver -k`, then signals) is how to end them first.
    public func delete(_ name: String) async throws {
        guard Bottle.isValidName(name) else { throw OssoverError.invalid("bottle name '\(name)'") }
        let layout = layout(name)
        guard FileManager.default.fileExists(atPath: layout.root.path) else {
            throw OssoverError.missing("bottle \(name) at \(layout.root.path)")
        }
        let alive = try await runningProcesses(of: name)
        guard alive.isEmpty else {
            throw OssoverError.invalid("bottle \(name) has \(alive.count) running Wine process(es) (pids \(alive.map(String.init).joined(separator: ", "))); stop them first")
        }
        do {
            try FileManager.default.removeItem(at: layout.root)
        } catch {
            throw OssoverError.io("cannot remove \(layout.root.path): \(error.localizedDescription)")
        }
    }
}
