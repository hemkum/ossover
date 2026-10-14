// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Store-side tests for the REA decisions (docs/rea/decisions.md): 14 (GPTK import kept verbatim,
// links recreated, `anchor apple`), 16(d) (bundled overlays laid out and recorded from disk),
// 29 (minMacOS floor with a DXMT/D3DMetal overlay), the engine-manifest contract with
// engine/package.sh, the packager's SHA256SUMS, and the wine version string read from ntdll.so.

private func touch(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private func touch(_ url: URL, _ text: String = "MZ") throws { try touch(url, Data(text.utf8)) }

/// A thin 64-bit Mach-O magic followed by padding: enough for `EngineIntegrity.isMachO`.
private let machOStub = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(repeating: 0, count: 60)

@Suite struct EngineProbeVersionTests {
    @Test("the wine-<version> token is cut out of a glued strings line")
    func versionFromStrings() {
        #expect(EngineProbe.wineVersionString(in: "abc\n0123456789abcdefwine-11.16\nwine-later") == "wine-11.16")
        #expect(EngineProbe.wineVersionString(in: "x\nwine-11.0-8726-g2e2f5fca349\n") == "wine-11.0-8726-g2e2f5fca349")
        #expect(EngineProbe.wineVersionString(in: "wine-11.16.1\n") == "wine-11.16.1")
        #expect(EngineProbe.wineVersionString(in: "wine-foo\nWINEMSYNC\n") == nil)
        #expect(EngineProbe.wineVersionString(in: "") == nil)
    }

    @Test("the byte-scan fallback finds the same token")
    func versionFromBytes() {
        let data = Data([0, 0, 0x41]) + Data("wine-x".utf8) + Data([0]) + Data("abcwine-11.16".utf8) + Data([0, 0x42])
        #expect(EngineProbe.scanWineVersion(in: data) == "wine-11.16")
        #expect(EngineProbe.scanWineVersion(in: Data("no version here".utf8)) == nil)
        #expect(EngineProbe.scanWineVersion(in: Data()) == nil)
    }

    @Test("the manifest's wineVersion is checked against the binary's first two components")
    func disagreement() {
        #expect(EngineProbe.wineVersionDisagreement(probed: "wine-11.16", declared: "11.16") == nil)
        #expect(EngineProbe.wineVersionDisagreement(probed: "wine-11.16", declared: "11.16.0") == nil)
        #expect(EngineProbe.wineVersionDisagreement(probed: nil, declared: "11.16") == nil)
        #expect(EngineProbe.wineVersionDisagreement(probed: "wine-11.0-8726-g2e2f5fca349", declared: "11.16")?.contains("ntdll.so says wine-11.0") == true)
        #expect(EngineProbe.wineVersionDisagreement(probed: "garbage", declared: "11.16") == nil)
    }

    @Test("the probe carries the version string beside the capabilities")
    func probeField() {
        let probe = EngineProbe(msync: true, wineVersionString: "wine-11.16")
        #expect(probe.wineVersionString == "wine-11.16")
        #expect(probe.capabilities(over: EngineCapabilities()).msync)
        #expect(probe.disagreements(with: EngineCapabilities()).count == 1)
    }
}

@Suite struct EngineManifestContractTests {
    /// What `engine/package.sh` writes (its `manifest` section), with the `source` block the
    /// out-dir copy gets after the tar, in the object form `ExtractSpec` decodes.
    static let packaged = """
        {
          "schema": "ossover.engine-manifest/1",
          "id": "x64-ossover-cx26.3-r1",
          "displayName": "ossover Wine 11.0 (CrossOver 26.3.0 sources) r1",
          "version": "26.3.0-r1",
          "wineVersion": "11.0",
          "wineVersionString": "wine-11.0-8726-g2e2f5fca349",
          "arch": "x86_64",
          "minMacOS": "15.0",
          "requires": ["rosetta2"],
          "paths": { "wine": "wine/bin/wine", "wineserver": "wine/bin/wineserver", "libWine": "wine/lib/wine",
                     "unixLib": "wine/lib/wine/x86_64-unix", "pe64Lib": "wine/lib/wine/x86_64-windows", "pe32Lib": "wine/lib/wine/i386-windows",
                     "lib": "wine/lib", "share": "wine/share/wine", "mono": "wine/share/wine/mono", "gecko": "wine/share/wine/gecko" },
          "baseEnv": { "GST_PLUGIN_SYSTEM_PATH": "${engine}/wine/lib/gstreamer-1.0" },
          "capabilities": { "msync": true, "esync": false, "wow64": true, "macdrvExports": true, "dllPathPrepend": true, "d3dmetalHost": true,
                            "winemetalBuiltin": true },
          "bundledRenderers": [
            { "id": "dxmt", "kind": "dxmt", "version": "0.80", "path": "overlays/dxmt",
              "layout": { "unix": ["winemetal.so"], "pe": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll", "winemetal.dll"],
                          "pe32": ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] },
              "builtinMarked": true, "requires": { "macdrvExports": true, "dllPathPrepend": true } },
            { "id": "dxvk", "kind": "dxvk", "version": "1.10.3-async-20230507-repack", "path": "overlays/dxvk",
              "layout": { "pe": ["d3d10core.dll", "d3d11.dll"], "pe32": ["d3d10core.dll", "d3d11.dll"] },
              "builtinMarked": true, "requires": { "dllPathPrepend": true } }
          ],
          "addons": { "wineMono": "10.4.1", "wineGecko": "2.47.4" },
          "components": [ { "id": "dxmt", "version": "0.80", "url": "https://example.invalid/dxmt", "sha256": null, "size": null,
                            "license": "MIT", "bundled": true, "path": "overlays/dxmt" } ],
          "build": { "date": "2026-10-14T00:00:00Z", "patches": ["0001-use-the-real-user-name.patch"], "gstreamerPlugins": 120 },
          "licenses": { "wine": "LGPL-2.1-or-later", "note": "D3DMetal is never bundled" },
          "source": { "url": "file:///tmp/x64-ossover-cx26.3-r1.tar.xz", "sha256": "TBD", "size": 123, "kind": "tar.xz",
                      "extract": { "strip": 1, "into": "." } }
        }
        """

    @Test("a package.sh manifest decodes, keeps the new keys and round-trips")
    func packagedManifestDecodes() throws {
        let manifest = try JSONDocument.decode(EngineManifest.self, from: Data(Self.packaged.utf8))
        try manifest.validate()
        #expect(manifest.wineVersionString == "wine-11.0-8726-g2e2f5fca349")
        #expect(manifest.addons == EngineAddons(wineMono: "10.4.1", wineGecko: "2.47.4"))
        #expect(manifest.capabilities == Fixtures.crossOverPrepend)
        #expect(manifest.paths == EnginePaths(wine: "wine/bin/wine", wineserver: "wine/bin/wineserver", libWine: "wine/lib/wine"))
        #expect(manifest.bundledRendererKinds == [.dxmt, .dxvk])
        #expect(manifest.bundledRenderer(.dxmt)?.layout?.unix == ["winemetal.so"])
        #expect(manifest.bundledRenderer(.dxvk)?.layout?.pe32 == ["d3d10core.dll", "d3d11.dll"])
        #expect(manifest.source.extract == ExtractSpec(strip: 1, into: "."))
        #expect(!manifest.source.isPinned)
        #expect(EngineProbe.wineVersionDisagreement(probed: manifest.wineVersionString, declared: manifest.wineVersion) == nil)

        let encoded = String(decoding: try JSONDocument.encode(manifest), as: UTF8.self)
        #expect(encoded.contains("\"wineVersionString\" : \"wine-11.0-8726-g2e2f5fca349\""))
        #expect(encoded.contains("\"wineMono\" : \"10.4.1\""))
        #expect(try JSONDocument.decode(EngineManifest.self, from: Data(encoded.utf8)) == manifest)
    }

    @Test("a manifest without the new keys encodes none of them")
    func absentKeysStayAbsent() throws {
        let manifest = Fixtures.manifest(capabilities: Fixtures.crossOver)
        #expect(manifest.wineVersionString == nil)
        #expect(manifest.addons == nil)
        let encoded = String(decoding: try JSONDocument.encode(manifest), as: UTF8.self)
        #expect(!encoded.contains("wineVersionString"))
        #expect(!encoded.contains("addons"))
    }

    @Test("the shipped frankea manifest records the probed version string and add-ons")
    func frankeaRecordsEvidence() throws {
        let catalog = try EngineStore.catalog(in: Fixtures.repoRoot.appending(path: "engines"))
        let frankea = try #require(catalog.first { $0.id == "x64-frankea-wine11.16-cx26.3-v4.6.4b1" })
        #expect(frankea.wineVersionString == "wine-11.16")
        #expect(EngineProbe.wineVersionDisagreement(probed: frankea.wineVersionString, declared: frankea.wineVersion) == nil)
        #expect(frankea.addons?.wineMono == "11.3.0")
        #expect(frankea.addons?.wineGecko == "2.47.4")
        #expect(frankea.bundledRenderer(.dxmt)?.layout?.unix == [], "DXMT/x64 holds no .so (tar tzf)")
        #expect(frankea.bundledRenderer(.dxmt)?.builtinMarked == false)
    }

    @Test("minMacOS is raised to 14.0 only with a DXMT or D3DMetal overlay on disk (decision 29)")
    func minMacOSFloor() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = OssoverPaths(home: home).engine("e")
        func manifest(_ minMacOS: String, _ bundles: [BundledRenderer]) -> EngineManifest {
            var m = Fixtures.manifest(id: "e", capabilities: Fixtures.crossOverPrepend)
            m.minMacOS = minMacOS
            m.bundledRenderers = bundles
            return m
        }
        let dxmt = BundledRenderer(kind: .dxmt, version: "0.80", path: "overlays/dxmt")
        let dxvk = BundledRenderer(kind: .dxvk, version: "1.10.3", path: "overlays/dxvk")
        let d3dmetal = BundledRenderer(kind: .d3dmetal, version: "3.0", path: "overlays/d3dmetal")

        #expect(EngineStore.minMacOSFloor(for: manifest("10.15", [dxmt]), root: root) == "10.15", "no overlay directory yet")
        try touch(root.appending(path: "overlays/dxmt/x86_64-windows/d3d11.dll"))
        try touch(root.appending(path: "overlays/dxvk/x86_64-windows/d3d11.dll"))
        try touch(root.appending(path: "overlays/d3dmetal/x86_64-windows/d3d11.dll"))
        #expect(EngineStore.minMacOSFloor(for: manifest("10.15", [dxmt]), root: root) == "14.0")
        #expect(EngineStore.minMacOSFloor(for: manifest("13.0", [d3dmetal]), root: root) == "14.0")
        #expect(EngineStore.minMacOSFloor(for: manifest("15.0", [dxmt]), root: root) == "15.0", "the toolchain floor is already above")
        #expect(EngineStore.minMacOSFloor(for: manifest("14.0", [dxmt]), root: root) == "14.0")
        #expect(EngineStore.minMacOSFloor(for: manifest("10.15", [dxvk]), root: root) == "10.15", "DXVK/MoltenVK is not a 14.0 overlay")
        #expect(EngineStore.minMacOSFloor(for: manifest("10.15", []), root: root) == "10.15")
        #expect(EngineStore.overlayMinMacOS == "14.0")
    }
}

