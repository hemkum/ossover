// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// `ossover bottle settings --set engine=<id>` and `ossover bottle clone`: the pure parts (the
// --set split, the decision, the document rewrite, the clone plan, the cp arguments) and the
// store operations on disk with the fake engine of PrefixBottleTests (no Wine, no network).

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// A strategy-B overlay as `RendererMaterializer.place` leaves it: our d3d11.dll in system32,
/// the engine's own moved aside as `.ossover-orig`, and the state file recording both.
private func placeFakeOverlay(in layout: BottleLayout) throws -> RendererState {
    let dll = layout.system32.appending(path: "d3d11.dll")
    try write(URL(fileURLWithPath: dll.path + RendererMaterializer.backupSuffix), "MZ engine builtin")
    try write(dll, "MZ dxmt copy")
    let placed = PlacedFile(path: "prefix/drive_c/windows/system32/d3d11.dll", sha256: try SHA256Hasher.hex(ofFile: dll),
                            source: "/ossover-test/renderers/dxmt-0.80/wine/d3d11.dll", markStripped: true,
                            backup: "prefix/drive_c/windows/system32/d3d11.dll" + RendererMaterializer.backupSuffix)
    let state = RendererState(kind: .dxmt, packID: "dxmt-0.80", packRoot: "/ossover-test/renderers/dxmt-0.80",
                              strategy: .prefixCopy, placed: [placed])
    try state.save(to: layout.rendererState)
    return state
}

private let gameProgram = Program(id: "game", name: "Game", exe: #"C:\Games\game.exe"#, args: ["-dx11"])

@Suite struct EngineSwitchParsingTests {
    @Test("engine= is split out of --set; the other assignments go to the settings editor untouched, in order")
    func partition() throws {
        let (engine, rest) = try EngineSwitch.partition(["winver=win11", "engine=x64-two", "env.FOO=bar"])
        #expect(engine == "x64-two")
        #expect(rest == ["winver=win11", "env.FOO=bar"])
        #expect(try EngineSwitch.partition([]).engineID == nil)
        let none = try EngineSwitch.partition(["sync=none", "novalue", "=x"])
        #expect(none.engineID == nil)
        #expect(none.settings == ["sync=none", "novalue", "=x"], "malformed assignments are the editor's to report")
    }

    @Test("engineId, engine_id and ENGINE spell the same key; engines= does not")
    func keySpellings() throws {
        for key in ["engineId", "engine_id", "Engine-ID", "ENGINE"] {
            #expect(try EngineSwitch.partition(["\(key)=e2"]).engineID == "e2", "\(key)")
        }
        let other = try EngineSwitch.partition(["engines=e2"])
        #expect(other.engineID == nil && other.settings == ["engines=e2"])
    }

    @Test("an empty or malformed id, or the engine twice, is refused before anything is saved")
    func refusals() {
        #expect(throws: OssoverError.invalid("engine id '' in --set engine=")) { try EngineSwitch.partition(["engine="]) }
        #expect(throws: OssoverError.self) { try EngineSwitch.partition(["engine=has space"]) }
        #expect(throws: OssoverError.invalid("--set names the engine twice ('engineId=b')")) {
            try EngineSwitch.partition(["engine=a", "winver=win10", "engineId=b"])
        }
    }
}

