// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Decisions 22–26 (REA L-38…L-43): the display registry batch and its reboot, the wined3d
// fallback knob, the engine stamp on bottle.json with the launch-time re-init, and the single
// win64 init path.

/// An engine whose `wine` and `wineserver` are shell scripts: every call is appended to
/// `calls.log` beside the loader, and `wineboot` creates the prefix's `system.reg` the way the
/// real one would. Enough to drive `Prefix.initialize`, `Prefix.applyDisplaySettings` and
/// `BottleStore.ensureInitialized` end to end without Wine.
struct FakeEngine {
    let paths: OssoverPaths
    let id: String

    var root: URL { paths.engine(id) }
    var callsLog: URL { root.appending(path: "wine/bin/calls.log") }

    static func install(in paths: OssoverPaths, id: String = "fake-engine", version: String = "r1") throws -> FakeEngine {
        let fake = FakeEngine(paths: paths, id: id)
        try fake.writeManifest(version: version)
        let fm = FileManager.default
        let bin = fake.root.appending(path: "wine/bin", directoryHint: .isDirectory)
        try fm.createDirectory(at: fake.root.appending(path: "wine/lib/wine/x86_64-unix", directoryHint: .isDirectory),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = """
            #!/bin/sh
            dir="$(cd "$(dirname "$0")" && pwd)"
            printf 'wine %s\\n' "$*" >> "$dir/calls.log"
            case "$1" in
              wineboot) mkdir -p "$WINEPREFIX/drive_c/users/crossover" && : > "$WINEPREFIX/system.reg" ;;
              winecfg) [ -e "$dir/fail-winecfg" ] && exit 1 ;;
            esac
            exit 0
            """
        // With the `hang-wait` marker `-w` never returns on its own (a server kept alive by a
        // client); `exec` so the cap's SIGTERM ends the sleeper itself, not just the shell.
        let wineserver = """
            #!/bin/sh
            dir="$(cd "$(dirname "$0")" && pwd)"
            printf 'wineserver %s\\n' "$*" >> "$dir/calls.log"
            if [ "$1" = -w ] && [ -e "$dir/hang-wait" ]; then exec sleep 5; fi
            exit 0
            """
        for (name, body) in [("wine", wine), ("wineserver", wineserver)] {
            let url = bin.appending(path: name)
            try Data(body.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return fake
    }

    /// (Re)writes `manifest.json`; a new `version` is what an engine upgrade in place looks like.
    func writeManifest(version: String) throws {
        var manifest = Fixtures.manifest(id: id, capabilities: Fixtures.crossOver, requires: [])
        manifest.version = version
        try JSONDocument.save(manifest, to: root.appending(path: Engine.manifestFileName))
    }

    func engine() throws -> Engine { try EngineStore(paths: paths).engine(id) }

    /// Makes `winecfg` exit 1 (a boot that dies after wineboot), or lets it succeed again.
    func failWinecfg(_ fail: Bool) throws {
        let marker = root.appending(path: "wine/bin/fail-winecfg")
        if fail { try Data().write(to: marker) } else { try? FileManager.default.removeItem(at: marker) }
    }

    /// Makes `wineserver -w` block (a server that something keeps alive), or return at once again.
    func hangWait(_ hang: Bool) throws {
        let marker = root.appending(path: "wine/bin/hang-wait")
        if hang { try Data().write(to: marker) } else { try? FileManager.default.removeItem(at: marker) }
    }

    var calls: [String] {
        (try? String(contentsOf: callsLog, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
}

/// A process the process table shows as a member of a prefix: `WINEPREFIX=<prefix>` in its
/// environment and a Wine-looking argv[0] (`notepad.exe`, `wineserver`), or an exe path inside
/// the prefix with no such word (what Wine's command-line rewrite leaves). It is a tiny compiled
/// sleeper started through a symlink of that name — Apple's own `/bin/sleep` would not do, the
/// kernel hides a platform binary's environment from `ps -E` and `KERN_PROCARGS2`. It runs as
/// an orphan (backgrounded by a `sh` that exits at once), so launchd reaps it the moment a
/// signal ends it, like a real Wine process reparented to launchd; Foundation's `Process` is
/// not used, its `waitUntilExit` after an external kill does not reliably return.
final class FakePrefixProcess: Sendable {
    /// Compiled once per test process into a fixed place under the temporary directory.
    static let sleeper: URL? = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "ossover-tests-sleeper", directoryHint: .isDirectory)
        let binary = directory.appending(path: "sleeper")
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: binary.path) { return binary }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appending(path: "sleeper-\(getpid()).c")
            try Data("#include <unistd.h>\nint main(void) { sleep(300); return 0; }\n".utf8).write(to: source)
            let fresh = directory.appending(path: "sleeper-\(getpid())")
            try Shell.runSync(executable: "/usr/bin/cc", args: ["-o", fresh.path, source.path], timeout: 120)
                .check(command: "cc")
            try? fm.removeItem(at: source)
            // Another test process may be compiling too: rename is atomic, the loser's copy is dropped.
            if (try? fm.moveItem(at: fresh, to: binary)) == nil { try? fm.removeItem(at: fresh) }
            return fm.isExecutableFile(atPath: binary.path) ? binary : nil
        } catch {
            return nil
        }
    }()

    let pid: pid_t

    private init(pid: pid_t) { self.pid = pid }

    /// Starts the sleeper as `<directory>/<name>` with `WINEPREFIX` set to the layout's prefix
    /// (or `environment` as given: `[:]` is how a program whose command line Wine rewrote looks;
    /// the shell's own PATH/HOME words are there either way, as every process has some).
    static func start(named name: String, in directory: URL, prefix: URL, environment: [String: String]? = nil) throws -> FakePrefixProcess {
        let sleeper = try #require(Self.sleeper, "a C compiler is needed to build the live-process fixture")
        let link = directory.appending(path: name)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: sleeper.path)
        let result = try Shell.runSync(executable: "/bin/sh", args: ["-c", "\"$0\" </dev/null >/dev/null 2>&1 & echo $!", link.path],
                                       env: environment ?? ["WINEPREFIX": prefix.path], timeout: 10).check(command: "sh")
        let pid = try #require(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), "sh printed no pid: \(result.stdout)")
        // Give the table a moment to show it.
        let deadline = Date().addingTimeInterval(5)
        while !ProcessTable.isAlive(pid), Date() < deadline { usleep(20_000) }
        return FakePrefixProcess(pid: pid)
    }

    var isRunning: Bool { ProcessTable.isAlive(pid) }

    /// SIGTERM, then waits (up to five seconds) for launchd to have reaped it.
    func stop() {
        if isRunning { Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while isRunning, Date() < deadline { usleep(20_000) }
    }
}

@Suite struct PrefixDisplayTests {
    @Test("RetinaMode and LogPixels live on the global keys; cb_access_map_w is the only inf value kept")
    func displayBatch() {
        let settings = BottleSettings(retina: true, dpi: Prefix.highResolutionDPI, captureDisplaysForFullscreen: true)
        let display = Prefix.displayEntries(for: settings)
        #expect(display.map(\.key) == [Prefix.macDriverKey, Prefix.macDriverKey, Prefix.desktopKey])
        #expect(display.map(\.name) == ["RetinaMode", "CaptureDisplaysForFullscreen", "LogPixels"])
        #expect(display.map(\.data) == ["y", "y", "192"])
        #expect(display.map(\.type) == [.string, .string, .dword])
        #expect(Prefix.highResolutionDPI == 192, "U-6: the plan's assumption, not a CrossOver observation")
        #expect(Prefix.macDriverKey == #"HKCU\Software\Wine\Mac Driver"#)
        #expect(Prefix.desktopKey == #"HKCU\Control Panel\Desktop"#)
        #expect(Prefix.wined3dFallbackEntries == [.dword(#"HKCU\Software\Wine\Direct3D"#, "cb_access_map_w", 1)])
        let batch = Prefix.registryEntries(for: settings)
        #expect(batch == display + Prefix.wined3dFallbackEntries)
        for entry in batch {
            #expect(!entry.key.contains("AppDefaults"), "RetinaMode is read from the global key only (L-40)")
            #expect(!entry.key.contains("Systray") && !entry.key.contains("X11 Driver") && !entry.key.contains("Explorer"),
                    "no reader for CX's Systray\\Hidden / X11 Driver\\ShowSystray in the 26.3.0 tree (L-38)")
            #expect(!entry.key.hasPrefix("HKLM"), "nothing version-related: winecfg -v writes CurrentBuild/UBR itself (L-38)")
        }
        #expect(Prefix.displayEntries(for: BottleSettings(retina: false, dpi: 96)).map(\.data) == ["n", "n", "96"])
        #expect(Prefix.winebootEnvironment == ["WINEARCH": "win64"], "64-bit prefixes only (L-43)")
        #expect(Prefix.wineArch == "win64")
    }

    @Test("a display change on a booted prefix writes the batch and, with restart, reboots the bottle")
    func applyDisplaySettingsRestarts() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths)
        let engine = try fake.engine()
        let store = BottleStore(paths: paths)
        let bottle = try store.create(name: "b", engineID: fake.id, settings: BottleSettings(retina: false, dpi: 120))
        let layout = store.layout("b")

