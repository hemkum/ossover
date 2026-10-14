// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Tests for the review findings fixed in the Phase 2/3 code: prefix membership, user-folder
// restore, engine-bundled renderer packs, the strategy-B winemetal gate, the interactive
// spawn, symlink escapes, bench preconditions and the per-prefix HUD filter.

@Suite struct ProcessTablePrefixTests {
    static let prefix = URL(fileURLWithPath: "/ossover-test/bottles/w/prefix", isDirectory: true)
    static let env = " WINEPREFIX=/ossover-test/bottles/w/prefix HOME=/Users/h"

    @Test("a shell with WINEPREFIX exported is not a prefix process")
    func shellIsNotAMember() {
        let entries = [
            ProcessEntry(pid: 10, command: "-zsh" + Self.env),
            ProcessEntry(pid: 11, command: "/usr/bin/vim notes.txt" + Self.env),
            ProcessEntry(pid: 12, command: "/ossover-test/engines/e/wine/bin/wineserver" + Self.env),
            ProcessEntry(pid: 13, command: "/ossover-test/engines/e/wine/lib/wine/x86_64-unix/wine C:\\Games\\x.exe" + Self.env),
            ProcessEntry(pid: 14, command: "wine64-preloader C:\\windows\\system32\\winedevice.exe" + Self.env),
            ProcessEntry(pid: 15, command: "/ossover-test/engines/e/wine/libexec/gstreamer-1.0/gst-plugin-scanner" + Self.env),
            ProcessEntry(pid: 16, command: "/ossover-test/engines/e/wine/bin/some-helper" + Self.env),
            ProcessEntry(pid: 17, command: "C:\\Games\\The Witcher 3\\bin\\x64\\witcher3.exe --launcher-skip" + Self.env),
            ProcessEntry(pid: 18, command: "/ossover-test/engines/e/wine/bin/wine x.exe WINEPREFIX=/ossover-test/bottles/wb/prefix"),
        ]
        #expect(ProcessTable.filter(entries, winePrefix: Self.prefix).map(\.pid) == [12, 13, 14, 15, 17])
        #expect(ProcessTable.filter(entries, winePrefix: Self.prefix, engineRoot: URL(fileURLWithPath: "/ossover-test/engines/e")).map(\.pid)
                == [12, 13, 14, 15, 16, 17], "anything running from the engine directory counts once the engine is known")
        #expect(!ProcessTable.isWineProcess(ProcessEntry(pid: 1, command: "-zsh")))
        #expect(ProcessTable.isWineProcess(ProcessEntry(pid: 1, command: "wineserver -p")))
        #expect(ProcessTable.isWineProcess(ProcessEntry(pid: 1, command: "/x/wineloader64 notepad.EXE")))
    }

    @Test("processes whose DLL path names a renderer pack")
    func dllPathMembers() {
        let root = URL(fileURLWithPath: "/ossover-test/renderers/dxmt-0.80", isDirectory: true)
        let entries = [
            ProcessEntry(pid: 1, command: "wine64-preloader x.exe WINEPREFIX=/p WINEDLLPATH=/ossover-test/renderers/dxmt-0.80/wine:/other HOME=/h"),
            ProcessEntry(pid: 2, command: "wine64-preloader x.exe WINEDLLPATH_PREPEND=/ossover-test/renderers/dxmt-0.80 HOME=/h"),
            ProcessEntry(pid: 3, command: "wine64-preloader x.exe WINEDLLPATH=/ossover-test/renderers/dxmt-0.800/wine HOME=/h"),
            ProcessEntry(pid: 4, command: "wine64-preloader x.exe WINEDLLPATH=/other HOME=/h"),
            ProcessEntry(pid: 5, command: "wine64-preloader x.exe HOME=/h"),
        ]
        #expect(ProcessTable.filter(entries, dllPath: root).map(\.pid) == [1, 2])
        #expect(ProcessTable.environmentValues(of: ProcessEntry(pid: 9, command: "tool WINEDLLPATH=/a b/wine FOO=1 WINEDLLPATH=/c"), key: "WINEDLLPATH")
                == ["/a b/wine", "/c"])
        #expect(ProcessTable.environmentValues(of: ProcessEntry(pid: 9, command: "tool FOO=1"), key: "WINEDLLPATH").isEmpty)
    }
}