@Suite struct EngineStoreInstallPiecesTests {
    @Test("the packager's SHA256SUMS is verified and carried into the installed sums")
    func packagerSums() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let staging = home.appending(path: ".e.partial", directoryHint: .isDirectory)
        let note = Data("hello".utf8)
        try touch(staging.appending(path: "wine/share/wine/wine.inf"), note)
        try touch(staging.appending(path: "wine/lib/wine/x86_64-unix/ntdll.so"), machOStub)
        try touch(staging.appending(path: "manifest.json"), Data("{}".utf8))
        let sums = [
            SHA256Hasher.Entry(path: "wine/share/wine/wine.inf", sha256: SHA256Hasher.hex(of: note)),
            SHA256Hasher.Entry(path: "wine/lib/wine/x86_64-unix/ntdll.so", sha256: SHA256Hasher.hex(of: machOStub)),
            SHA256Hasher.Entry(path: "manifest.json", sha256: SHA256Hasher.hex(of: Data("{}".utf8))),
        ]
        try touch(staging.appending(path: "SHA256SUMS"), Data(SHA256Hasher.formatSums(sums).utf8))

        #expect(try EngineStore.verifyPackagerSums(in: home.appending(path: "nothing-here"), under: home, engineID: "e").isEmpty)
        let lines = LineCollector()
        let verified = try EngineStore.verifyPackagerSums(in: staging, under: staging, engineID: "e") { lines.append($0) }
        #expect(verified.map(\.path).sorted() == ["manifest.json", "wine/lib/wine/x86_64-unix/ntdll.so", "wine/share/wine/wine.inf"])
        #expect(lines.lines.contains { $0.contains("verified 3 files") })

