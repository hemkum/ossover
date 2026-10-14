// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct RendererCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renderer",
        abstract: "Install renderer packs (DXMT, DXVK), import Apple's GPTK for D3DMetal and accept its licence.",
        subcommands: [List.self, Install.self, ImportGPTK.self, Accept.self, Remove.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Installed renderer packs, or the repository's catalog with --catalog.")

        @OptionGroup var global: GlobalOptions
        @Flag(help: "Print JSON.") var json = false
        @Flag(help: "List the repository's renderers/*.json instead of what is installed.") var catalog = false

        func run() async throws {
            if catalog { return try listCatalog() }
            let store = RendererStore(paths: global.paths)
            let rows = store.list(log: Console.logger).map { RendererRow($0, store: store) }
            if json { return try Console.json(rows) }
            guard !rows.isEmpty else {
                print("no renderer packs installed (ossover renderer install dxmt-0.80; engines may bundle one: ossover engine list)")
                return
            }
            Console.table(["ID", "Kind", "Version", "Status", "Licence"], rows.map {
                [$0.id, $0.kind, $0.version, $0.usable ? "usable" : ($0.reason ?? "unusable"), $0.licence]
            })
        }

        func listCatalog() throws {
            let manifests = try RendererStore.catalog(in: RepoRoot.renderers(in: try RepoRoot.require()))
            if json { return try Console.json(manifests) }
            let store = RendererStore(paths: global.paths)
            Console.table(["ID", "Kind", "Version", "Pinned", "Installed", "Source"], manifests.map {
                [$0.id, $0.kind.rawValue, $0.version, Table.yesNo($0.source?.isPinned ?? false), Table.yesNo(store.isInstalled($0.id)),
                 $0.source?.url.absoluteString ?? "-"]
            })
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download, verify and unpack a DXMT or DXVK pack from a manifest.")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "A manifest file, or an id/kind from the repository's renderers/ directory.") var manifest: String
        @Flag(help: "Reinstall over an existing pack directory (refused while a running bottle uses it).") var replace = false
        @Flag(help: "With --replace: reinstall even while running processes use the pack.") var force = false

        func run() async throws {
            let manifest = try Catalog.rendererManifest(self.manifest)
            Console.note("installing \(manifest.id) (\(manifest.kind.displayName) \(manifest.version))")
            let progress = ProgressPrinter(label: "download")
            let pack: RendererPack
            do {
                pack = try await RendererStore(paths: global.paths).install(manifest, replace: replace, force: force,
                                                                            progress: progress.handler, log: Console.logger)
            } catch {
                progress.finish()
                throw error
            }
            progress.finish()
            print("installed \(pack.id) at \(pack.root.path)")
        }
    }

    struct ImportGPTK: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-gptk",
            abstract: "Import D3DMetal from Apple's Game Porting Toolkit dmg (never downloaded by ossover).")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "The GPTK disk image you downloaded from Apple.") var dmg: String
        @Option(help: "Version to record when the framework does not say.") var version: String?
        @Flag(help: "Replace an existing pack of the same version (refused while a running bottle uses it).") var replace = false
        @Flag(help: "With --replace: reimport even while running processes use the pack.") var force = false

        func run() async throws {
            let url = Catalog.fileURL(dmg)
            guard FileManager.default.fileExists(atPath: url.path) else { throw OssoverError.missing(url.path) }
            let store = RendererStore(paths: global.paths)
            let pack = try await store.importGPTK(dmgURL: url, version: version, replace: replace, force: force, log: Console.logger)
            print("imported \(pack.id) at \(pack.root.path)")
            print("licence record: \(store.licenceRecordURL(for: pack.id).path)")
            if store.isUsable(pack) {
                print("licence already accepted for this dmg; the pack is usable")
            } else {
                print("D3DMetal stays unusable until you accept Apple's licence: ossover renderer accept \(pack.id)")
            }
        }
    }

    struct Accept: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record that you accept Apple's licence for an imported D3DMetal pack.")

        static let notice = """
            D3DMetal is part of Apple's Game Porting Toolkit. Apple licenses it for personal, non-commercial use and \
            forbids redistribution; ossover never downloads or ships it, you imported the dmg yourself. Accepting \
            records in licenses/ that you agree to Apple's terms for this pack, which unlocks `renderer d3dmetal`.
            """

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Pack id (ossover renderer list).") var id: String
        @Flag(name: .customLong("yes"), help: "Skip the confirmation prompt.") var yes = false

        func run() async throws {
            let store = RendererStore(paths: global.paths)
            let pack = try store.pack(id)
            guard pack.kind.needsLicence else {
                print("\(pack.id) (\(pack.kind.displayName)) needs no licence acceptance")
                return
            }
            if let record = store.licenceRecord(for: pack.id), record.isAccepted {
                print("already accepted at \(Format.date(record.acceptedAt))")
                return
            }
            print(Self.notice)
            if !yes {
                guard Console.confirm("Accept Apple's Game Porting Toolkit licence for \(pack.id)?") else {
                    Console.error("not accepted (answer y, or pass --yes)")
                    throw failure()
                }
            }
            let record = try store.accept(pack.id)
            print("accepted \(pack.id) at \(Format.date(record.acceptedAt)); record \(store.licenceRecordURL(for: pack.id).path)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an installed renderer pack (its licence record is kept).")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Pack id.") var id: String

        func run() async throws {
            try RendererStore(paths: global.paths).remove(id)
            print("removed renderer \(id)")
        }
    }
}

struct RendererRow: Codable {
    var id: String
    var kind: String
    var version: String
    var root: String
    var builtinMarked: Bool
    var usable: Bool
    var reason: String?
    var licenceAccepted: Bool?
    var licence: String

    init(_ pack: RendererPack, store: RendererStore) {
        id = pack.id
        kind = pack.kind.rawValue
        version = pack.manifest.version
        root = pack.root.path
        builtinMarked = pack.manifest.builtinMarked
        usable = store.isUsable(pack)
        reason = store.unusableReason(pack)
        if pack.kind.needsLicence {
            let record = store.licenceRecord(for: pack.id)
            licenceAccepted = record?.isAccepted ?? false
            licence = record.map { $0.isAccepted ? "accepted \(Format.date($0.acceptedAt))" : "not accepted" } ?? "no record"
        } else {
            licenceAccepted = nil
            licence = "-"
        }
    }
}