        await #expect(throws: OssoverError.self) {
            try await Prefix.applyDisplaySettings(bottle: bottle, engine: engine, layout: layout)
        }
        await #expect(throws: OssoverError.self) {
            try await Prefix.applySettings(bottle: bottle, engine: engine, layout: layout)
        }
        #expect(fake.calls.isEmpty, "an unbooted prefix gets the values at its first boot; no Wine runs")

        try FileManager.default.createDirectory(at: layout.prefix, withIntermediateDirectories: true)
        try Data().write(to: layout.systemReg)
        let noRestart = try await Prefix.applyDisplaySettings(bottle: bottle, engine: engine, layout: layout, restart: false)
        #expect(noRestart == nil)
        #expect(fake.calls.count == 1)
        #expect(fake.calls[0].hasPrefix("wine regedit /S C:\\windows\\temp\\ossover-"))

        let lines = LineCollector()
        let report = try await Prefix.applyDisplaySettings(bottle: bottle, engine: engine, layout: layout, restart: true) { lines.append($0) }
        #expect(report?.serverWasRunning == true)
        let calls = fake.calls
        #expect(calls.count == 4)
        #expect(calls[1].hasPrefix("wine regedit /S "))
        #expect(Array(calls.suffix(2)) == ["wineserver -k", "wineserver -w"], "wineserver -k → -w: the next launch starts a fresh server")
        #expect(lines.lines.contains("registry: RetinaMode=n, CaptureDisplaysForFullscreen=n, LogPixels=120"))

        let full = try await Prefix.applySettings(bottle: bottle, engine: engine, layout: layout, restart: true)
        #expect(full != nil)
        #expect(fake.calls[4] == "wine winecfg -v win10", "the full re-apply sets the Windows version first")
        #expect(fake.calls.count == 8)
    }
}

