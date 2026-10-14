// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// Paths and pure fixtures shared by the suites. Nothing here touches the network or Wine; the
/// `/ossover-test` home never exists on disk (the pure tests only need its paths), and I/O tests
/// use `temporaryDirectory()`.
enum Fixtures {
    /// `Tests/Fixtures`, found from this file.
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    /// The repository checkout (`engines/`, `renderers/`, `recipes/`).
    static let repoRoot: URL = directory.deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ relative: String) -> URL { directory.appending(path: relative) }

    static func text(_ relative: String) throws -> String { try String(contentsOf: url(relative), encoding: .utf8) }

    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }

    static let home = URL(fileURLWithPath: "/ossover-test", isDirectory: true)
    static var paths: OssoverPaths { OssoverPaths(home: home) }

    // MARK: Engines

    /// A CrossOver-derived tree without `WINEDLLPATH_PREPEND` (the bootstrap engine's shape).
    static let crossOver = EngineCapabilities(msync: true, esync: false, wow64: true, macdrvExports: true,
                                              dllPathPrepend: false, d3dmetalHost: true)
    /// The plan's own engine (patch 0003): overlay strategy C.
    static let crossOverPrepend = EngineCapabilities(msync: true, esync: false, wow64: true, macdrvExports: true,
                                                     dllPathPrepend: true, d3dmetalHost: true)
    /// A vanilla upstream build with esync.
    static let vanillaEsync = EngineCapabilities(msync: false, esync: true, wow64: true)
    /// A vanilla build whose winemac.so exports `macdrv_functions` (DXMT fits, msync does not).
    static let vanillaEsyncMacdrv = EngineCapabilities(msync: false, esync: true, wow64: true, macdrvExports: true)

    static func manifest(id: String = "test-engine", capabilities: EngineCapabilities, baseEnv: [String: String] = [:],
                         frameworks: String? = nil, requires: [String] = ["rosetta2"]) -> EngineManifest {
        EngineManifest(id: id, displayName: "Test engine", version: "r1", wineVersion: "11.16", arch: .x86_64, minMacOS: "15.0",
                       requires: requires,
                       source: ArtifactSource(url: URL(fileURLWithPath: "/ossover-test/downloads/test-engine.tar.xz"), sha256: "TBD"),
                       paths: EnginePaths(frameworks: frameworks), baseEnv: baseEnv, capabilities: capabilities)
    }

    static func engine(id: String = "test-engine", capabilities: EngineCapabilities, baseEnv: [String: String] = [:],
                       frameworks: String? = nil, requires: [String] = ["rosetta2"]) -> Engine {
        Engine(root: paths.engine(id), manifest: manifest(id: id, capabilities: capabilities, baseEnv: baseEnv,
                                                           frameworks: frameworks, requires: requires))
    }

    // MARK: Renderer packs (under `/ossover-test/renderers/<id>`)

    static func pack(id: String, kind: RendererKind, version: String, overrides: [String],
                     requires: RendererRequires = RendererRequires(), builtinMarked: Bool = true,
                     layout: RendererLayout? = nil) -> RendererPack {
        let manifest = RendererPackManifest(id: id, kind: kind, version: version, builtinMarked: builtinMarked, requires: requires,
                                            layout: layout ?? RendererResolver.defaultLayout(kind), overrides: overrides)
        return RendererPack(root: paths.renderer(id), manifest: manifest)
    }

    static let dxmtPack = pack(id: "dxmt-0.80", kind: .dxmt, version: "0.80", overrides: ["dxgi,d3d11,d3d10core=n,b"],
                               requires: RendererRequires(wineMin: "10.18", macdrvExports: true))
    static let dxvkPack = pack(id: "dxvk-macos-1.10.3", kind: .dxvk, version: "1.10.3", overrides: ["d3d9,d3d10core,d3d11,dxgi=n,b"])
    static let d3dmetalPack = pack(id: "d3dmetal-3.0", kind: .d3dmetal, version: "3.0", overrides: ["d3d10,d3d11,d3d12,dxgi=n,b"],
                                   requires: RendererRequires(macdrvExports: true), builtinMarked: false)

    // MARK: Disk

    /// A fresh directory under the system temporary directory.
    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "ossover-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