@Suite struct EngineSwitchDecisionTests {
    static let notepad = ProcessEntry(pid: 42, command: #"/e/wine/bin/wine64-preloader C:\windows\system32\notepad.exe WINEPREFIX=/p"#)
    static let overlay = RendererState(kind: .dxmt, packID: "dxmt-0.80", packRoot: "/r/dxmt-0.80", strategy: .prefixCopy, placed: [])

    @Test("same engine is a no-op even under live processes; anything alive blocks; else switch, reverting a recorded overlay")
    func decision() {
        let bottle = Bottle(name: "b", engineID: "e1", engineStamp: EngineStamp(engineID: "e1", version: "r1"))
        #expect(EngineSwitch.decision(bottle: bottle, to: "e1", liveProcesses: [Self.notepad], overlay: Self.overlay) == .alreadyOnEngine)
        #expect(EngineSwitch.decision(bottle: bottle, to: "e2", liveProcesses: [Self.notepad], overlay: nil) == .blocked(live: [Self.notepad]))
        #expect(EngineSwitch.decision(bottle: bottle, to: "e2", liveProcesses: [], overlay: nil) == .proceed(revertOverlay: false))
        #expect(EngineSwitch.decision(bottle: bottle, to: "e2", liveProcesses: [], overlay: Self.overlay) == .proceed(revertOverlay: true))
        #expect(EngineSwitch.Decision.blocked(live: [Self.notepad]).description == "blocked by 1 Wine process(es) in the prefix")
        #expect(EngineSwitch.Decision.proceed(revertOverlay: true).description == "switch, reverting the renderer overlay first")
    }

    @Test("the rewrite changes engineId and drops the stamp; programs, recipes, Steam state and settings stay")
    func rewrite() {
        var bottle = Bottle(name: "b", engineID: "e1", settings: BottleSettings(windowsVersion: .win11, dpi: 120),
                            engineStamp: EngineStamp(engineID: "e1", version: "r1"))
        bottle.programs = [gameProgram]
        bottle.recipesApplied = ["witcher3-4.04-dxmt"]
        bottle.steam = SteamState(appID: 292030, branch: "classic")
        let switched = EngineSwitch.rewrite(bottle, to: "e2")
        #expect(switched.engineID == "e2")
        #expect(switched.engineStamp == nil)
        #expect(switched.programs == bottle.programs)
        #expect(switched.recipesApplied == bottle.recipesApplied)
        #expect(switched.steam == bottle.steam)
        #expect(switched.settings == bottle.settings && switched.created == bottle.created && switched.name == "b")
        #expect(EngineSwitch.Result(bottle: switched, previousEngineID: "e1").changed)
        #expect(!EngineSwitch.Result(bottle: bottle, previousEngineID: "e1").changed)
    }
}

@Suite struct BottleClonePlanTests {
    @Test("the plan renames, re-dates and keeps everything else; the stamp survives only when the engine does")
    func plan() throws {
        var source = Bottle(name: "src", engineID: "e1", settings: BottleSettings(sync: .none, renderer: .dxmt),
                            created: Date(timeIntervalSince1970: 1_000), engineStamp: EngineStamp(engineID: "e1", version: "r1"))
        source.programs = [gameProgram]
        source.recipesApplied = ["r"]
        source.steam = SteamState(appID: 292030, buildID: "123")
        let now = Date(timeIntervalSince1970: 2_000.7)

        let same = try BottleClone.plan(source: source, name: "dst", now: now)
        #expect(same.name == "dst" && same.engineID == "e1")
        #expect(same.engineStamp == source.engineStamp)
        #expect(same.created == Date(timeIntervalSince1970: 2_000), "created=now, whole seconds like every document date")
        #expect(same.programs == source.programs && same.recipesApplied == ["r"] && same.steam == source.steam)
        #expect(same.settings == source.settings && same.schema == Bottle.currentSchema)
        #expect(source.name == "src", "the source document is untouched")

        let other = try BottleClone.plan(source: source, name: "dst", engineID: "e2", now: now)
        #expect(other.engineID == "e2" && other.engineStamp == nil)
        #expect(other.programs == source.programs && other.steam == source.steam)

        let explicitSame = try BottleClone.plan(source: source, name: "dst", engineID: "e1", now: now)
        #expect(explicitSame.engineStamp == source.engineStamp, "naming the source's own engine keeps the stamp")
    }

    @Test("the source's own name, a bad name and a bad engine id are refused")
    func refusals() {
        let source = Bottle(name: "src", engineID: "e1")
        #expect(throws: OssoverError.invalid("a clone of bottle src needs another name")) { try BottleClone.plan(source: source, name: "src") }
        #expect(throws: OssoverError.self) { try BottleClone.plan(source: source, name: ".hidden") }
        #expect(throws: OssoverError.self) { try BottleClone.plan(source: source, name: "a/b") }
        #expect(throws: OssoverError.invalid("engine id 'bad id'")) { try BottleClone.plan(source: source, name: "dst", engineID: "bad id") }
    }