@Suite struct EngineStampTests {
    static let engine = Fixtures.engine(id: "e1", capabilities: Fixtures.crossOver)

    @Test("the stamp records engine id + manifest version and round-trips through bottle.json")
    func stampRoundTrip() throws {
        let stamp = EngineStamp(engine: Self.engine, stampedAt: Date(timeIntervalSince1970: 1_791_892_800.7))
        #expect(stamp.engineID == "e1")
        #expect(stamp.version == "r1")
        #expect(stamp.stampedAt == Date(timeIntervalSince1970: 1_791_892_800), "second precision, like every date on disk")
        #expect(stamp.matches(Self.engine))
        var upgraded = Fixtures.manifest(id: "e1", capabilities: Fixtures.crossOver)
        upgraded.version = "r2"
        #expect(!stamp.matches(Engine(root: Fixtures.paths.engine("e1"), manifest: upgraded)), "same id, other version")
        #expect(!stamp.matches(Fixtures.engine(id: "e2", capabilities: Fixtures.crossOver)), "other id")
        #expect(stamp.summary == "e1 r1")
        #expect(EngineStamp(engineID: "e1", version: "").summary == "e1")

        let bottle = Bottle(name: "b", engineID: "e1", engineStamp: stamp)
        let encoded = String(decoding: try JSONDocument.encode(bottle), as: UTF8.self)
        #expect(encoded.contains("\"engineStamp\""))
        #expect(encoded.contains("\"stampedAt\""))
        #expect(encoded.contains("2026-10-13T12:00:00Z"))
        #expect(!encoded.contains("\"engineID\""), "the key is engineId, as on the bottle itself")
        let again = try JSONDocument.decode(Bottle.self, from: Data(encoded.utf8))
        #expect(again == bottle)
        #expect(again.engineStamp == stamp)
    }

    @Test("a bottle.json written before stamps existed loads with no stamp, and a bad stamp id fails validation")
    func legacyBottleHasNoStamp() throws {
        let bottle = try Bottle.load(from: Fixtures.url("bottles/witcher3/bottle.json"))
        #expect(bottle.engineStamp == nil)
        let encoded = String(decoding: try JSONDocument.encode(bottle), as: UTF8.self)
        #expect(!encoded.contains("engineStamp"), "nil is left out, not written as null")
        let bad = Bottle(name: "b", engineID: "e1", engineStamp: EngineStamp(engineID: ".bad", version: "r1"))
        #expect(throws: OssoverError.self) { try bad.validate() }
        try Bottle(name: "b", engineID: "e1", engineStamp: EngineStamp(engineID: "e1", version: "r1")).validate()
    }

