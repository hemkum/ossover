// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `ossover bottle clone <src> <dst>`: a second bottle with the same prefix, so the same game
/// can run on two engines side by side. The prefix is copied with `cp -c -R` (clonefile(2)):
/// on APFS the clone shares the game's blocks with the source until one of them writes, so a
/// tens-of-GB install costs no second copy. `cp -c` copies bytes by itself where cloning is
/// impossible (another volume, a non-APFS volume), and a `cp` that fails outright is retried as
/// a plain `cp -R` with a warning. The clone starts with no renderer overlay (what strategy B
/// placed is reverted in the copy, `RendererMaterializer.revert`, and placed again at its
/// first launch), empty `logs/` and `steamcmd/`, and no sync-state record.
///
/// ossover-specific: CrossOver's bottle duplication is a byte copy.
public enum BottleClone {
    /// The clone's `bottle.json`: the source document under the new name, created `now`, on
    /// `engineID` when given. The stamp stays when the engine does (the prefix is the same
    /// bytes, initialised by that engine) and is dropped when it changes, so the clone's first
    /// launch re-runs the init steps on the new engine (`BottleStore.ensureInitialized`).
    /// Programs, recipes and the Steam state are kept. Pure.
    public static func plan(source: Bottle, name: String, engineID: String? = nil, now: Date = Date()) throws -> Bottle {
        guard Bottle.isValidName(name) else { throw OssoverError.invalid("bottle name '\(name)' is not a valid directory name") }
        guard name != source.name else { throw OssoverError.invalid("a clone of bottle \(name) needs another name") }
        if let engineID, !EngineManifest.isValidID(engineID) { throw OssoverError.invalid("engine id '\(engineID)'") }
        let target = engineID ?? source.engineID
        var clone = source
        clone.schema = Bottle.currentSchema
        clone.name = name
        clone.created = now.secondPrecision
        clone.engineID = target
        if target != source.engineID { clone.engineStamp = nil }
        return clone
    }

    /// The `cp` arguments for the prefix: `-c` (clonefile) on the first try, plain `-R` on the
    /// fallback. `-R` without `-L`/`-H` keeps `dosdevices/z:` and the user-folder links as
    /// links. Pure.
    public static func copyArguments(from source: URL, to destination: URL, clone: Bool) -> [String] {
        (clone ? ["-c"] : []) + ["-R", source.path, destination.path]
    }

    /// What `BottleStore.clone` did.
    public struct Result: Sendable, Equatable {
        /// The clone as saved.
        public var bottle: Bottle
        /// True when `cp -c -R` succeeded. `cp -c` falls back to a byte copy on its own when the
        /// volume cannot clone, so this says the clone flag was honoured, not that blocks are
        /// shared; false means the plain `cp -R` fallback ran.
        public var usedCloneFlag: Bool
        /// The source's overlay, reverted in the clone, when the source had one.
        public var revertedOverlay: RendererState?
        /// The files the revert removed from the clone (relative to its directory).
        public var removedFiles: [String]

        public init(bottle: Bottle, usedCloneFlag: Bool, revertedOverlay: RendererState? = nil, removedFiles: [String] = []) {
            self.bottle = bottle
            self.usedCloneFlag = usedCloneFlag
            self.revertedOverlay = revertedOverlay
            self.removedFiles = removedFiles
        }
    }
}

extension BottleStore {
    /// Clones bottle `sourceName` to a new bottle `name` (see `BottleClone`). Refuses while the
    /// source has live Wine processes (a prefix mid-write is not a consistent copy) and when the
    /// destination exists. With `engineID` the clone runs on that engine, which must be
    /// installed, and starts without a stamp. A failure part way removes the half-made clone.
    public func clone(_ sourceName: String, to name: String, engineID: String? = nil, log: Log? = nil) async throws -> BottleClone.Result {
        let source = try load(sourceName)
        let sourceLayout = layout(sourceName)
        let planned = try BottleClone.plan(source: source, name: name, engineID: engineID)
        try planned.validate()
        let destination = layout(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.root.path) else {
            throw OssoverError.alreadyExists("bottle \(name) at \(destination.root.path)")
        }
        let engines = EngineStore(paths: paths)
        if let engineID {
            let engine = try engines.engine(engineID)
            guard engine.isInstalled else { throw OssoverError.missing("engine \(engineID): wine loader at \(engine.wine.path)") }
        }
        let sourceRoot = (try? engines.engine(source.engineID))?.root
        let live = try await WineServer.liveProcesses(layout: sourceLayout, engineRoot: sourceRoot)
        guard live.isEmpty else {
            throw OssoverError.invalid("bottle \(sourceName): cannot be cloned while " + WineServer.busyClause(bottle: sourceName, live: live))
        }
        try paths.ensureLayout()
        do {
            try fm.createDirectory(at: destination.root, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(destination.root.path): \(error.localizedDescription)")
        }
        do {
            var usedCloneFlag = true
            if fm.fileExists(atPath: sourceLayout.prefix.path) {
                usedCloneFlag = try await Self.copyPrefix(from: sourceLayout.prefix, to: destination.prefix, log: log)
            }
            try destination.ensureDirectories()   // prefix when the source had none; fresh logs/ and steamcmd/
            var reverted: RendererState?
            var removed: [String] = []
            if let overlay = RendererMaterializer.state(layout: sourceLayout) {
                // The placed files came along with the prefix; their record is what revert needs.
                do {
                    try fm.copyItem(at: sourceLayout.rendererState, to: destination.rendererState)
                } catch {
                    throw OssoverError.io("cannot copy \(sourceLayout.rendererState.path): \(error.localizedDescription)")
                }
                removed = try RendererMaterializer.revert(layout: destination)
                reverted = overlay
                log?("reverted the \(overlay.kind.rawValue) overlay (\(overlay.packID), \(removed.count) file(s)) in the clone; its first launch places it again")
            }
            try planned.save(to: destination.bottleJSON, preservingStamp: false)
            return BottleClone.Result(bottle: planned, usedCloneFlag: usedCloneFlag, revertedOverlay: reverted, removedFiles: removed)
        } catch {
            try? fm.removeItem(at: destination.root)
            throw error
        }
    }

    /// `cp -c -R`, then `cp -R` when that fails (warned through `log`). Returns whether the
    /// clone flag was honoured.
    static func copyPrefix(from source: URL, to destination: URL, log: Log?) async throws -> Bool {
        let cloneArgs = BottleClone.copyArguments(from: source, to: destination, clone: true)
        let cloned = try await Shell.run(executable: "/bin/cp", args: cloneArgs)
        if cloned.succeeded { return true }
        let tail = OssoverError.tail(of: cloned.combined, lines: 3)
        log?("warning: \(Shell.commandLine("/bin/cp", cloneArgs)) failed (exit \(cloned.status))" + (tail.isEmpty ? "" : ": \(tail)")
            + "; copying the prefix byte by byte with cp -R instead")
        try? FileManager.default.removeItem(at: destination)
        let copyArgs = BottleClone.copyArguments(from: source, to: destination, clone: false)
        _ = try await Shell.run(executable: "/bin/cp", args: copyArgs).check(command: Shell.commandLine("/bin/cp", copyArgs))
        return false
    }
}
