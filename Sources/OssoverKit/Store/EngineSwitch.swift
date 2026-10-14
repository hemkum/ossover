// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `ossover bottle settings <name> --set engine=<id>`: moving a bottle to another installed
/// engine (the same game, two engines, one prefix — an A/B benchmark). The prefix stays; what
/// changes is what the previous engine left in it and what the next launch does with it:
///
/// 1. Nothing may be alive in the prefix (`WineServer.liveProcesses`): a wineserver of the old
///    engine keeps serving its clients, and the re-init that follows must never run under them
///    (`BottleStore.initializationDecision`). Refused with the `ossover bottle stop` hint.
/// 2. A strategy-B renderer overlay the old engine's launches placed (`.renderer-state.json`) is
///    reverted first, before `engineId` changes: the files were chosen against the old engine's
///    capabilities, and `RendererMaterializer.prepare` places (or not) at the next launch
///    against the new one.
/// 3. `bottle.json` gets the new `engineId` and no `engineStamp`, so `BottleStore.ensureInitialized`
///    re-runs the idempotent init (`wineboot -u`, `winecfg -v`, the display registry batch) on
///    the new engine before the first launch (REA L-42, decision 25). Programs, recipes and the
///    Steam state stay as they are.
///
/// ossover-specific: CrossOver has no engine switch, every bottle runs on the one bundled Wine.
public enum EngineSwitch {
    /// The `--set` key (`engine=<id>`; `engineId`/`engine_id` are read the same way).
    public static let settingKey = "engine"

    /// Splits `--set key=value` assignments into the engine switch, when there is one, and the
    /// assignments the settings editor handles. `engine=` is accepted once, with a valid engine
    /// id; an assignment without `=` is passed through for the editor to report. Pure.
    public static func partition(_ assignments: [String]) throws -> (engineID: String?, settings: [String]) {
        var engineID: String?
        var settings: [String] = []
        for assignment in assignments {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                settings.append(assignment)
                continue
            }
            let key = assignment[..<equals].lowercased().filter { $0 != "-" && $0 != "_" }
            guard key == settingKey || key == "engineid" else {
                settings.append(assignment)
                continue
            }
            let value = String(assignment[assignment.index(after: equals)...])
            guard engineID == nil else { throw OssoverError.invalid("--set names the engine twice ('\(assignment)')") }
            guard EngineManifest.isValidID(value) else { throw OssoverError.invalid("engine id '\(value)' in --set \(assignment)") }
            engineID = value
        }
        return (engineID, settings)
    }

    /// What a switch has to do, from the bottle, the prefix's live processes and the overlay
    /// state on disk. Pure.
    public enum Decision: Equatable, Sendable, CustomStringConvertible {
        /// The bottle already runs on that engine: nothing changes, the stamp stays.
        case alreadyOnEngine
        /// Something runs in the prefix; the switch is refused.
        case blocked(live: [ProcessEntry])
        /// Switch: revert the overlay when a state file records one, then rewrite `bottle.json`.
        case proceed(revertOverlay: Bool)

        public var description: String {
            switch self {
            case .alreadyOnEngine: return "already on that engine"
            case let .blocked(live): return "blocked by \(live.count) Wine process(es) in the prefix"
            case let .proceed(revertOverlay): return revertOverlay ? "switch, reverting the renderer overlay first" : "switch"
            }
        }
    }

    public static func decision(bottle: Bottle, to engineID: String, liveProcesses: [ProcessEntry], overlay: RendererState?) -> Decision {
        if bottle.engineID == engineID { return .alreadyOnEngine }
        guard liveProcesses.isEmpty else { return .blocked(live: liveProcesses) }
        return .proceed(revertOverlay: overlay != nil)
    }

    /// The document after the switch: the new engine and no stamp, everything else as it was. Pure.
    public static func rewrite(_ bottle: Bottle, to engineID: String) -> Bottle {
        var switched = bottle
        switched.engineID = engineID
        switched.engineStamp = nil
        return switched
    }

    /// What `BottleStore.switchEngine` did.
    public struct Result: Sendable, Equatable {
        /// The bottle as saved.
        public var bottle: Bottle
        public var previousEngineID: String
        /// The overlay that was in the prefix and is reverted now, when there was one.
        public var revertedOverlay: RendererState?
        /// The files the revert removed (relative to the bottle directory).
        public var removedFiles: [String]

        public init(bottle: Bottle, previousEngineID: String, revertedOverlay: RendererState? = nil, removedFiles: [String] = []) {
            self.bottle = bottle
            self.previousEngineID = previousEngineID
            self.revertedOverlay = revertedOverlay
            self.removedFiles = removedFiles
        }

        /// False when the bottle already ran on the requested engine.
        public var changed: Bool { previousEngineID != bottle.engineID }
    }
}

extension BottleStore {
    /// Moves bottle `name` to `engineID` (see `EngineSwitch`): refuses while the prefix has live
    /// processes, reverts a strategy-B overlay, then saves `bottle.json` with the new engine and
    /// no stamp so the next `ensureInitialized` re-runs the init steps on it. The engine must be
    /// installed. A switch to the engine the bottle already runs on changes nothing.
    public func switchEngine(_ name: String, to engineID: String, log: Log? = nil) async throws -> EngineSwitch.Result {
        let bottle = try load(name)
        let engines = EngineStore(paths: paths)
        let target = try engines.engine(engineID)
        guard target.isInstalled else { throw OssoverError.missing("engine \(engineID): wine loader at \(target.wine.path)") }
        let layout = layout(name)
        // The old engine, when still installed, widens the live match to anything running from its directory.
        let previousRoot = (try? engines.engine(bottle.engineID))?.root
        let live = try await WineServer.liveProcesses(layout: layout, engineRoot: previousRoot)
        let overlay = RendererMaterializer.state(layout: layout)
        switch EngineSwitch.decision(bottle: bottle, to: engineID, liveProcesses: live, overlay: overlay) {
        case .alreadyOnEngine:
            return EngineSwitch.Result(bottle: bottle, previousEngineID: bottle.engineID)
        case let .blocked(live):
            throw OssoverError.invalid("bottle \(name): the engine cannot change while " + WineServer.busyClause(bottle: name, live: live))
        case let .proceed(revertOverlay):
            var removed: [String] = []
            if revertOverlay, let overlay {
                removed = try RendererMaterializer.revert(layout: layout)
                log?("reverted the \(overlay.kind.rawValue) overlay (\(overlay.packID), \(removed.count) file(s)) that engine \(bottle.engineID) placed")
            }
            // Nothing is alive, so a sync-state record left by a server that exited on its own is stale.
            WineServer.clearSyncState(layout: layout)
            let switched = EngineSwitch.rewrite(bottle, to: engineID)
            try switched.validate()
            // The stamp is this writer's to drop: `preservingStamp` would put the old engine's back.
            try switched.save(to: layout.bottleJSON, preservingStamp: false)
            log?("bottle \(name): engine \(bottle.engineID) → \(engineID); the prefix is re-initialised on the next launch")
            return EngineSwitch.Result(bottle: switched, previousEngineID: bottle.engineID,
                                       revertedOverlay: revertOverlay ? overlay : nil, removedFiles: removed)
        }
    }
}