    @Test("cp runs with -c first and plain -R on the fallback, links kept as links")
    func copyArguments() {
        let src = URL(fileURLWithPath: "/h/bottles/a/prefix", isDirectory: true)
        let dst = URL(fileURLWithPath: "/h/bottles/b/prefix", isDirectory: true)
        #expect(BottleClone.copyArguments(from: src, to: dst, clone: true) == ["-c", "-R", "/h/bottles/a/prefix", "/h/bottles/b/prefix"])
        #expect(BottleClone.copyArguments(from: src, to: dst, clone: false) == ["-R", "/h/bottles/a/prefix", "/h/bottles/b/prefix"])
    }
}

@Suite struct EngineSwitchStoreTests {
    @Test("switch: the overlay is reverted before engineId changes, the stamp is dropped, the next init runs on the new engine; same engine is a no-op")
    func switchFlow() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let one = try FakeEngine.install(in: paths, id: "engine-one", version: "r1")
        let two = try FakeEngine.install(in: paths, id: "engine-two", version: "r5")
        let store = BottleStore(paths: paths)
        var created = try store.create(name: "b", engineID: one.id, settings: BottleSettings(windowsVersion: .win11))
        created.programs = [gameProgram]
        created.recipesApplied = ["r"]
        try store.save(created)
        #expect(try await store.ensureInitialized("b").ran)
        let bootCalls = one.calls
        let layout = store.layout("b")
        let overlay = try placeFakeOverlay(in: layout)
        let dll = layout.system32.appending(path: "d3d11.dll")
        let backup = URL(fileURLWithPath: dll.path + RendererMaterializer.backupSuffix)
        try WineServer.recordSyncState(WineServer.SyncState(sync: .msync, winemsync: "1", engineID: one.id), layout: layout)

        // The engine it already runs on: nothing changes, not even the overlay.
        let same = try await store.switchEngine("b", to: one.id)
        #expect(!same.changed && same.revertedOverlay == nil && same.removedFiles.isEmpty)
        #expect(try store.load("b").engineStamp?.engineID == one.id)
        #expect(exists(layout.rendererState))
        #expect(try read(dll) == "MZ dxmt copy")

        // An engine that is not installed: refused, nothing changes.
        await #expect(throws: OssoverError.self) { try await store.switchEngine("b", to: "engine-absent") }
        #expect(try store.load("b").engineID == one.id)

        let lines = LineCollector()
        let result = try await store.switchEngine("b", to: two.id) { lines.append($0) }
        #expect(result.changed && result.previousEngineID == one.id)
        #expect(result.revertedOverlay == overlay)
        #expect(result.removedFiles == [overlay.placed[0].path])
        #expect(try read(dll) == "MZ engine builtin", "the engine's own file is back in system32")
        #expect(!exists(backup))
        #expect(!exists(layout.rendererState))
        #expect(WineServer.syncState(layout: layout) == nil, "a stale sync-state record is cleared like bottle stop does")
        let onDisk = try store.load("b")
        #expect(onDisk.engineID == two.id)
        #expect(onDisk.engineStamp == nil, "no stamp: ensureInitialized re-runs the steps (preservingStamp must not put the old one back)")
        #expect(onDisk.programs == [gameProgram] && onDisk.recipesApplied == ["r"])
        #expect(onDisk.settings == created.settings && onDisk.created == created.created)
        #expect(lines.lines.first == "reverted the dxmt overlay (dxmt-0.80, 1 file(s)) that engine engine-one placed")
        #expect(lines.lines.last == "bottle b: engine engine-one → engine-two; the prefix is re-initialised on the next launch")
        #expect(two.calls.isEmpty && one.calls == bootCalls, "the switch itself runs no Wine on either engine")

        // The next launch's hook: the idempotent init on engine two, then the stamp names it.
        let reinit = try await store.ensureInitialized("b")
        #expect(reinit.reason == .engineStampMissing)
        #expect(two.calls.first == "wine wineboot -u")
        #expect(two.calls.contains { $0.hasPrefix("wine winecfg -v win11") })
        let stamped = try store.load("b")
        #expect(stamped.engineStamp?.engineID == two.id && stamped.engineStamp?.version == "r5")
        #expect(!(try await store.ensureInitialized("b").ran), "stamped: nothing more to run")
    }