    @Test("save keeps the stamp on disk unless the copy being saved carries a strictly newer one")
    func saveKeepsNewerStamp() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "bottle.json")
        let older = EngineStamp(engineID: "e1", version: "r1", stampedAt: Date(timeIntervalSince1970: 1_000))
        let newer = EngineStamp(engineID: "e1", version: "r2", stampedAt: Date(timeIntervalSince1970: 2_000))
        let tie = EngineStamp(engineID: "e1", version: "r2-tie", stampedAt: Date(timeIntervalSince1970: 2_000))
        let newest = EngineStamp(engineID: "e1", version: "r3", stampedAt: Date(timeIntervalSince1970: 3_000))
        let unstamped = Bottle(name: "b", engineID: "e1")

        #expect(unstamped.withStampPreserved(from: url) == unstamped, "no file: nothing to keep")
        try unstamped.save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == nil)
        try Bottle(name: "b", engineID: "e1", engineStamp: older).save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == older, "a stamp over no stamp is written")
        try Bottle(name: "b", engineID: "e1", engineStamp: newer).save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == newer, "a newer stamp replaces an older one")
        try unstamped.save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == newer, "an unstamped copy keeps the stamp on disk")
        try Bottle(name: "b", engineID: "e1", engineStamp: older).save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == newer, "an older stamp does not roll it back")
        try Bottle(name: "b", engineID: "e1", engineStamp: tie).save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == newer, "same second: the disk wins (the copy is the stale one)")
        try Bottle(name: "b", engineID: "e1", engineStamp: newest).save(to: url)
        #expect(try Bottle.load(from: url).engineStamp == newest)

        try Bottle(name: "b", engineID: "e1", engineStamp: older).save(to: url, preservingStamp: false)
        #expect(try Bottle.load(from: url).engineStamp == older, "the init path writes its stamp as is")
        try unstamped.save(to: url, preservingStamp: false)
        #expect(try Bottle.load(from: url).engineStamp == nil)

        try Bottle(name: "b", engineID: "e1", engineStamp: newest).save(to: url)
        var edited = try Bottle.load(from: url)
        edited.engineStamp = nil
        edited.programs = [Program(id: "p", name: "P", exe: #"C:\p.exe"#)]
        try edited.save(to: url)
        let reloaded = try Bottle.load(from: url)
        #expect(reloaded.programs.map(\.id) == ["p"], "the rest of the document is written as given")
        #expect(reloaded.engineStamp == newest)
    }
}