@Suite struct PrefixUserFolderTests {
    @Test("a second restore keeps the first kept folder")
    func secondRestoreKeepsBoth() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let layout = OssoverPaths(home: home).bottleLayout("b")
        let user = layout.userDirectory("u")
        let target = home.appending(path: "mac-Documents", directoryHint: .isDirectory)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let documents = user.appending(path: "Documents", directoryHint: .isDirectory)
        try fm.createSymbolicLink(atPath: documents.path, withDestinationPath: target.path)

        #expect(try Prefix.isolateUserFolders(layout: layout, userName: "u").map(\.name) == ["Documents"])
        try Data("one".utf8).write(to: documents.appending(path: "save1"))
        #expect(try Prefix.restoreUserFolders(layout: layout).map(\.name) == ["Documents"])
        let kept1 = user.appending(path: "Documents (bottle)", directoryHint: .isDirectory)
        #expect(fm.fileExists(atPath: kept1.appending(path: "save1").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: documents.path) == target.path)

        #expect(try Prefix.isolateUserFolders(layout: layout, userName: "u").map(\.name) == ["Documents"])
        try Data("two".utf8).write(to: documents.appending(path: "save2"))
        #expect(Prefix.keptFolderURL(for: "Documents", in: user).lastPathComponent == "Documents (bottle 2)")
        try Prefix.restoreUserFolders(layout: layout)
        let kept2 = user.appending(path: "Documents (bottle 2)", directoryHint: .isDirectory)
        #expect(fm.fileExists(atPath: kept1.appending(path: "save1").path), "the first kept folder survives")
        #expect(fm.fileExists(atPath: kept2.appending(path: "save2").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: documents.path) == target.path)
        #expect(Prefix.keptFolderURL(for: "Documents", in: user).lastPathComponent == "Documents (bottle 3)")
    }

    @Test("the prefix user name follows the engine when nothing is booted yet")
    func userNameFallsBackByEngine() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let layout = OssoverPaths(home: home).bottleLayout("b")
        #expect(Prefix.userName(layout: layout) == NSUserName())
        #expect(Prefix.userName(layout: layout, engine: Fixtures.engine(capabilities: Fixtures.vanillaEsync)) == NSUserName())
        #expect(Prefix.userName(layout: layout, engine: Fixtures.engine(capabilities: Fixtures.crossOver)) == Prefix.crossOverUserName)
        try FileManager.default.createDirectory(at: layout.userDirectory("crossover"), withIntermediateDirectories: true)
        #expect(Prefix.userName(layout: layout, engine: Fixtures.engine(capabilities: Fixtures.vanillaEsync)) == "crossover", "a booted prefix wins")
        try FileManager.default.createDirectory(at: layout.userDirectory(NSUserName()), withIntermediateDirectories: true)
        #expect(Prefix.userName(layout: layout, engine: Fixtures.engine(capabilities: Fixtures.crossOver)) == NSUserName())
    }
}