    @Test("live processes block the switch with the stop hint; the overlay and bottle.json stay as they were")
    func liveGate() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let one = try FakeEngine.install(in: paths, id: "engine-one")
        let two = try FakeEngine.install(in: paths, id: "engine-two")
        let store = BottleStore(paths: paths)
        _ = try store.create(name: "b", engineID: one.id)
        #expect(try await store.ensureInitialized("b").ran)
        let layout = store.layout("b")
        _ = try placeFakeOverlay(in: layout)

        let notepad = try FakePrefixProcess.start(named: "notepad.exe", in: home, prefix: layout.prefix)
        defer { notepad.stop() }
        let error = await #expect(throws: OssoverError.self) { try await store.switchEngine("b", to: two.id) }
        guard case let .invalid(message)? = error else {
            Issue.record("expected .invalid, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("bottle b: the engine cannot change while 1 Wine process(es) still run in its prefix: pid \(notepad.pid) "))
        #expect(message.hasSuffix("Stop them first: ossover bottle stop b"))
        let untouched = try store.load("b")
        #expect(untouched.engineID == one.id && untouched.engineStamp?.engineID == one.id)
        #expect(exists(layout.rendererState))
        #expect(try read(layout.system32.appending(path: "d3d11.dll")) == "MZ dxmt copy")
    }
}

@Suite struct BottleCloneStoreTests {
    @Test("clone: same prefix contents, bottle.json renamed with programs kept, overlay reverted in the clone only, fresh logs and steamcmd")
    func cloneFlow() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let one = try FakeEngine.install(in: paths, id: "engine-one")
        let store = BottleStore(paths: paths)
        var created = try store.create(name: "b", engineID: one.id, settings: BottleSettings(sync: .none, dpi: 120))
        created.programs = [gameProgram]
        created.recipesApplied = ["r"]
        created.steam = SteamState(appID: 292030, buildID: "123")
        try store.save(created)
        #expect(try await store.ensureInitialized("b").ran)
        let layout = store.layout("b")
        let overlay = try placeFakeOverlay(in: layout)
        let game = layout.driveC.appending(path: "Games/game.bin")
        try write(game, "bytes")
        try FileManager.default.createDirectory(at: layout.prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.prefix.appending(path: "dosdevices/z:").path, withDestinationPath: "/")
        try write(layout.logs.appending(path: "old.log"), "log")
        try write(layout.steamcmd.appending(path: "fetch-292030.txt"), "script")
        try WineServer.recordSyncState(WineServer.SyncState(sync: .none, winemsync: "0", engineID: one.id), layout: layout)
        let before = Date().secondPrecision

        let lines = LineCollector()
        let result = try await store.clone("b", to: "c") { lines.append($0) }
        #expect(result.usedCloneFlag)
        #expect(result.bottle.name == "c" && result.bottle.engineID == one.id)
        #expect(result.bottle.engineStamp?.engineID == one.id, "same engine: the stamp that initialised these bytes stays")
        #expect(result.bottle.created >= before)
        let clone = store.layout("c")
        let loaded = try store.load("c")
        #expect(loaded == result.bottle)
        #expect(loaded.programs == [gameProgram] && loaded.recipesApplied == ["r"] && loaded.steam == created.steam)
        #expect(loaded.settings == created.settings)
        #expect(store.names() == ["b", "c"])

