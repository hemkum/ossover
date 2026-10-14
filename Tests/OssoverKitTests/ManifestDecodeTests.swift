// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct ManifestDecodeTests {
    @Test func shippedEngineManifestsValidate() throws {
        let catalog = try EngineStore.catalog(in: Fixtures.repoRoot.appending(path: "engines"))
        let ids = catalog.map(\.id)
        #expect(ids.contains("x64-frankea-wine11.16-cx26.3-v4.6.4b1"))
        #expect(ids.contains("x64-gcenx-wine-devel-11.18"))
        for manifest in catalog {
            #expect(manifest.schema == EngineManifest.currentSchema)
            #expect(manifest.arch == .x86_64)
            #expect(manifest.requiresRosetta)
            #expect(manifest.runs(onMacOS: Version([15, 0])))
        }
        let frankea = try #require(catalog.first { $0.id == "x64-frankea-wine11.16-cx26.3-v4.6.4b1" })
        #expect(frankea.wineVersionParsed == Version([11, 16]))
        #expect(frankea.capabilities.msync)
        #expect(frankea.capabilities.macdrvExports)
        #expect(frankea.capabilities.d3dmetalHost)
        #expect(!frankea.capabilities.dllPathPrepend)
        #expect(!frankea.capabilities.esync)
        #expect(frankea.capabilities.enabled == ["msync", "wow64", "macdrvExports", "d3dmetalHost"])
        #expect(frankea.bundledRendererKinds == [.dxmt, .dxvk])
        #expect(frankea.source.isPinned)
        #expect(frankea.source.size == 481_348_675)
        #expect(frankea.source.extract == ExtractSpec(strip: 1, into: "engine"))
        #expect(frankea.paths.wine == "engine/Wine/bin/wine")
        let gcenx = try #require(catalog.first { $0.id == "x64-gcenx-wine-devel-11.18" })
        #expect(!gcenx.source.isPinned)
        #expect(gcenx.capabilities.enabled == ["wow64"])
    }

    @Test func shippedRendererManifestsValidate() throws {
        let catalog = try RendererStore.catalog(in: Fixtures.repoRoot.appending(path: "renderers"))
        #expect(catalog.map(\.id).sorted() == ["dxmt-0.80", "dxvk-macos-1.10.3"])
        let dxmt = try #require(catalog.first { $0.id == "dxmt-0.80" })
        #expect(dxmt.kind == .dxmt)
        #expect(dxmt.builtinMarked)
        #expect(dxmt.requires.wineMin == "10.18")
        #expect(dxmt.requires.macdrvExports)
        #expect(dxmt.layout.relativePaths.contains("x86_64-unix/winemetal.so"))
        #expect(dxmt.layout.relativePaths.contains("x86_64-windows/d3d11.dll"))
        #expect(dxmt.layout.relativePaths.contains("i386-windows/dxgi.dll"))
        #expect(dxmt.overrides == ["dxgi,d3d11,d3d10core=n,b"])
        #expect(dxmt.source?.isPinned == true)
        #expect(dxmt.unmet(by: Fixtures.manifest(capabilities: Fixtures.crossOver)).isEmpty)
        #expect(!dxmt.unmet(by: Fixtures.manifest(capabilities: Fixtures.vanillaEsync)).isEmpty)
        let dxvk = try #require(catalog.first { $0.id == "dxvk-macos-1.10.3" })
        #expect(dxvk.kind == .dxvk)
        #expect(dxvk.unmet(by: Fixtures.manifest(capabilities: Fixtures.vanillaEsync)).isEmpty)
    }

    @Test func fixtureManifestsLoad() throws {
        let engine = try EngineManifest.load(from: Fixtures.url("manifests/test-engine.json"))
        #expect(engine.id == "test-engine")
        #expect(engine.capabilities == Fixtures.crossOver)
        #expect(!engine.source.isPinned)
        let pack = try RendererPackManifest.load(from: Fixtures.url("manifests/dxmt-test.json"))
        #expect(pack.source == nil)
        #expect(pack.layout.pe32 == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"])
        let resolved = RendererPack(root: Fixtures.paths.renderer(pack.id), manifest: pack)
        #expect(resolved.wineDir.path == "/ossover-test/renderers/dxmt-test/wine")
        #expect(resolved.expectedFiles.count == 9)
    }

    @Test func fixtureBottleDecodesWithItsOnDiskKeys() throws {
        let url = Fixtures.url("bottles/witcher3/bottle.json")
        let bottle = try Bottle.load(from: url)
        #expect(bottle.name == "witcher3")
        #expect(bottle.engineID == "test-engine")
        #expect(bottle.created == Date(timeIntervalSince1970: 1_791_892_800))
        #expect(bottle.settings.renderer == .dxmt)
        #expect(bottle.settings.sync == .msync)
        #expect(bottle.settings.env == ["ROSETTA_ADVERTISE_AVX": "1"])
        #expect(bottle.programs.map(\.id) == ["witcher3"])
        #expect(bottle.program(id: "witcher3")?.exe == #"C:\Games\The Witcher 3\bin\x64\witcher3.exe"#)
        #expect(bottle.program(id: "witcher3")?.args == ["--launcher-skip", "-skipStartScreen"])
        #expect(bottle.recipesApplied == ["witcher3-4.04-dx11"])
        #expect(bottle.recipeHistory.first?.version == "sha256:0123456789ab")
        #expect(bottle.steam?.appID == 292030)
        #expect(bottle.steam?.branch == "next-gen")
        #expect(bottle.steam?.buildID == "11916098")
        #expect(bottle.steam?.fetchedAt == Date(timeIntervalSince1970: 1_791_891_000))

        let encoded = String(decoding: try JSONDocument.encode(bottle), as: UTF8.self)
        #expect(encoded.contains("\"engineId\""))
        #expect(encoded.contains("\"appId\""))
        #expect(encoded.contains("\"buildId\""))
        #expect(!encoded.contains("\"engineID\""))
        let again = try JSONDocument.decode(Bottle.self, from: Data(encoded.utf8))
        #expect(again == bottle)
    }

    @Test func bottleWithMissingOptionalKeysTakesDefaults() throws {
        let minimal = #"{"schema":"ossover.bottle/1","name":"min","engineId":"test-engine"}"#
        let bottle = try JSONDocument.decode(Bottle.self, from: Data(minimal.utf8))
        try bottle.validate()
        #expect(bottle.settings == BottleSettings())
        #expect(bottle.programs.isEmpty)
        #expect(bottle.steam == nil)
        let wrongSchema = #"{"schema":"ossover.bottle/2","name":"min","engineId":"test-engine"}"#
        #expect(throws: OssoverError.self) { try JSONDocument.decode(Bottle.self, from: Data(wrongSchema.utf8)).validate() }
    }

    @Test func fixtureRecipeDecodesEveryStepAndRoundTrips() throws {
        let recipe = try Recipe.load(from: Fixtures.url("recipes/all-steps.json"))
        #expect(recipe.id == "fixture-all-steps")
        #expect(recipe.steps.count == 15)
        #expect(recipe.steps.map(\.typeName) == ["winver", "sync", "renderer", "retina", "registry", "registry", "dlloverride",
                                                  "env", "env", "winetricks", "file", "ini", "copy", "program", "note"])
        #expect(recipe.steps[3] == .retina(value: false, dpi: nil))
        #expect(recipe.steps[4] == .registry(key: #"HKCU\Software\Fixture"#, name: "Flag", type: .dword, data: "1"))
        #expect(recipe.steps[5] == .registry(key: #"HKCU\Software\Fixture"#, name: "Name", type: .string, data: "x"))
        #expect(recipe.steps[7] == .env(name: "FIXTURE_PROGRAM", value: "1", scope: .program))
        #expect(recipe.steps[8] == .env(name: "FIXTURE_BOTTLE", value: "2", scope: .bottle))
        #expect(recipe.steps[9] == .winetricks(verbs: ["corefonts"], optional: false, note: nil))
        #expect(recipe.steps[11] == .ini(path: #"${gameDir}\game.ini"#, section: nil, key: "Fullscreen", value: "0"))
        #expect(recipe.programs.map(\.id) == ["fixture-game"])
        #expect(recipe.programs.first?.launchMode == .start)
        #expect(recipe.touchesWine)
        #expect(recipe.usesGameDir)
        let data = try JSONDocument.encode(recipe)
        #expect(try JSONDocument.decode(Recipe.self, from: data) == recipe)
    }

    @Test func shippedRecipesValidate() throws {
        let witcher = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/witcher3.json"))
        #expect(witcher.id == "witcher3-4.04-dx11")
        #expect(witcher.requires.capabilities == ["msync"])
        #expect(witcher.requires.renderers == [.dxmt])
        #expect(witcher.gameDir == #"C:\Games\The Witcher 3"#)
        #expect(witcher.knownIssues.count == 6)
        #expect(witcher.knownIssues.contains { $0.fix?.contains("witcher3-vcrun") == true })
        let vcrun = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/witcher3-vcrun.json"))
        #expect(vcrun.steps.contains { if case .winetricks = $0 { return true } else { return false } })
        let steam = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/steam.json"))
        #expect(steam.id == "steam-client")
        #expect(steam.programs.first?.launchMode == .start)
    }
}