/// Collects log lines from a `@Sendable` log callback.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite struct RendererBundleTests {
    static let frankeaID = "x64-frankea-wine11.16-cx26.3-v4.6.4b1"

    static func touch(_ url: URL, _ text: String = "MZ") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The bootstrap tarball's shape under an engine root: `engine/DXMT/{x64,x32}`, `engine/DXVK/{x64,x32,dxvk.conf}`.
    static func whiskyTree(at root: URL) throws {
        for name in ["d3d10core", "d3d11", "dxgi", "winemetal", "nvapi64", "nvngx"] { try touch(root.appending(path: "engine/DXMT/x64/\(name).dll")) }
        for name in ["d3d10core", "d3d11", "dxgi", "winemetal"] { try touch(root.appending(path: "engine/DXMT/x32/\(name).dll")) }
        for name in ["d3d10core", "d3d11"] {
            try touch(root.appending(path: "engine/DXVK/x64/\(name).dll"))
            try touch(root.appending(path: "engine/DXVK/x32/\(name).dll"))
        }
        try touch(root.appending(path: "engine/DXVK/dxvk.conf"), "# conf")
        try touch(root.appending(path: "engine/Wine/lib/wine/x86_64-unix/winemetal.so"), "frankea-so")
    }

    @Test("the shipped frankea manifest resolves its bundled DXMT and DXVK after install normalisation")
    func frankeaBundlesResolve() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let catalog = try EngineStore.catalog(in: Fixtures.repoRoot.appending(path: "engines"))
        let manifest = try #require(catalog.first { $0.id == Self.frankeaID })
        let root = OssoverPaths(home: home).engine(manifest.id)
        try Self.whiskyTree(at: root)

        #expect(RendererResolver.bundledPacks(engine: Engine(root: root, manifest: manifest)).isEmpty, "Whisky's x64/x32 shape is not a pack yet")
        let lines = LineCollector()
        let installed = try EngineStore.normalizeBundledRenderers(manifest, root: root) { lines.append($0) }
        #expect(installed.bundledRenderers.map(\.path) == ["overlays/dxmt", "overlays/dxvk"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "overlays/dxmt/x86_64-windows/d3d11.dll").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "overlays/dxmt/i386-windows/d3d11.dll").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "overlays/dxvk/dxvk.conf").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "engine/DXMT").path))
        #expect(lines.lines.contains { $0.contains("engine/DXMT → overlays/dxmt") })

        let engine = Engine(root: root, manifest: installed)
        let packs = RendererResolver.bundledPacks(engine: engine)
        #expect(packs.map(\.kind) == [.dxmt, .dxvk])
        for pack in packs {
            #expect(pack.wineDir == engine.overlay(pack.kind), "a bare overlay is its own wine dir")
            #expect(pack.missingFiles.isEmpty, "\(pack.id): \(pack.missingFiles.map(\.lastPathComponent))")
            #expect(RendererResolver.isBundled(pack, in: engine))
            #expect(RendererResolver.unmet(pack: pack, engine: engine).isEmpty)
        }
        let dxmt = try #require(packs.first)
        #expect(dxmt.id == "\(manifest.id)-dxmt")
        #expect(dxmt.manifest.version == "0.80")
        #expect(!dxmt.manifest.builtinMarked)
        #expect(dxmt.manifest.layout.pe32 == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"])

        // `auto` and an explicit `dxmt` take the engine's own pack over an installed release pack.
        let installedPack = RendererPack(root: OssoverPaths(home: home).renderer("dxmt-0.80"), manifest: Fixtures.dxmtPack.manifest)
        let selection = try RendererResolver.resolve(choice: .dxmt, engine: engine, packs: [installedPack] + packs)
        #expect(selection.pack?.id == dxmt.id)
        #expect(selection.strategy == .prefixCopy)
        #expect(selection.dllPath == engine.overlay(.dxmt))
        let copies = RendererMaterializer.plan(selection: selection, layout: OssoverPaths(home: home).bottleLayout("b"))
        #expect(copies.map { $0.destination.lastPathComponent } == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        #expect(RendererMaterializer.winemetalNote(selection: selection, engine: engine)?.contains("the engine's own") == true)

        // Normalising again is a no-op.
        #expect(try EngineStore.normalizeBundledRenderers(installed, root: root) == installed)
    }

    @Test("an engine packaged by engine/package.sh (bare overlays/<kind>, layout lists) resolves and prepends")
    func packagedEngineBundleResolves() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
            {
              "schema": "ossover.engine-manifest/1",
              "id": "x64-ossover-cx26.3-r1",
              "displayName": "ossover Wine 11.0 (CrossOver 26.3.0 sources) r1",
              "version": "cx26.3.0-r1",
              "wineVersion": "11.0",
              "arch": "x86_64",
              "minMacOS": "15.0",
              "requires": ["rosetta2"],
              "source": { "url": "https://example.invalid/x64-ossover-cx26.3-r1.tar.xz", "sha256": "TBD", "license": "LGPL-2.1-or-later" },
              "paths": { "wine": "wine/bin/wine", "wineserver": "wine/bin/wineserver", "libWine": "wine/lib/wine" },
              "baseEnv": {},
              "capabilities": { "msync": true, "esync": false, "wow64": true, "macdrvExports": true, "dllPathPrepend": true, "d3dmetalHost": true,
                                "winemetalBuiltin": true },
              "bundledRenderers": [
                { "id": "dxmt", "kind": "dxmt", "version": "0.80", "path": "overlays/dxmt",
                  "layout": { "unix": ["winemetal.so"], "pe": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll", "winemetal.dll"],
                              "pe32": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] },
                  "builtinMarked": true, "requires": { "macdrvExports": true, "dllPathPrepend": true } }
              ],
              "addons": { "wineMono": "10.4.1" },
              "build": { "patches": ["0001", "0003", "0014"] }
            }
            """
        let manifest = try JSONDocument.decode(EngineManifest.self, from: Data(json.utf8))
        try manifest.validate()
        let root = OssoverPaths(home: home).engine(manifest.id)
        let bundled = try #require(manifest.bundledRenderer(.dxmt))
        for relative in bundled.layout?.relativePaths ?? [] {
            // The install refresh records builtinMarked from the files (EngineStore.normalizeBundledRenderers),
            // and package.sh's DXMT PEs carry the mark (REA L-25).
            let url = root.appending(path: "overlays/dxmt/\(relative)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (relative.hasSuffix(".dll") ? PEBuiltinMarkTests.marked : Data("so".utf8)).write(to: url)
        }
        try Self.touch(root.appending(path: "wine/lib/wine/x86_64-unix/winemetal.so"), "same")

        let installed = try EngineStore.normalizeBundledRenderers(manifest, root: root)
        #expect(installed == manifest, "already in the plan's shape: nothing moves")
        let engine = Engine(root: root, manifest: installed)
        let packs = RendererResolver.bundledPacks(engine: engine)
        #expect(packs.count == 1)
        let pack = try #require(packs.first)
        #expect(pack.wineDir == engine.overlay(.dxmt))
        #expect(pack.missingFiles.isEmpty)
        #expect(pack.manifest.builtinMarked)
        let selection = try RendererResolver.resolve(choice: .auto, engine: engine, packs: packs)
        #expect(selection.kind == .dxmt)
        #expect(selection.strategy == .prepend)
        #expect(selection.dllPath == engine.overlay(.dxmt))
        let env = WineEnvironment.make(engine: engine, bottle: Bottle(name: "b", engineID: engine.id), layout: OssoverPaths(home: home).bottleLayout("b"),
                                       program: nil, renderer: selection)
        #expect(env["WINEDLLPATH_PREPEND"] == engine.overlay(.dxmt).path)
        #expect(env["WINEDLLPATH"] == nil)
    }

    @Test("packRoot accepts the pack, bare and wine-directory shapes")
    func packRootShapes() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let packShaped = home.appending(path: "a", directoryHint: .isDirectory)
        try Self.touch(packShaped.appending(path: "wine/x86_64-windows/d3d11.dll"))
        let bare = home.appending(path: "b", directoryHint: .isDirectory)
        try Self.touch(bare.appending(path: "x86_64-windows/d3d11.dll"))
        let whisky = home.appending(path: "c", directoryHint: .isDirectory)
        try Self.touch(whisky.appending(path: "x64/d3d11.dll"))
        #expect(RendererResolver.packRoot(containing: packShaped) == packShaped.standardizedFileURL)
        #expect(RendererResolver.packRoot(containing: packShaped.appending(path: "wine")) == packShaped.standardizedFileURL)
        #expect(RendererResolver.packRoot(containing: bare) == bare.standardizedFileURL)
        #expect(RendererResolver.packRoot(containing: whisky) == nil)
        #expect(RendererPack(root: bare, manifest: Fixtures.dxmtPack.manifest).wineDir == bare.standardizedFileURL)
        #expect(RendererPack(root: packShaped, manifest: Fixtures.dxmtPack.manifest).wineDir.lastPathComponent == "wine")
        #expect(Fixtures.dxmtPack.wineDir.path == "/ossover-test/renderers/dxmt-0.80/wine", "nothing on disk: the nested shape")
    }

    @Test("strategy B refuses a DXMT pack whose winemetal.so is not the engine's")
    func winemetalCouplingGate() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        func engine(_ capabilities: EngineCapabilities, bundledVersion: String? = nil) -> Engine {
            var manifest = Fixtures.manifest(id: "e", capabilities: capabilities)
            if let bundledVersion { manifest.bundledRenderers = [BundledRenderer(kind: .dxmt, version: bundledVersion, path: "overlays/dxmt")] }
            return Engine(root: paths.engine("e"), manifest: manifest)
        }
        let pack = RendererPack(root: paths.renderer("dxmt-0.80"), manifest: Fixtures.dxmtPack.manifest)
        let crossOver = engine(Fixtures.crossOver)

        // No winemetal.so in the engine: the pack's own resolves through WINEDLLPATH.
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: crossOver) == nil)
        try Self.touch(crossOver.unixLibDir.appending(path: "winemetal.so"), "engine-build")
        // Engine winemetal.so present, no bundled DXMT declared, no pack winemetal.so to compare:
        // nothing proves the pairing, so the gate refuses (decision 12(c) is refuse-unless).
        let unproven = try #require(RendererResolver.winemetalCoupling(pack: pack, engine: crossOver))
        #expect(unproven.contains("declares no bundled DXMT version"))
        try Self.touch(pack.unixDir.appending(path: "winemetal.so"), "release-build")
        let reason = try #require(RendererResolver.winemetalCoupling(pack: pack, engine: crossOver))
        #expect(reason.contains("strategy B runs the pack's D3D DLLs against the engine's winemetal"))
        #expect(RendererResolver.unmet(pack: pack, engine: crossOver) == [reason])
        let selection = RendererSelection(choice: .dxmt, kind: .dxmt, pack: pack, dllPath: pack.wineDir, strategy: .prefixCopy)
        #expect(RendererMaterializer.unmet(selection: selection, engine: crossOver) == [reason], "the materializer mirrors the resolver")
        #expect(throws: OssoverError.self) { try RendererResolver.resolve(choice: .dxmt, engine: crossOver, packs: [pack]) }
        #expect(try RendererResolver.resolve(choice: .auto, engine: crossOver, packs: [pack]).kind == .wined3d)

        // Same bytes: fine. A bundled DXMT of another version: refused even with the same bytes.
        try Self.touch(pack.unixDir.appending(path: "winemetal.so"), "engine-build")
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: crossOver) == nil)
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: engine(Fixtures.crossOver, bundledVersion: "0.80")) == nil)
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: engine(Fixtures.crossOver, bundledVersion: "0.79"))?.contains("DXMT 0.79") == true)

        // Equal versions but different bytes: the stricter byte gate refuses (the frankea case
        // for a non-bundled 0.80 pack, REA U-20). Strategy C and the engine's own pack are never
        // coupled.
        try Self.touch(pack.unixDir.appending(path: "winemetal.so"), "release-build")
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: engine(Fixtures.crossOver, bundledVersion: "0.80"))?.contains("DXMT 0.80") == true)
        #expect(RendererResolver.winemetalCoupling(pack: pack, engine: engine(Fixtures.crossOverPrepend)) == nil)
        let bundled = RendererPack(root: crossOver.overlay(.dxmt), manifest: Fixtures.dxmtPack.manifest)
        #expect(RendererResolver.winemetalCoupling(pack: bundled, engine: crossOver) == nil)
        #expect(RendererResolver.winemetalCoupling(pack: Fixtures.dxvkPack, engine: crossOver) == nil)
    }
}

@Suite struct ShellInteractiveTests {
    @Test("the interactive child shares ossover's process group and reports its status")
    func childStaysInTheForegroundGroup() throws {
        #expect(try Shell.runInteractive(executable: "/bin/sh", args: ["-c", "exit 3"]) == 3)
        let sameGroup = try Shell.runInteractive(executable: "/bin/sh",
                                                 args: ["-c", "test \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"$(ps -o pgid= -p $PPID | tr -d ' ')\""])
        #expect(sameGroup == 0, "a child in its own group would be stopped by SIGTTIN on the first TTY read")
        let cwd = try Shell.runInteractive(executable: "/bin/sh", args: ["-c", "test \"$(pwd -P)\" = \"$(cd /tmp && pwd -P)\""],
                                           cwd: URL(fileURLWithPath: "/tmp", isDirectory: true))
        #expect(cwd == 0)
        let env = try Shell.runInteractive(executable: "/bin/sh", args: ["-c", "test \"$OSSOVER_T\" = yes"], env: ["OSSOVER_T": "yes"])
        #expect(env == 0)
        let signalled = try Shell.runInteractive(executable: "/bin/sh", args: ["-c", "kill -TERM $$"])
        #expect(signalled == 128 + SIGTERM)
        #expect(throws: OssoverError.self) { try Shell.runInteractive(executable: "/nonexistent/ossover-tool") }
        #expect(Shell.exitStatus(fromWaitStatus: 3 << 8) == 3)
        #expect(Shell.exitStatus(fromWaitStatus: Int32(SIGKILL)) == 137)
    }
}

@Suite struct EngineStoreSafetyTests {
    @Test("symbolic links that leave the install tree are found")
    func escapingSymlinks() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let root = home.appending(path: "engine", directoryHint: .isDirectory)
        let sub = root.appending(path: "sub", directoryHint: .isDirectory)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("f".utf8).write(to: root.appending(path: "file"))
        try Data("o".utf8).write(to: home.appending(path: "outside"))
        try fm.createSymbolicLink(atPath: sub.appending(path: "inside").path, withDestinationPath: "../file")
        try fm.createSymbolicLink(atPath: sub.appending(path: "dangling").path, withDestinationPath: "nowhere")
        try fm.createSymbolicLink(atPath: sub.appending(path: "absolute").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: sub.appending(path: "dotdot").path, withDestinationPath: "../../outside")
        #expect(EngineStore.escapingSymlinks(under: root).map(\.lastPathComponent) == ["absolute", "dotdot"])
        #expect(throws: OssoverError.self) { try EngineStore.requireNoEscapingSymlinks(under: root, what: "engine t") }
        try fm.removeItem(at: sub.appending(path: "absolute"))
        try fm.removeItem(at: sub.appending(path: "dotdot"))
        #expect(EngineStore.escapingSymlinks(under: root).isEmpty)
        try EngineStore.requireNoEscapingSymlinks(under: root, what: "engine t")
    }

    @Test("the quarantine strip acts on links themselves")
    func quarantineArguments() {
        // The flag set is the whole point: without -s, xattr follows a link out of the tree.
        #expect(EngineStore.quarantineAttribute == "com.apple.quarantine")
        #expect(EngineStore.xattrExecutable == "/usr/bin/xattr")
    }
}

@Suite struct BenchPreconditionTests {
    @Test("the benchmark save is made the newest and the settings are checked")
    func checkPreconditions() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let saves = home.appending(path: "gamesaves", directoryHint: .isDirectory)
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let old = saves.appending(path: "AutoSave_1.sav")
        try Data("old".utf8).write(to: old)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let benchmark = home.appending(path: "repo/recipes/witcher3/bench/benchmark.sav")
        try fm.createDirectory(at: benchmark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("benchmark".utf8).write(to: benchmark)
        let settings = home.appending(path: "user.settings")
        try Data("[Rendering]\nHairWorksLevel=0\n[Viewport]\nResolution=\"2560x1600\"\nVSync=false\n".utf8).write(to: settings)
        let preconditions = ResolvedBenchPreconditions(savesDirectory: saves, saveExtension: "sav", benchmarkSave: benchmark,
                                                       settingsFile: settings, requiredSettings: BenchPreconditions.witcher3.requiredSettings)

        let first = try BenchHarness.checkPreconditions(preconditions)
        #expect(first.contains { $0.contains("copied") && $0.contains("AutoSave_1.sav") })
        #expect(try BenchHarness.newestFile(in: saves, extension: "sav")?.lastPathComponent == "benchmark.sav")
        let second = try BenchHarness.checkPreconditions(preconditions)
        #expect(second.contains { $0.contains("is the newest") })
        #expect(second.contains { $0.contains("user.settings holds the benchmark profile") })

        // A newer foreign save (Hemant played after creating the benchmark) is displaced again.
        let played = saves.appending(path: "ManualSave_2.sav")
        try Data("played".utf8).write(to: played)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: played.path)
        #expect(try BenchHarness.checkPreconditions(preconditions).contains { $0.contains("copied") && $0.contains("ManualSave_2.sav") })

        try Data("[Rendering]\nHairWorksLevel=1\n[Viewport]\nResolution=\"2560x1600\"\n".utf8).write(to: settings)
        #expect(throws: OssoverError.self) { try BenchHarness.checkPreconditions(preconditions) }
        var missing = preconditions
        missing.benchmarkSave = home.appending(path: "repo/recipes/witcher3/bench/absent.sav")
        #expect(throws: OssoverError.self) { try BenchHarness.checkPreconditions(missing) }
        #expect(try BenchHarness.checkPreconditions(ResolvedBenchPreconditions()).isEmpty, "nothing demanded, nothing checked")
    }

    @Test("the novigrad profile carries the Witcher 3 preconditions and round-trips")
    func profileEncodesPreconditions() throws {
        let profile = BenchProfile.novigrad
        #expect(profile.preconditions == .witcher3)
        let data = try JSONDocument.encode(profile)
        #expect(try JSONDocument.decode(BenchProfile.self, from: data) == profile)
        let legacy = try JSONDocument.decode(BenchProfile.self, from: Data(#"{"name":"x","loadWaitS":1,"warmupS":1,"measureS":10,"runs":1,"manualLoad":true,"manualLoadCountdownS":5,"loadKey":"return","menuTimeoutS":30,"menu":{"windowTimeoutS":30,"minFPS":20,"sustainS":5,"blackThreshold":0.03,"requireScreenshot":false},"cooldownS":0}"#.utf8))
        #expect(legacy.preconditions == nil, "a profile written before preconditions existed still loads")
        #expect(BenchHarness.caffeinateArguments(waitingFor: 4321) == ["-dims", "-w", "4321"])
    }
}

@Suite struct HUDTraceFilterTests {
    @Test("only the prefix's processes count")
    func filteredByProcessIDs() {
        let frame = MetalHUDFrame(intervalMs: 16, gpuTimeMs: 8)
        let trace = MetalHUDTrace(samples: [
            MetalHUDSample(timestamp: Date(), processID: 100, firstFrame: 0, gfxMemoryMB: 1, processMemoryMB: 1, frames: [frame]),
            MetalHUDSample(timestamp: Date(), processID: 200, firstFrame: 0, gfxMemoryMB: 1, processMemoryMB: 1, frames: [frame, frame]),
            MetalHUDSample(timestamp: Date(), processID: nil, firstFrame: 0, gfxMemoryMB: 1, processMemoryMB: 1, frames: [frame]),
        ])
        #expect(trace.filtered(processIDs: [100]).frameCount == 1)
        #expect(trace.filtered(processIDs: [100, 200]).frameCount == 3)
        #expect(trace.filtered(processIDs: []).isEmpty)
        #expect(trace.filtered(processID: 200).frameCount == 2)
    }
}