        // The prefix: the same files, links kept as links, system.reg (the clone counts as booted).
        #expect(clone.prefixInitialised)
        #expect(try read(clone.driveC.appending(path: "Games/game.bin")) == "bytes")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: clone.prefix.appending(path: "dosdevices/z:").path) == "/")
        // The overlay: reverted in the clone, intact in the source.
        #expect(result.revertedOverlay == overlay && result.removedFiles == [overlay.placed[0].path])
        #expect(try read(clone.system32.appending(path: "d3d11.dll")) == "MZ engine builtin")
        #expect(!exists(clone.system32.appending(path: "d3d11.dll" + RendererMaterializer.backupSuffix)))
        #expect(!exists(clone.rendererState))
        #expect(try read(layout.system32.appending(path: "d3d11.dll")) == "MZ dxmt copy")
        #expect(RendererMaterializer.state(layout: layout) == overlay)
        #expect(lines.lines.contains { $0.hasPrefix("reverted the dxmt overlay (dxmt-0.80, 1 file(s)) in the clone") })
        // Fresh logs/, steamcmd/, no sync-state record.
        #expect(try FileManager.default.contentsOfDirectory(atPath: clone.logs.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clone.steamcmd.path).isEmpty)
        #expect(WineServer.syncState(layout: clone) == nil)
        // A write in the clone does not reach the source.
        try write(clone.driveC.appending(path: "Games/game.bin"), "changed")
        #expect(try read(game) == "bytes")
        // Same engine, stamped: the clone's first launch has nothing to run.
        #expect(!(try await store.ensureInitialized("c").ran))
        #expect(one.calls.filter { $0 == "wine wineboot -u" }.count == 1)
    }

    @Test("--engine: the clone starts without a stamp and its first init runs on that engine; an absent engine is refused")
    func cloneToOtherEngine() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let one = try FakeEngine.install(in: paths, id: "engine-one")
        let two = try FakeEngine.install(in: paths, id: "engine-two", version: "r5")
        let store = BottleStore(paths: paths)
        _ = try store.create(name: "b", engineID: one.id)
        #expect(try await store.ensureInitialized("b").ran)

        await #expect(throws: OssoverError.self) { try await store.clone("b", to: "d", engineID: "engine-absent") }
        #expect(!exists(store.layout("d").root), "nothing is left behind")

        let result = try await store.clone("b", to: "c", engineID: two.id)
        #expect(result.bottle.engineID == two.id && result.bottle.engineStamp == nil)
        #expect(try store.load("c").engineStamp == nil)
        let reinit = try await store.ensureInitialized("c")
        #expect(reinit.reason == .engineStampMissing)
        #expect(two.calls.first == "wine wineboot -u")
        #expect(try store.load("c").engineStamp?.version == "r5")
        let source = try store.load("b")
        #expect(source.engineID == one.id && source.engineStamp?.engineID == one.id, "the source is untouched")
    }

    @Test("refused when the destination exists or the source has live processes; a never-booted source clones as an empty prefix")
    func refusals() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let one = try FakeEngine.install(in: paths, id: "engine-one")
        let store = BottleStore(paths: paths)
        _ = try store.create(name: "b", engineID: one.id)
        #expect(try await store.ensureInitialized("b").ran)
        let layout = store.layout("b")
        _ = try store.create(name: "c", engineID: one.id)

        let taken = await #expect(throws: OssoverError.self) { try await store.clone("b", to: "c") }
        guard case .alreadyExists? = taken else {
            Issue.record("expected .alreadyExists, got \(String(describing: taken))")
            return
        }
        #expect(try store.load("c").created <= Date(), "the existing bottle is left alone")
        await #expect(throws: OssoverError.self, "cloning onto itself") { try await store.clone("b", to: "b") }

        let notepad = try FakePrefixProcess.start(named: "notepad.exe", in: home, prefix: layout.prefix)
        defer { notepad.stop() }
        let busy = await #expect(throws: OssoverError.self) { try await store.clone("b", to: "d") }
        guard case let .invalid(message)? = busy else {
            Issue.record("expected .invalid, got \(String(describing: busy))")
            return
        }
        #expect(message.hasPrefix("bottle b: cannot be cloned while 1 Wine process(es) still run in its prefix: pid \(notepad.pid) "))
        #expect(message.hasSuffix("Stop them first: ossover bottle stop b"))
        #expect(!exists(store.layout("d").root))
        notepad.stop()

        // A source created with --no-init: an empty prefix directory, the stamp from creation kept.
        _ = try store.create(name: "fresh", engineID: one.id)
        let fresh = try await store.clone("fresh", to: "fresh2")
        #expect(!store.layout("fresh2").prefixInitialised)
        #expect(exists(store.layout("fresh2").prefix) && exists(store.layout("fresh2").logs))
        #expect(fresh.bottle.engineStamp?.engineID == one.id && fresh.revertedOverlay == nil)
    }
}