        // The merged SHA256SUMS: Mach-O files hashed here, the packager's data files carried over,
        // the rewritten manifest.json left out.
        try touch(staging.appending(path: "manifest.json"), Data("{\"rewritten\":true}".utf8))
        let written = try EngineIntegrity.writeSums(root: staging, to: staging.appending(path: "SHA256SUMS"), merging: verified)
        #expect(written.map(\.path) == ["wine/lib/wine/x86_64-unix/ntdll.so", "wine/share/wine/wine.inf"])
        let report = try EngineIntegrity.verify(root: staging, sumsFile: staging.appending(path: "SHA256SUMS"))
        #expect(report.ok && report.checked == 2)

        // A tree extracted into a subdirectory gets its paths rebased.
        let nested = home.appending(path: ".n.partial", directoryHint: .isDirectory)
        try touch(nested.appending(path: "engine/a.txt"), note)
        try touch(nested.appending(path: "engine/SHA256SUMS"), Data("\(SHA256Hasher.hex(of: note))  a.txt\n".utf8))
        #expect(try EngineStore.verifyPackagerSums(in: nested.appending(path: "engine"), under: nested, engineID: "n").map(\.path) == ["engine/a.txt"])

        // A damaged file stops the install.
        try touch(nested.appending(path: "engine/a.txt"), Data("tampered".utf8))
        #expect(throws: OssoverError.self) { try EngineStore.verifyPackagerSums(in: nested.appending(path: "engine"), under: nested, engineID: "n") }
    }

    @Test("a Whisky-shaped bundle is laid out as overlays/<kind> and recorded from the files (decision 16(d))")
    func bundleRefreshedFromDisk() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = OssoverPaths(home: home).engine("e")
        for name in ["d3d10core", "d3d11", "dxgi", "winemetal"] { try touch(root.appending(path: "engine/DXMT/x64/\(name).dll"), PEBuiltinMarkTests.marked) }
        try touch(root.appending(path: "engine/DXMT/x64/winemetal.so"), Data("so".utf8))
        for name in ["d3d11", "dxgi"] { try touch(root.appending(path: "engine/DXMT/x32/\(name).dll"), PEBuiltinMarkTests.marked) }
        var manifest = Fixtures.manifest(id: "e", capabilities: Fixtures.crossOver)
        manifest.bundledRenderers = [BundledRenderer(kind: .dxmt, version: "0.80", path: "engine/DXMT", layout: RendererLayout(pe: ["d3d11.dll"]), builtinMarked: false)]

        let lines = LineCollector()
        let installed = try EngineStore.normalizeBundledRenderers(manifest, root: root) { lines.append($0) }
        let bundled = try #require(installed.bundledRenderer(.dxmt))
        #expect(bundled.path == "overlays/dxmt")
        #expect(bundled.layout == RendererLayout(unix: ["winemetal.so"], pe: ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"], pe32: ["d3d11.dll", "dxgi.dll"]))
        #expect(bundled.builtinMarked == true, "recorded from the DOS stub, not from the manifest")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "overlays/dxmt/x86_64-unix/winemetal.so").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "overlays/dxmt/x86_64-windows/winemetal.so").path))
        #expect(lines.lines.contains { $0.contains("moved x86_64-windows/winemetal.so to x86_64-unix/") })
        #expect(lines.lines.contains { $0.contains("manifest says builtinMarked false, d3d10core.dll says true") })
        #expect(lines.lines.contains { $0.contains("layout recorded from the files") })

        // The synthesised pack matches the files, and a second pass changes nothing.
        let engine = Engine(root: root, manifest: installed)
        let pack = try #require(RendererResolver.bundledPacks(engine: engine).first)
        #expect(pack.missingFiles.isEmpty)
        #expect(pack.manifest.builtinMarked)
        #expect(pack.wineDir == engine.overlay(.dxmt))
        #expect(try EngineStore.normalizeBundledRenderers(installed, root: root) == installed)
        #expect(EngineStore.minMacOSFloor(for: installed, root: root) == "15.0")
    }
}

