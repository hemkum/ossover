// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/highball/main.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (engine list/install shape, download progress line)

import ArgumentParser
import Foundation
import OssoverKit

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Install, list, verify and remove engines (Wine builds).",
        subcommands: [List.self, Install.self, Verify.self, Remove.self, ValidateManifest.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Installed engines, or the repository's catalog with --catalog.")

        @OptionGroup var global: GlobalOptions
        @Flag(help: "Print JSON.") var json = false
        @Flag(help: "List the repository's engines/*.json instead of what is installed.") var catalog = false

        func run() async throws {
            if catalog { return try listCatalog() }
            let rows = EngineStore(paths: global.paths).list(log: Console.logger).map(EngineRow.init)
            if json { return try Console.json(rows) }
            guard !rows.isEmpty else {
                print("no engines installed (ossover engine install <id or manifest.json>; ossover engine list --catalog)")
                return
            }
            Console.table(["ID", "Wine", "Arch", "Capabilities", "Bundled", "Status"], rows.map {
                [$0.id, $0.wineVersion, $0.arch, Format.list($0.capabilities), Format.list($0.bundledRenderers), $0.installed ? "ok" : "incomplete"]
            })
        }

        func listCatalog() throws {
            let manifests = try EngineStore.catalog(in: RepoRoot.engines(in: try RepoRoot.require()))
            if json { return try Console.json(manifests) }
            let store = EngineStore(paths: global.paths)
            Console.table(["ID", "Wine", "Min macOS", "Pinned", "Installed", "Source"], manifests.map {
                [$0.id, $0.wineVersion, $0.minMacOS, Table.yesNo($0.source.isPinned), Table.yesNo(store.isInstalled($0.id)), $0.source.url.absoluteString]
            })
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download, verify and unpack an engine from a manifest.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "A manifest file, or an id from the repository's engines/ directory.") var manifest: String
        @Flag(help: "Reinstall over an existing engine directory (refused while processes run from it).") var replace = false
        @Flag(help: "With --replace: reinstall even while processes run from the engine directory.") var force = false

        func run() async throws {
            let manifest = try Catalog.engineManifest(self.manifest)
            Console.note("installing \(manifest.id): \(manifest.displayName)")
            let progress = ProgressPrinter(label: "download")
            let engine: Engine
            do {
                engine = try await EngineStore(paths: global.paths).install(manifest, replace: replace, force: force,
                                                                            progress: progress.handler, log: Console.logger)
            } catch {
                progress.finish()
                throw error
            }
            progress.finish()
            print("installed \(engine.id) at \(engine.root.path)")
            print("capabilities: " + Format.list(engine.capabilities.enabled))
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-hash an engine's Mach-O files against its SHA256SUMS.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Engine id.") var id: String
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let store = EngineStore(paths: global.paths)
            let engine = try store.engine(id)
            let report = try store.verify(engine)
            if json {
                try Console.json(VerifyRow(id: engine.id, ok: report.ok, checked: report.checked, changed: report.changed,
                                           missing: report.missing, unlisted: report.unlisted))
            } else {
                print("\(engine.id): \(report.summary)")
                for file in report.changed { print("changed: \(file)") }
                for file in report.missing { print("missing: \(file)") }
            }
            guard report.ok else { throw failure() }
        }
    }

    /// Hidden packaging check: decodes a `manifest.json` with the model `engine install` uses
    /// (`EngineManifest.load` validates), so `engine/gates.sh manifest` can prove the file
    /// `engine/package.sh` wrote is one ossover will accept. `--layout` also checks the tree next
    /// to the manifest (loader, wineserver, lib/wine, every bundled renderer's layout files).
    struct ValidateManifest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate-manifest",
            abstract: "Decode and validate an engine manifest.json (packaging check).",
            shouldDisplay: false)

        @Argument(help: "Path to a manifest.json.") var file: String
        @Flag(help: "Also check the engine tree next to the manifest (paths, bundled renderer layouts).") var layout = false
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let url = Catalog.fileURL(file)
            let manifest = try EngineManifest.load(from: url)
            let engine = Engine(root: url.deletingLastPathComponent(), manifest: manifest)
            var problems: [String] = []
            if layout {
                do { try engine.validateLayout() } catch let error as OssoverError { problems.append(error.errorDescription ?? "\(error)") }
                for bundled in manifest.bundledRenderers {
                    let root = engine.root.appending(path: bundled.path, directoryHint: .isDirectory)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                        problems.append("bundled \(bundled.kind.rawValue): \(bundled.path) is not a directory")
                        continue
                    }
                    guard let layout = bundled.layout else { continue }
                    let pack = RendererPack(root: root, manifest: RendererPackManifest(
                        id: bundled.kind.rawValue, kind: bundled.kind, version: bundled.version ?? "", layout: layout))
                    for missing in pack.missingFiles {
                        problems.append("bundled \(bundled.kind.rawValue): layout file missing: \(missing.path)")
                    }
                }
            }
            if json {
                try Console.json(EngineRow(engine))
            } else {
                print("\(manifest.id): wine \(manifest.wineVersion), minMacOS \(manifest.minMacOS), capabilities "
                      + Format.list(manifest.capabilities.enabled) + ", bundled "
                      + Format.list(manifest.bundledRenderers.map { "\($0.kind.rawValue)@\($0.version ?? "?")" })
                      + ", source " + (manifest.source.isPinned ? "pinned" : "unpinned (TBD)")
                      + (layout ? (problems.isEmpty ? ", layout ok" : ", layout problems: \(problems.count)") : ""))
            }
            for problem in problems { Console.error(problem) }
            guard problems.isEmpty else { throw failure() }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an installed engine.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Engine id.") var id: String
        @Flag(help: "Remove even while processes run from the engine directory.") var force = false

        func run() async throws {
            let users = BottleStore(paths: global.paths).bottles(usingEngine: id)
            if !users.isEmpty { Console.warn("bottles still reference \(id): \(users.joined(separator: ", "))") }
            try await EngineStore(paths: global.paths).remove(id, force: force)
            print("removed engine \(id)")
        }
    }
}

struct EngineRow: Codable {
    var id: String
    var displayName: String
    var version: String
    var wineVersion: String
    var arch: String
    var capabilities: [String]
    var bundledRenderers: [String]
    var root: String
    var installed: Bool

    init(_ engine: Engine) {
        id = engine.id
        displayName = engine.manifest.displayName
        version = engine.manifest.version
        wineVersion = engine.manifest.wineVersion
        arch = engine.arch.rawValue
        capabilities = engine.capabilities.enabled
        bundledRenderers = engine.manifest.bundledRenderers.map(\.kind.rawValue)
        root = engine.root.path
        installed = engine.isInstalled
    }
}

struct VerifyRow: Codable {
    var id: String
    var ok: Bool
    var checked: Int
    var changed: [String]
    var missing: [String]
    var unlisted: [String]
}