@Suite struct BottleStoreInitializationTests {
    @Test("why a prefix must be (re)initialised: never booted, unstamped, or stamped by another engine")
    func reasons() {
        let engine = Fixtures.engine(id: "e1", capabilities: Fixtures.crossOver)
        let stamp = EngineStamp(engine: engine)
        let stamped = Bottle(name: "b", engineID: "e1", engineStamp: stamp)
        #expect(BottleStore.initializationReason(bottle: stamped, engine: engine, prefixInitialised: false) == .prefixNotInitialised)
        #expect(BottleStore.initializationReason(bottle: stamped, engine: engine, prefixInitialised: true) == nil)
        #expect(BottleStore.initializationReason(bottle: Bottle(name: "b", engineID: "e1"), engine: engine, prefixInitialised: true)
                == .engineStampMissing)
        #expect(BottleStore.initializationReason(bottle: Bottle(name: "b", engineID: "e1"), engine: engine, prefixInitialised: false)
                == .prefixNotInitialised, "an unbooted prefix is the first reason, stamp or not")

        var upgraded = Fixtures.manifest(id: "e1", capabilities: Fixtures.crossOver)
        upgraded.version = "r2"
        let newEngine = Engine(root: Fixtures.paths.engine("e1"), manifest: upgraded)
        let reason = BottleStore.initializationReason(bottle: stamped, engine: newEngine, prefixInitialised: true)
        guard case let .engineChanged(from, to)? = reason else {
            Issue.record("expected engineChanged, got \(String(describing: reason))")
            return
        }
        #expect(from == stamp)
        #expect(to.engineID == "e1" && to.version == "r2")
        #expect(reason?.description == "engine changed from e1 r1 to e1 r2")
        #expect(BottleStore.InitializationReason.engineStampMissing.description == "prefix carries no engine stamp")

        // The store's own check reads system.reg from the bottle directory.
        #expect(Fixtures.paths.bottleLayout("b").prefixInitialised == false)
        #expect(BottleStore(paths: Fixtures.paths).initializationReason(for: stamped, engine: engine) == .prefixNotInitialised)
    }

    @Test("create stamps the bottle; ensureInitialized boots, is a no-op on a matching stamp, and re-runs on an engine change")
    func ensureInitializedFlow() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths, version: "r1")
        let store = BottleStore(paths: paths)

        #expect(try store.create(name: "unstamped", engineID: "absent-engine", requireEngine: false).engineStamp == nil,
                "no engine check, nothing to stamp")
        let created = try store.create(name: "b", engineID: fake.id)
        #expect(created.engineStamp?.engineID == fake.id)
        #expect(created.engineStamp?.version == "r1")
        #expect(try store.load("b").engineStamp == created.engineStamp)
        let layout = store.layout("b")
        #expect(!layout.prefixInitialised)

        let lines = LineCollector()
        let first = try await store.ensureInitialized("b") { lines.append($0) }
        #expect(first.ran)
        #expect(first.reason == .prefixNotInitialised)
        #expect(first.report?.windowsVersion == .win10)
        #expect(first.report?.engineStamp?.version == "r1")
        #expect(first.bottle.engineStamp?.version == "r1")
        #expect(layout.prefixInitialised)
        let calls = fake.calls
        #expect(calls.first == "wine wineboot -u")
        #expect(calls.contains("wineserver -w"))
        #expect(calls.contains("wine winecfg -v win10"))
        #expect(calls.contains { $0.hasPrefix("wine regedit /S C:\\windows\\temp\\ossover-") })
        #expect(Array(calls.suffix(2)) == ["wineserver -k", "wineserver -w"], "the boot ends with a shutdown so the next launch starts fresh")
        #expect(try store.load("b").engineStamp?.version == "r1")
        #expect(lines.lines.contains { $0.hasPrefix("prefix not initialised; running the prefix-init steps for engine fake-engine r1") })

        let again = try await store.ensureInitialized("b")
        #expect(!again.ran)
        #expect(again.reason == nil)
        #expect(again.report == nil)
        #expect(fake.calls == calls, "a matching stamp runs nothing")

        try fake.writeManifest(version: "r2")
        let stale = try store.load("b")
        #expect(stale.engineStamp?.version == "r1")
        let third = try await store.ensureInitialized("b")
        guard case let .engineChanged(from, to)? = third.reason else {
            Issue.record("expected engineChanged, got \(String(describing: third.reason))")
            return
        }
        #expect(from.version == "r1")
        #expect(to.version == "r2")
        #expect(fake.calls.count == calls.count * 2, "the same idempotent steps ran again")
        #expect(fake.calls[calls.count] == "wine wineboot -u")
        #expect(try store.load("b").engineStamp?.version == "r2")

        try store.save(stale)
        #expect(try store.load("b").engineStamp?.version == "r2", "saving the stale copy keeps the newer stamp")

        let wrong = Fixtures.engine(id: "other", capabilities: Fixtures.crossOver)
        await #expect(throws: OssoverError.self) { try await store.ensureInitialized(stale, engine: wrong) }
        #expect(try store.load("b").engineStamp?.version == "r2")
    }

    @Test("a boot that dies after wineboot drops the stamp, so the next launch runs the steps again")
    func failedInitClearsTheStamp() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths)
        let store = BottleStore(paths: paths)
        let created = try store.create(name: "b", engineID: fake.id)
        #expect(created.engineStamp != nil, "stamped at creation, before any boot")

        try fake.failWinecfg(true)
        await #expect(throws: OssoverError.self) { try await store.ensureInitialized("b") }
        #expect(store.layout("b").prefixInitialised, "wineboot ran: system.reg exists")
        #expect(try store.load("b").engineStamp == nil, "the half-initialised prefix must not look complete")
        #expect(store.initializationReason(for: try store.load("b"), engine: try fake.engine()) == .engineStampMissing)

        try fake.failWinecfg(false)
        let recovered = try await store.ensureInitialized("b")
        #expect(recovered.reason == .engineStampMissing)
        #expect(try store.load("b").engineStamp?.version == "r1")
        #expect(fake.calls.filter { $0 == "wine winecfg -v win10" }.count == 2, "winecfg ran once per attempt")
    }
}