@Suite struct CodeSignTests {
    static let appleInfo = """
        Executable=/x/libd3dshared.dylib
        Identifier=com.apple.libd3dshared
        Format=Mach-O thin (x86_64)
        Authority=Software Signing
        Authority=Apple Code Signing Certification Authority
        Authority=Apple Root CA
        """

    @Test("Apple's own chain is told apart from Developer ID and App Store chains")
    func anchorApple() {
        let parsed = CodeSign.parseInfo(Self.appleInfo)
        #expect(parsed.identifier == "com.apple.libd3dshared")
        #expect(parsed.authorities == ["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"])
        #expect(CodeSign.chainAnchorsAtApple(parsed.authorities))
        #expect(!CodeSign.chainAnchorsAtApple(["Developer ID Application: Some Corp (ABCDE12345)", "Developer ID Certification Authority", "Apple Root CA"]))
        #expect(!CodeSign.chainAnchorsAtApple(["Apple Mac OS Application Signing", "Apple Worldwide Developer Relations Certification Authority", "Apple Root CA"]))
        #expect(!CodeSign.chainAnchorsAtApple([]))
        #expect(!CodeSign.chainAnchorsAtApple(["Software Signing"]))
        #expect(CodeSign.appleAnchorRequirement == "=anchor apple", "codesign -R's inline form; a bare 'anchor apple' is read as a file path")
    }

