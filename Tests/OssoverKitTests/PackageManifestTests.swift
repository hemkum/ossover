// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// The manifest `engine/package.sh` writes (through `engine/manifest.py`) must be one
/// `EngineManifest` decodes and `EngineStore.install` accepts. The fixture is the writer's own
/// output on the synthetic tree of `engine/selftest.sh --write-fixture`, so these tests pin the
/// contract between the packager and the Swift model (docs/rea/decisions.md 28, 29, 32).
@Suite struct PackageManifestTests {
    static let fixture = "manifests/package-sh-engine.json"

    @Test func packagerManifestDecodesAndValidates() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.schema == EngineManifest.currentSchema)
        #expect(manifest.id == "x64-ossover-cx26.3-r1")
        #expect(manifest.version == "26.3.0-r1")
        #expect(manifest.wineVersionParsed == Version([11, 0]))
        #expect(manifest.wineVersionString == "wine-11.0-8726-g2e2f5fca349")   // REA L-45, read from ntdll.so
        #expect(manifest.arch == .x86_64)
        #expect(manifest.requiresRosetta)
        #expect(manifest.addons == EngineAddons(wineMono: "10.4.1", wineGecko: "2.47.4"))
        #expect(manifest.notes.count == 4)
    }

    /// The tarball is `<id>/…`, so the installer strips one component into the engine root; the
    /// copy inside the tarball cannot know its own hash and stays unpinned.
    @Test func sourceBlockIsAnArtifactSource() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.source.extract == ExtractSpec(strip: 1, into: "."))
        #expect(!manifest.source.isPinned)
        #expect(manifest.source.url.isFileURL)
        #expect(manifest.source.url.lastPathComponent == "x64-ossover-cx26.3-r1.tar.xz")
        #expect(manifest.source.extract?.destination(under: Fixtures.paths.engine(manifest.id)) == Fixtures.paths.engine(manifest.id))
    }

    /// `paths` is the Swift `EnginePaths` shape and resolves to the plan §5 layout; no
    /// `frameworks` directory, because no `DYLD_*` row exists for it to feed (REA L-54).
    @Test func pathsResolveToThePlanLayout() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.paths == EnginePaths(wine: "wine/bin/wine", wineserver: "wine/bin/wineserver", libWine: "wine/lib/wine"))
        let engine = Engine(root: Fixtures.paths.engine(manifest.id), manifest: manifest)
        #expect(engine.wine.path == "/ossover-test/engines/x64-ossover-cx26.3-r1/wine/bin/wine")
        #expect(engine.unixLibDir.path == "/ossover-test/engines/x64-ossover-cx26.3-r1/wine/lib/wine/x86_64-unix")
        #expect(engine.libDir.path == "/ossover-test/engines/x64-ossover-cx26.3-r1/wine/lib")
        #expect(engine.gstreamerPlugins.path == "/ossover-test/engines/x64-ossover-cx26.3-r1/wine/lib/gstreamer-1.0")
        #expect(engine.frameworks == nil)
    }

    /// Measured on the tree: msync/wow64/macdrvExports/dllPathPrepend/d3dmetalHost on, esync off
    /// (the CrossOver tree does not compile it in, REA L-32) — the same shape `Fixtures.crossOverPrepend`
    /// describes for the plan's own engine.
    @Test func capabilitiesAreTheCrossOverPrependSet() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.capabilities == Fixtures.crossOverPrepend)
        #expect(!manifest.capabilities.esync)
        #expect(manifest.capabilities.enabled == ["msync", "wow64", "macdrvExports", "dllPathPrepend", "d3dmetalHost"])
    }

    /// GStreamer rows only; the rpath rule carries the tree, so no `DYLD_*` row (REA L-12, L-54).
    @Test func baseEnvHasNoDyldRows() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.baseEnv.keys.allSatisfy { !$0.hasPrefix("DYLD_") })
        #expect(manifest.baseEnv["GST_PLUGIN_SYSTEM_PATH"] == "${engine}/wine/lib/gstreamer-1.0")
        #expect(manifest.baseEnv["GST_PLUGIN_SCANNER"] == "${engine}/wine/libexec/gstreamer-1.0/gst-plugin-scanner")
        #expect(manifest.baseEnv["GST_REGISTRY"] == "${engine}/gst-registry-x86_64.bin")
    }

    /// Bundled overlays in CrossOver's bare shape (`overlays/<kind>/{x86_64-unix,x86_64-windows,
    /// i386-windows}`, REA L-23) with the file-name `layout` decision 16(c) asks for, builtin
    /// marked (strategy C), resolvable through `Engine.bundledRendererURL` and `RendererPack.wineDir`.
    @Test func bundledRenderersAreBareOverlaysWithLayouts() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.bundledRendererKinds == [.dxmt, .dxvk])
        let dxmt = try #require(manifest.bundledRenderer(.dxmt))
        #expect(dxmt.version == "0.80")
        #expect(dxmt.path == "overlays/dxmt")
        #expect(dxmt.builtinMarked == true)
        #expect(dxmt.layout?.unix == ["winemetal.so"])
        #expect(dxmt.layout?.pe == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll", "winemetal.dll"])
        #expect(dxmt.layout?.pe32 == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"])
        let dxvk = try #require(manifest.bundledRenderer(.dxvk))
        #expect(dxvk.version == "1.10.3-20230507-repack", "the components[].dxvk-macos spelling, parsed from the pinned URL (decision 32)")
        #expect(dxvk.layout?.unix == [])
        #expect(dxvk.layout?.pe == ["d3d10core.dll", "d3d11.dll", "d3d9.dll", "dxgi.dll"])
        #expect(dxvk.builtinMarked == true)

        let engine = Engine(root: Fixtures.paths.engine(manifest.id), manifest: manifest)
        #expect(engine.bundledRendererURL(.dxmt) == engine.overlay(.dxmt))
        #expect(engine.bundledRendererURL(.d3dmetal) == nil)
        let pack = RendererPack(root: engine.overlay(.dxmt), manifest: RendererPackManifest(
            id: "dxmt", kind: .dxmt, version: dxmt.version ?? "", layout: dxmt.layout ?? RendererLayout()))
        // the directory does not exist on disk, so `wineDir` falls back to the nested shape; the
        // layout still names 11 files under it
        #expect(pack.expectedFiles.count == 11)
        #expect(pack.expectedFiles.contains { $0.lastPathComponent == "winemetal.so" })
    }

    /// `minMacOS` is max(toolchain floor 15.0, overlay floor 14.0): the engine runs on 15 and not
    /// on 14 (REA L-62, L-78; decision 29). The per-renderer floor is a packaging-record key the
    /// model ignores, so it must be visible in the JSON but absent after a round trip.
    @Test func minMacOSFollowsTheOverlayRule() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        #expect(manifest.minMacOS == "15.0")
        #expect(manifest.runs(onMacOS: Version([15, 0])))
        #expect(!manifest.runs(onMacOS: Version([14, 7])))
        let raw = try Fixtures.text(Self.fixture)
        #expect(raw.contains("\"minMacOS\": \"14.0\""))
        #expect(raw.contains("\"overlayMinMacOS\": \"14.0\""))
        #expect(raw.contains("\"deploymentTarget\": \"15.0\""))
    }

    /// What `EngineStore.install` does: decode, re-encode with the Swift model, decode again. The
    /// packaging-record keys vanish, the model's keys survive unchanged.
    @Test func survivesTheInstallRoundTrip() throws {
        let manifest = try EngineManifest.load(from: Fixtures.url(Self.fixture))
        let data = try JSONDocument.encode(manifest)
        let again = try JSONDocument.decode(EngineManifest.self, from: data)
        try again.validate()
        #expect(again == manifest)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains("\"wineVersionString\""))
        #expect(encoded.contains("\"wineMono\""))
        #expect(!encoded.contains("\"components\""))
        #expect(!encoded.contains("\"overlayMinMacOS\""))
        #expect(!encoded.contains("\"requires\": {"))
    }

    /// The shape before this pass (`extract` as a string, extra `paths` keys, `winemetalBuiltin`
    /// inside `capabilities`) must not decode: it is what `ossover engine install` would have
    /// crashed on.
    @Test func preReaShapeIsRejected() throws {
        var json = try JSONSerialization.jsonObject(with: Fixtures.data(Self.fixture)) as! [String: Any]
        var source = json["source"] as! [String: Any]
        source["extract"] = "x64-ossover-cx26.3-r1/"
        json["source"] = source
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: OssoverError.self) { try JSONDocument.decode(EngineManifest.self, from: data) }

        var noSource = json
        noSource["source"] = nil
        let data2 = try JSONSerialization.data(withJSONObject: noSource)
        #expect(throws: OssoverError.self) { try JSONDocument.decode(EngineManifest.self, from: data2) }
    }
}