@Suite struct BottleStoreLiveProcessTests {
    static let notepad = ProcessEntry(pid: 42, command: #"/e/wine/bin/wine64-preloader C:\windows\system32\notepad.exe WINEPREFIX=/p HOME=/h"#)
    static let server = ProcessEntry(pid: 41, command: "/e/wine/bin/wineserver WINEPREFIX=/p HOME=/h")

    @Test("the decision: a live wineserver counts as initialised, and anything alive blocks the steps that would have to run")
    func decision() {
        let engine = Fixtures.engine(id: "e1", capabilities: Fixtures.crossOver)
        let stamp = EngineStamp(engine: engine)
        let stamped = Bottle(name: "b", engineID: "e1", engineStamp: stamp)
        let unstamped = Bottle(name: "b", engineID: "e1")
        func decide(_ bottle: Bottle, _ engine: Engine, initialised: Bool, live: [ProcessEntry]) -> BottleStore.InitializationDecision {
            BottleStore.initializationDecision(bottle: bottle, engine: engine, prefixInitialised: initialised, liveProcesses: live)
        }

        #expect(decide(stamped, engine, initialised: true, live: []) == .upToDate)
        #expect(decide(stamped, engine, initialised: true, live: [Self.notepad]) == .upToDate, "a matching stamp: the launch reuses what runs")
        #expect(decide(stamped, engine, initialised: true, live: [Self.server, Self.notepad]) == .upToDate)
        #expect(decide(stamped, engine, initialised: false, live: [Self.server]) == .upToDate,
                "a live wineserver holds the registry: initialised whether or not system.reg is flushed yet")
        #expect(decide(stamped, engine, initialised: false, live: []) == .initialize(.prefixNotInitialised))
        #expect(decide(stamped, engine, initialised: false, live: [Self.notepad]) == .blocked(.prefixNotInitialised, live: [Self.notepad]),
                "a client without a server is debris, not a boot: never wineboot under it")
        #expect(decide(unstamped, engine, initialised: true, live: []) == .initialize(.engineStampMissing))
        #expect(decide(unstamped, engine, initialised: true, live: [Self.server]) == .blocked(.engineStampMissing, live: [Self.server]))
        #expect(decide(unstamped, engine, initialised: false, live: [Self.server]) == .blocked(.engineStampMissing, live: [Self.server]),
                "the server makes the prefix initialised, but the missing stamp still asks for the steps")

        var upgraded = Fixtures.manifest(id: "e1", capabilities: Fixtures.crossOver)
        upgraded.version = "r2"
        let newEngine = Engine(root: Fixtures.paths.engine("e1"), manifest: upgraded)
        let changed = BottleStore.InitializationReason.engineChanged(from: stamp, to: EngineStamp(engine: newEngine))
        #expect(decide(stamped, newEngine, initialised: true, live: []) == .initialize(changed))
        let blocked = decide(stamped, newEngine, initialised: true, live: [Self.server, Self.notepad])
        #expect(blocked == .blocked(changed, live: [Self.server, Self.notepad]))
        #expect(blocked.description == "engine changed from e1 r1 to e1 r2, but 2 Wine process(es) still run in the prefix")
        #expect(decide(stamped, newEngine, initialised: false, live: [Self.server]) == .blocked(changed, live: [Self.server]))
        #expect(BottleStore.InitializationDecision.upToDate.description == "prefix up to date")
        #expect(BottleStore.InitializationDecision.initialize(.prefixNotInitialised).description == "prefix not initialised")

        let result = BottleStore.InitializationResult(bottle: stamped, liveProcesses: [Self.notepad, Self.server])
        #expect(!result.ran)
        #expect(result.runningWineserver == Self.server)
        #expect(BottleStore.InitializationResult(bottle: stamped, liveProcesses: [Self.notepad]).runningWineserver == nil)
    }

    @Test("membership: the WINEPREFIX exact match, or an exe inside the prefix by Unix path once Wine has wiped the environment")
    func members() async throws {
        let layout = BottleLayout(root: URL(fileURLWithPath: "/ossover-test/bottles/w", isDirectory: true))
        let env = " WINEPREFIX=/ossover-test/bottles/w/prefix HOME=/h"
        let server = ProcessEntry(pid: 10, command: "/ossover-test/engines/e/wine/bin/wineserver" + env)
        let loader = ProcessEntry(pid: 11, command: "/ossover-test/engines/e/wine/bin/wine C:\\\\x.exe" + env)
        let shell = ProcessEntry(pid: 12, command: "-zsh" + env)
        let rewritten = ProcessEntry(pid: 13, command: "/ossover-test/bottles/w/prefix/drive_c/windows/system32/notepad.exe ")
        let game = ProcessEntry(pid: 14, command: "/ossover-test/bottles/w/prefix/drive_c/Games/The Witcher 3/bin/x64/witcher3.exe --launcher-skip")
        let system = ProcessEntry(pid: 15, command: "C:\\\\windows\\\\system32\\\\services.exe ")
        let otherBottle = ProcessEntry(pid: 16, command: "/ossover-test/bottles/wb/prefix/drive_c/x.exe")
        let sibling = ProcessEntry(pid: 17, command: "/ossover-test/bottles/w/prefix2/drive_c/x.exe")
        let bare = ProcessEntry(pid: 18, command: "/ossover-test/bottles/w/prefix")
        let helper = ProcessEntry(pid: 19, command: "/ossover-test/engines/e/wine/bin/some-helper" + env)
        let entries = [server, loader, shell, rewritten, game, system, otherBottle, sibling, bare, helper]

        #expect(WineServer.members(of: entries, layout: layout).map(\.pid) == [10, 11, 13, 14])
        #expect(WineServer.members(of: entries, layout: layout, engineRoot: URL(fileURLWithPath: "/ossover-test/engines/e")).map(\.pid)
                == [10, 11, 13, 14, 19], "table order, no duplicates")
        #expect(WineServer.isRewrittenMember(rewritten, prefix: layout.prefix))
        #expect(WineServer.isRewrittenMember(game, prefix: layout.prefix), "spaces in the path, arguments after it")
        #expect(!WineServer.isRewrittenMember(system, prefix: layout.prefix), "a C:\\ argv[0] carries no prefix")
        #expect(!WineServer.isRewrittenMember(otherBottle, prefix: layout.prefix))
        #expect(!WineServer.isRewrittenMember(sibling, prefix: layout.prefix), "prefix2 is not under prefix")
        #expect(!WineServer.isRewrittenMember(bare, prefix: layout.prefix), "the directory itself is not an exe")
        #expect(!WineServer.isRewrittenMember(server, prefix: layout.prefix), "the server is a member by its environment, not by path")

        // Live: a sleeper started by Unix path inside drive_c with an empty environment, the way
        // a rewritten Wine program looks in the table (no WINEPREFIX word at all).
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = OssoverPaths(home: home).bottleLayout("b")
        let games = real.driveC.appending(path: "Games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let program = try FakePrefixProcess.start(named: "game.exe", in: games, prefix: real.prefix, environment: [:])
        defer { program.stop() }
        let live = try await WineServer.liveProcesses(layout: real)
        #expect(live.map(\.pid) == [program.pid])
        #expect(ProcessTable.filter(live, winePrefix: real.prefix).isEmpty, "invisible to the environment match alone")
        #expect(try await WineServer.processes(layout: real) == [program.pid])
        #expect(try await BottleStore(paths: OssoverPaths(home: home)).runningProcesses(of: "b") == [program.pid])
    }

    @Test("the busy clause names pid + command of what runs and the stop command")
    func busyClause() {
        #expect(WineServer.describe([Self.notepad, Self.server])
                == #"pid 41 /e/wine/bin/wineserver; pid 42 /e/wine/bin/wine64-preloader C:\windows\system32\notepad.exe"#,
                "by pid, environment words stripped")
        #expect(WineServer.describe([]).isEmpty)
        #expect(WineServer.stopCommand == "ossover bottle stop")
        #expect(WineServer.busyClause(bottle: "b", live: [Self.notepad])
                == #"1 Wine process(es) still run in its prefix: pid 42 /e/wine/bin/wine64-preloader C:\windows\system32\notepad.exe. "#
                    + "Stop them first: ossover bottle stop b")
        let none = WineServer.busyClause(bottle: "b", live: [])
        #expect(none.contains("no process of its prefix is visible now"))
        #expect(none.contains("`ossover bottle stop b`"))
        #expect(WineServer.bootWait == 120)
    }

    @Test("a prefix with live processes is never rebooted under: the re-init fails listing them, or stops them first on request")
    func liveProcessesBlockTheReinit() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths, version: "r1")
        let store = BottleStore(paths: paths)
        let created = try store.create(name: "b", engineID: fake.id)
        let layout = store.layout("b")
        let booted = try await store.ensureInitialized("b")
        #expect(booted.ran && booted.liveProcesses.isEmpty)
        let bootCalls = fake.calls

        let notepad = try FakePrefixProcess.start(named: "notepad.exe", in: home, prefix: layout.prefix)
        defer { notepad.stop() }
        let live = try await WineServer.liveProcesses(layout: layout, engineRoot: fake.root)
        #expect(live.map(\.pid) == [notepad.pid], "the fixture is a member of the prefix as ps shows it")
        #expect(live.first?.commandWithoutEnvironment == home.appending(path: "notepad.exe").path)

        // A matching stamp with the prefix booted: nothing to run, the live process is reported for the launch to reuse.
        let reused = try await store.ensureInitialized("b")
        #expect(!reused.ran)
        #expect(reused.liveProcesses.map(\.pid) == [notepad.pid])
        #expect(reused.runningWineserver == nil)
        #expect(fake.calls == bootCalls)

        // An engine change with that process alive: refused, with pid + command and the stop hint; no wineboot.
        try fake.writeManifest(version: "r2")
        let engine = try fake.engine()
        let error = await #expect(throws: OssoverError.self) { try await store.ensureInitialized("b") }
        guard case let .invalid(message)? = error else {
            Issue.record("expected .invalid, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("bottle b: the prefix must be (re)initialised (engine changed from fake-engine r1 to fake-engine r2), but wineboot must not run while 1 Wine process(es) still run in its prefix: pid \(notepad.pid) "))
        #expect(message.contains("/notepad.exe. Stop them first: ossover bottle stop b"))
        #expect(fake.calls == bootCalls, "nothing ran")
        #expect(try store.load("b").engineStamp?.version == "r1", "not a failed init: the stamp stays")
        #expect(notepad.isRunning)
        await #expect(throws: OssoverError.self, "Prefix.initialize guards itself too") {
            try await Prefix.initialize(bottle: created, engine: engine, layout: layout)
        }
        #expect(fake.calls == bootCalls)

        // With stopLiveProcesses (ossover run --restart-server): the plan's shutdown first, then the steps.
        let lines = LineCollector()
        let restarted = try await store.ensureInitialized("b", stopLiveProcesses: true) { lines.append($0) }
        guard case .engineChanged? = restarted.reason else {
            Issue.record("expected engineChanged, got \(String(describing: restarted.reason))")
            return
        }
        let calls = fake.calls
        #expect(Array(calls[bootCalls.count..<(bootCalls.count + 3)]) == ["wineserver -k", "wineserver -w", "wine wineboot -u"],
                "shutdown, then the boot")
        #expect(calls.count == bootCalls.count * 2 + 2)
        notepad.stop()
        #expect(!notepad.isRunning, "the leftover got SIGTERM from the shutdown")
        #expect(try store.load("b").engineStamp?.version == "r2")
        #expect(lines.lines.contains { $0.hasPrefix("engine changed from fake-engine r1 to fake-engine r2, but 1 Wine process(es) still run in the prefix (pid \(notepad.pid) ") && $0.hasSuffix("; stopping them first") })
        #expect(lines.lines.contains { $0.hasPrefix("wineserver stopped, ended 1 leftover process(es)") })
    }

    @Test("a running wineserver with a matching stamp is reused even before system.reg is flushed; without the stamp it blocks")
    func liveServerCountsAsInitialised() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths)
        let store = BottleStore(paths: paths)
        _ = try store.create(name: "b", engineID: fake.id)
        let layout = store.layout("b")
        #expect(!layout.prefixInitialised)

        let server = try FakePrefixProcess.start(named: "wineserver", in: home, prefix: layout.prefix)
        defer { server.stop() }
        let result = try await store.ensureInitialized("b")
        #expect(!result.ran, "the server is the boot's product; no second wineboot under it")
        #expect(result.runningWineserver?.pid == server.pid)
        #expect(fake.calls.isEmpty)

        var unstamped = try store.load("b")
        unstamped.engineStamp = nil
        try unstamped.save(to: layout.bottleJSON, preservingStamp: false)
        let error = await #expect(throws: OssoverError.self) { try await store.ensureInitialized("b") }
        guard case let .invalid(message)? = error else {
            Issue.record("expected .invalid, got \(String(describing: error))")
            return
        }
        #expect(message.contains("(prefix carries no engine stamp), but wineboot must not run while 1 Wine process(es) still run in its prefix: pid \(server.pid) "))
        #expect(fake.calls.isEmpty)
    }

    @Test("the boot's wineserver -w is capped; on expiry the error lists what keeps the server alive")
    func bootWaitIsCapped() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let fake = try FakeEngine.install(in: paths)
        let engine = try fake.engine()
        let store = BottleStore(paths: paths)
        let bottle = try store.create(name: "b", engineID: fake.id)
        let layout = store.layout("b")
        try fake.hangWait(true)

        // The wait itself, with a client alive: .timeout naming the bottle, the pid + command, the hint.
        let notepad = try FakePrefixProcess.start(named: "notepad.exe", in: home, prefix: layout.prefix)
        defer { notepad.stop() }
        let started = Date()
        let waitError = await #expect(throws: OssoverError.self) {
            try await WineServer.waitForExit(engine: engine, bottle: bottle, layout: layout, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 4, "the cap, not the sleeper's five seconds")
        guard case let .timeout(command, seconds)? = waitError else {
            Issue.record("expected .timeout, got \(String(describing: waitError))")
            return
        }
        #expect(seconds == 0.3)
        #expect(command.hasPrefix("wineserver -w (bottle b): 1 Wine process(es) still run in its prefix: pid \(notepad.pid) "))
        #expect(command.hasSuffix("/notepad.exe. Stop them first: ossover bottle stop b"))
        #expect(waitError?.errorDescription?.hasPrefix("Command timed out after 0.3 s: wineserver -w (bottle b): ") == true)
        notepad.stop()

        // Through ensureInitialized: the pre-check passes (nothing alive), wineboot runs, the wait
        // expires, and the failed boot drops the stamp like any other.
        let error = await #expect(throws: OssoverError.self) { try await store.ensureInitialized("b", bootWait: 0.3) }
        guard case let .timeout(text, _)? = error else {
            Issue.record("expected .timeout, got \(String(describing: error))")
            return
        }
        #expect(text.hasPrefix("wineserver -w (bottle b): no process of its prefix is visible now"))
        #expect(text.contains("`ossover bottle stop b` resets it"))
        #expect(Array(fake.calls.suffix(2)) == ["wine wineboot -u", "wineserver -w"], "nothing after the wait")
        #expect(!fake.calls.contains("wine winecfg -v win10"))
        #expect(layout.prefixInitialised)
        #expect(try store.load("b").engineStamp == nil, "a boot that did not settle must not look complete")

        try fake.hangWait(false)
        let recovered = try await store.ensureInitialized("b", bootWait: 0.3)
        #expect(recovered.reason == .engineStampMissing)
        #expect(try store.load("b").engineStamp?.version == "r1")
    }
}