    @Test("a framework is verified through its binary")
    func frameworkBinary() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fw = home.appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
        try touch(fw.appending(path: "Versions/A/D3DMetal"), machOStub)
        try FileManager.default.createSymbolicLink(atPath: fw.appending(path: "Versions/Current").path, withDestinationPath: "A")
        #expect(CodeSign.frameworkBinary(fw) == fw.appending(path: "Versions/Current/D3DMetal"))
        #expect(CodeSign.frameworkBinary(home.appending(path: "libd3dshared.dylib")) == nil)
        let flat = home.appending(path: "Flat.framework", directoryHint: .isDirectory)
        try touch(flat.appending(path: "Flat"), machOStub)
        #expect(CodeSign.frameworkBinary(flat) == flat.appending(path: "Flat"))
    }

    @Test("a signed-file record round-trips its anchor result")
    func signedFileRoundTrip() throws {
        let signed = SignedFile(path: "external/libd3dshared.dylib", identifier: "com.apple.libd3dshared", authorities: ["Software Signing"], verified: true, anchorApple: true)
        let data = try JSONDocument.encode(signed)
        #expect(try JSONDocument.decode(SignedFile.self, from: data) == signed)
        let legacy = try JSONDocument.decode(SignedFile.self, from: Data(#"{"path":"p","verified":true}"#.utf8))
        #expect(legacy.anchorApple == nil)
    }
}

@Suite struct GPTKImportTests {
    static let unixNames = ["d3d9.so", "d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so", "nvngx-on-metalfx.so"]
    static let peNames = ["d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx-on-metalfx.dll"]

    /// A toolkit's `redist/lib` as GPTK 3 ships it (REA L-55): `external/{libd3dshared.dylib,
    /// D3DMetal.framework}` and `wine/x86_64-{unix,windows}` with every `.so` a link to
    /// `../../external/libd3dshared.dylib`.
    static func toolkit(at root: URL) throws -> URL {
        let lib = root.appending(path: "redist/lib", directoryHint: .isDirectory)
        try touch(lib.appending(path: "external/libd3dshared.dylib"), machOStub)
        let fw = lib.appending(path: "external/D3DMetal.framework", directoryHint: .isDirectory)
        try touch(fw.appending(path: "Versions/A/D3DMetal"), machOStub + Data("metal".utf8))
        try touch(fw.appending(path: "Versions/A/Resources/Info.plist"), Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>3.0</string></dict></plist>
            """.utf8))
        try FileManager.default.createSymbolicLink(atPath: fw.appending(path: "Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: fw.appending(path: "D3DMetal").path, withDestinationPath: "Versions/Current/D3DMetal")
        let unix = lib.appending(path: "wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        for name in unixNames {
            try FileManager.default.createSymbolicLink(atPath: unix.appending(path: name).path, withDestinationPath: RendererStore.gptkUnixLinkTarget)
        }
        for name in peNames { try touch(lib.appending(path: "wine/x86_64-windows/\(name)")) }
        return lib
    }

    static func appleSigned(_ file: URL, _ path: String) -> SignedFile {
        SignedFile(path: path, identifier: "com.apple.\(file.deletingPathExtension().lastPathComponent)",
                   authorities: ["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"], verified: true, anchorApple: true)
    }

    @Test("the toolkit is staged verbatim: links kept, signatures recorded, no overrides")
    func stageKeepsEverything() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = try Self.toolkit(at: home.appending(path: "dmg"))
        let stage = home.appending(path: "renderers/.d3dmetal-3.0.partial", directoryHint: .isDirectory)
        let dmg = ImportedArtifact(fileName: "Game_Porting_Toolkit_3.0.dmg", sha256: String(repeating: "ab", count: 32), size: 1)
        let lines = LineCollector()
        let staged = try await RendererStore.stageGPTK(redistLib: lib, into: stage, id: "d3dmetal-3.0", version: "3.0", dmg: dmg,
                                                       inspect: { file, path in Self.appleSigned(file, path) }) { lines.append($0) }

        #expect(RendererStore.gptkVersion(frameworkDirectory: lib.appending(path: "external/D3DMetal.framework")) == "3.0")
        #expect(staged.manifest.id == "d3dmetal-3.0")
        #expect(staged.manifest.kind == .d3dmetal)
        #expect(staged.manifest.overrides.isEmpty, "activation is by prepended path + CX_* env, no WINEDLLOVERRIDES (decisions 14, 39)")
        #expect(staged.manifest.requires.macdrvExports)
        #expect(staged.manifest.layout.unix == Self.unixNames.sorted())
        #expect(staged.manifest.layout.pe == Self.peNames.sorted())
        #expect(staged.manifest.layout.pe32 == nil)
        #expect(!staged.manifest.builtinMarked)
        #expect(staged.manifest.notes.contains { $0.contains("anchor apple") && $0.contains("never re-signed") })
        #expect(staged.manifest.notes.contains { $0.contains(RendererStore.gptkUnixLinkTarget) })

        let pack = try RendererPack.load(root: stage)
        #expect(pack.missingFiles.isEmpty)
        #expect(pack.wineDir.path == stage.appending(path: "wine").path)
        for name in Self.unixNames {
            let link = pack.unixDir.appending(path: name)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == RendererStore.gptkUnixLinkTarget)
            #expect(FileManager.default.fileExists(atPath: link.path), "the link resolves inside the pack")
        }
        #expect(RendererStore.unixLinkTargets(in: pack.wineDir).count == 6)
        #expect(try RendererStore.verbatimMismatches(source: lib.appending(path: "external"), copy: pack.externalDir).isEmpty)
        #expect(try RendererStore.verbatimMismatches(source: lib.appending(path: "wine"), copy: pack.wineDir).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: pack.externalDir.appending(path: "D3DMetal.framework/Versions/Current").path) == "A")

        #expect(staged.record.packID == "d3dmetal-3.0")
        #expect(!staged.record.isAccepted)
        #expect(staged.record.source == dmg)
        #expect(staged.record.signatures.count == 2 + Self.unixNames.count)
        #expect(staged.record.signatures.prefix(2).map(\.path) == ["external/libd3dshared.dylib", "external/D3DMetal.framework"])
        #expect(staged.record.signatures.allSatisfy { $0.verified && $0.anchorApple == true })
        let link = try #require(staged.record.signatures.first { $0.path == "wine/x86_64-unix/d3d11.so" })
        #expect(link.identifier == "com.apple.libd3dshared", "a link carries libd3dshared's signature")
        #expect(lines.lines.contains { $0.contains("copying external/ and wine/ verbatim") })
        #expect(lines.lines.contains { $0.contains("x86_64-unix/{d3d10.so,d3d11.so,d3d12.so,d3d9.so,dxgi.so,nvngx-on-metalfx.so} → ../../external/libd3dshared.dylib") })
    }

    @Test("a toolkit that is not Apple-signed is refused, and so is a broken one")
    func stageRefusesNonApple() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = try Self.toolkit(at: home.appending(path: "dmg"))
        let dmg = ImportedArtifact(fileName: "x.dmg", sha256: String(repeating: "cd", count: 32))
        let developerID: RendererStore.SignatureInspector = { _, path in
            SignedFile(path: path, identifier: "com.example.d3d", authorities: ["Developer ID Application: X (ABCDE12345)", "Developer ID Certification Authority", "Apple Root CA"],
                       verified: true, anchorApple: false)
        }
        await #expect(throws: OssoverError.self) {
            try await RendererStore.stageGPTK(redistLib: lib, into: home.appending(path: "s1"), id: "d3dmetal-x", version: "x", dmg: dmg, inspect: developerID)
        }
        let unverified: RendererStore.SignatureInspector = { _, path in SignedFile(path: path, verified: false, anchorApple: false) }
        await #expect(throws: OssoverError.self) {
            try await RendererStore.stageGPTK(redistLib: lib, into: home.appending(path: "s2"), id: "d3dmetal-x", version: "x", dmg: dmg, inspect: unverified)
        }
        try FileManager.default.removeItem(at: lib.appending(path: "external/libd3dshared.dylib"))
        await #expect(throws: OssoverError.self) {
            try await RendererStore.stageGPTK(redistLib: lib, into: home.appending(path: "s3"), id: "d3dmetal-x", version: "x", dmg: dmg,
                                              inspect: { file, path in Self.appleSigned(file, path) })
        }
    }

    @Test("links are recreated exactly and a non-verbatim copy is detected")
    func linksAndVerbatim() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = try Self.toolkit(at: home.appending(path: "dmg"))
        let wine = lib.appending(path: "wine", directoryHint: .isDirectory)

        // A copy whose links were dereferenced (or point elsewhere) is repaired to the toolkit's links.
        let copy = home.appending(path: "copy", directoryHint: .isDirectory)
        try touch(copy.appending(path: "x86_64-unix/d3d11.so"), machOStub)
        try FileManager.default.createDirectory(at: copy.appending(path: "x86_64-unix"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: copy.appending(path: "x86_64-unix/dxgi.so").path, withDestinationPath: "elsewhere.dylib")
        let ensured = try RendererStore.recreateUnixLinks(from: wine, to: copy)
        #expect(ensured.count == 6)
        #expect(Set(ensured.values) == [RendererStore.gptkUnixLinkTarget])
        for name in Self.unixNames {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appending(path: "x86_64-unix/\(name)").path) == RendererStore.gptkUnixLinkTarget)
        }
        #expect(try RendererStore.recreateUnixLinks(from: copy, to: home.appending(path: "none")).count == 6, "an idempotent second pass")
        #expect(try RendererStore.recreateUnixLinks(from: home.appending(path: "nowhere"), to: copy).isEmpty)

        // Verbatim: the same tree passes; a changed byte, a changed link and a missing file are named.
        let twin = home.appending(path: "twin", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: wine, to: twin)
        #expect(try RendererStore.verbatimMismatches(source: wine, copy: twin).isEmpty)
        try touch(twin.appending(path: "x86_64-windows/d3d11.dll"), Data("MZ!".utf8))
        try FileManager.default.removeItem(at: twin.appending(path: "x86_64-unix/dxgi.so"))
        try FileManager.default.createSymbolicLink(atPath: twin.appending(path: "x86_64-unix/dxgi.so").path, withDestinationPath: "../../external/other.dylib")
        try FileManager.default.removeItem(at: twin.appending(path: "x86_64-windows/dxgi.dll"))
        #expect(try RendererStore.verbatimMismatches(source: wine, copy: twin) == ["x86_64-unix/dxgi.so", "x86_64-windows/d3d11.dll", "x86_64-windows/dxgi.dll"])
    }
}

@Suite struct RendererStoreLayoutTests {
    @Test("a Unix half beside the 64-bit PEs is split out and the layout read from disk")
    func separateAndRead() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let wine = home.appending(path: "wine", directoryHint: .isDirectory)
        try touch(wine.appending(path: "x86_64-windows/d3d11.dll"))
        try touch(wine.appending(path: "x86_64-windows/winemetal.so"), Data("so".utf8))
        #expect(RendererStore.layout(ofWineDir: wine) == RendererLayout(unix: [], pe: ["d3d11.dll"], pe32: nil))
        #expect(try RendererStore.separateUnixHalf(in: wine) == ["winemetal.so"])
        #expect(RendererStore.layout(ofWineDir: wine) == RendererLayout(unix: ["winemetal.so"], pe: ["d3d11.dll"], pe32: nil))
        #expect(try RendererStore.separateUnixHalf(in: wine).isEmpty, "nothing left to move")
        try touch(wine.appending(path: "i386-windows/d3d11.dll"))
        #expect(RendererStore.layout(ofWineDir: wine).pe32 == ["d3d11.dll"])
        #expect(RendererStore.layout(ofWineDir: home.appending(path: "nowhere")) == RendererLayout())
        try touch(wine.appending(path: "x86_64-windows/winemetal.so"), Data("again".utf8))
        #expect(throws: OssoverError.self) { try RendererStore.separateUnixHalf(in: wine) }
    }
}

@Suite struct BottleEngineStampStoreTests {
    @Test("bottle create stamps the installed engine (decision 25, REA L-42)")
    func createStamps() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let manifest = Fixtures.manifest(id: "e", capabilities: Fixtures.crossOver)
        let root = paths.engine("e")
        try manifest.save(to: root.appending(path: Engine.manifestFileName))
        try touch(root.appending(path: manifest.paths.wine), Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: manifest.paths.wine).path)
        let store = BottleStore(paths: paths)
        let bottle = try store.create(name: "b", engineID: "e")
        let stamp = try #require(bottle.engineStamp)
        #expect(stamp.engineID == "e")
        #expect(stamp.version == manifest.version)
        #expect(try store.load("b").engineStamp == stamp)
        #expect(try store.create(name: "c", engineID: "e", requireEngine: false).engineStamp == nil)
    }
}
