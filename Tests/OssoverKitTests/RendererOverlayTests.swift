// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Decision 14 (the GPTK pack layout a D3DMetal selection runs from; REA L-55, L-75) and the
// strategy-C materialisation of such a pack. Strategy B's copy plan is in PEBuiltinMarkTests,
// the winemetal gate and the bare overlay shape in ReviewFixTests.

@Suite struct GPTKPackLayoutTests {
    static let unixNames = ["d3d9.so", "d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so", "nvngx.so"]
    static let peNames = ["d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll"]

    static func touch(_ url: URL, _ text: String = "MZ") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// `renderers/d3dmetal-3.0` as `RendererStore.importGPTK` lays it out from `redist/lib`:
    /// `external/{libd3dshared.dylib, D3DMetal.framework}` beside `wine/x86_64-{unix,windows}`,
    /// every unix half a relative link to libd3dshared.
    static func gptkPack(under paths: OssoverPaths) throws -> RendererPack {
        let root = paths.renderer("d3dmetal-3.0")
        try touch(root.appending(path: "external/libd3dshared.dylib"), "dylib")
        try touch(root.appending(path: "external/D3DMetal.framework/Versions/A/D3DMetal"), "framework")
        for name in peNames { try touch(root.appending(path: "wine/x86_64-windows/\(name)")) }
        let unix = root.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        for name in unixNames {
            try FileManager.default.createSymbolicLink(atPath: unix.appending(path: name).path,
                                                       withDestinationPath: RendererPack.gptkUnixLinkTarget)
        }
        let manifest = RendererPackManifest(id: "d3dmetal-3.0", kind: .d3dmetal, version: "3.0", builtinMarked: true,
                                            requires: RendererRequires(macdrvExports: true),
                                            layout: RendererLayout(unix: unixNames, pe: peNames), overrides: [])
        return RendererPack(root: root, manifest: manifest)
    }

    @Test("a GPTK pack keeps external/ beside wine/ with every unix half linked to libd3dshared")
    func gptkLinks() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let pack = try Self.gptkPack(under: OssoverPaths(home: home))

        #expect(pack.wineDir.lastPathComponent == "wine", "an imported pack keeps the nested shape, external/ next to wine/")
        #expect(pack.gptkSharedLibrary == pack.externalDir.appending(path: "libd3dshared.dylib"))
        #expect(pack.missingFiles.isEmpty, "a link whose target exists counts as present")
        #expect(pack.gptkLinkIssues().isEmpty)

        // A regular file where a link belongs, and a link elsewhere, are reported by name.
        try FileManager.default.removeItem(at: pack.unixDir.appending(path: "d3d11.so"))
        try Self.touch(pack.unixDir.appending(path: "d3d11.so"), "real .so")
        try FileManager.default.removeItem(at: pack.unixDir.appending(path: "dxgi.so"))
        try FileManager.default.createSymbolicLink(atPath: pack.unixDir.appending(path: "dxgi.so").path,
                                                   withDestinationPath: "../../external/D3DMetal.framework/Versions/A/D3DMetal")
        let issues = pack.gptkLinkIssues()
        #expect(issues.count == 2)
        #expect(issues.contains { $0.hasPrefix("x86_64-unix/d3d11.so is a file, not a link to ../../external/libd3dshared.dylib") })
        #expect(issues.contains { $0.hasPrefix("x86_64-unix/dxgi.so links to ../../external/D3DMetal.framework/Versions/A/D3DMetal, not") })
        #expect(pack.missingFiles.isEmpty, "shape deviations are not missing files")

        // A dangling link is a missing file, not a link issue; other kinds are never checked.
        try FileManager.default.removeItem(at: pack.gptkSharedLibrary)
        #expect(pack.missingFiles.map(\.lastPathComponent) == ["d3d9.so", "d3d10.so", "d3d12.so", "nvngx.so"])
        #expect(pack.gptkLinkIssues().count == 2)
        #expect(Fixtures.dxmtPack.gptkLinkIssues().isEmpty)
        #expect(Fixtures.dxvkPack.gptkLinkIssues().isEmpty)
    }

    @Test("strategy C materialises a D3DMetal pack without touching the prefix and reports layout deviations")
    func d3dmetalPrepare() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let pack = try Self.gptkPack(under: paths)
        let engine = Engine(root: paths.engine("e"), manifest: Fixtures.manifest(id: "e", capabilities: Fixtures.crossOverPrepend))
        let bottle = Bottle(name: "b", engineID: engine.id, settings: BottleSettings(renderer: .d3dmetal))
        let layout = paths.bottleLayout("b")

        let selection = try RendererResolver.resolve(choice: .d3dmetal, engine: engine, packs: [pack])
        #expect(selection.strategy == .prepend, "D3DMetal has one strategy")
        #expect(selection.dllPath == pack.wineDir)
        #expect(selection.externalDir == pack.externalDir)

        let prepared = try RendererMaterializer.prepare(bottle: bottle, layout: layout, engine: engine, selection: selection)
        #expect(prepared.placed.isEmpty, "strategy C never touches the prefix")
        #expect(!FileManager.default.fileExists(atPath: layout.rendererState.path))
        #expect(!FileManager.default.fileExists(atPath: layout.prefix.path), "no prefix is needed or created")
        #expect(prepared.fragment.variables["WINEDLLPATH_PREPEND+"] == pack.wineDir.path)
        #expect(prepared.fragment.variables["WINEDLLPATH+"] == nil)
        #expect(prepared.fragment.variables["CX_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal", "REA L-19")
        // CX_APPLEGPTK_LIBD3DSHARED_PATH is a per-bottle row (decision 2, REA L-53: exported for every
        // process once a GPTK pack is accepted), not part of the renderer fragment; WineEnvironmentTests
        // covers it. The activation chain here is prepend + CX_ACTIVE_GRAPHICS_BACKEND (REA L-55).
        #expect(!prepared.notes.contains { $0.contains("not a link") })

        // A deviation from the GPTK shape is reported in the notes, not refused.
        try FileManager.default.removeItem(at: pack.unixDir.appending(path: "d3d12.so"))
        try Self.touch(pack.unixDir.appending(path: "d3d12.so"), "real .so")
        let deviating = try RendererMaterializer.prepare(bottle: bottle, layout: layout, engine: engine, selection: selection)
        #expect(deviating.notes.contains { $0 == "D3DMetal pack d3dmetal-3.0: x86_64-unix/d3d12.so is a file, not a link to ../../external/libd3dshared.dylib" })

        // Without WINEDLLPATH_PREPEND the same pack is refused (decision 14), whatever the selection claims.
        let bootstrap = Engine(root: paths.engine("boot"), manifest: Fixtures.manifest(id: "boot", capabilities: Fixtures.crossOver))
        let forced = RendererSelection(choice: .d3dmetal, kind: .d3dmetal, pack: pack, dllPath: pack.wineDir, strategy: .prepend)
        #expect(throws: OssoverError.self) {
            try RendererMaterializer.prepare(bottle: bottle, layout: layout, engine: bootstrap, selection: forced)
        }
        #expect(RendererMaterializer.unmet(selection: forced, engine: bootstrap) == [RendererResolver.d3dmetalPrependReason])

        // A pack whose libd3dshared is gone is refused with a pointer at the import.
        try FileManager.default.removeItem(at: pack.gptkSharedLibrary)
        #expect(throws: OssoverError.self) {
            try RendererMaterializer.prepare(bottle: bottle, layout: layout, engine: engine, selection: selection)
        }
    }
}
