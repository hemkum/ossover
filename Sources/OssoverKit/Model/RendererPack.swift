// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The Direct3D implementations ossover knows how to place in front of Wine's own.
public enum RendererKind: String, Codable, CaseIterable, Sendable {
    /// D3D10/11 → Metal (3Shain/dxmt). The default for Witcher 3.
    case dxmt
    /// D3D9/10/11 → Vulkan → MoltenVK (Gcenx/DXVK-macOS, capped at 1.10.3). Optional.
    case dxvk
    /// Apple's D3D11/12 → Metal from the Game Porting Toolkit; user-imported, never downloaded.
    case d3dmetal
    /// Wine's own D3D over OpenGL. Always available; slowest.
    case wined3d

    public var displayName: String {
        switch self {
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .d3dmetal: return "D3DMetal"
        case .wined3d: return "WineD3D"
        }
    }

    /// wined3d needs no pack: it is the engine's own.
    public var needsPack: Bool { self != .wined3d }
    /// D3DMetal is behind Apple's licence; the pack exists only after `renderer accept`.
    public var needsLicence: Bool { self == .d3dmetal }
}

/// Files a pack places, relative to the pack's `x86_64-unix`, `x86_64-windows` and optional
/// `i386-windows` directories (`RendererPack.wineDir`: the bare root of an engine overlay or
/// `<pack>/wine` of an installed pack). REA L-23, L-65.
public struct RendererLayout: Codable, Equatable, Sendable {
    public var unix: [String]
    public var pe: [String]
    /// Optional: DXMT 0.80's release asset carries an `i386-windows/` half
    /// (`{d3d10core,d3d11,dxgi,winemetal}.dll`, the `tar tzf` recorded in `renderers/dxmt-0.80.json`;
    /// REA L-65, U-13 closed); a pack without one leaves this nil.
    public var pe32: [String]?

    public init(unix: [String] = [], pe: [String] = [], pe32: [String]? = nil) {
        self.unix = unix
        self.pe = pe
        self.pe32 = pe32
    }

    enum CodingKeys: String, CodingKey { case unix, pe, pe32 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unix = try c.decodeIfPresent([String].self, forKey: .unix) ?? []
        pe = try c.decodeIfPresent([String].self, forKey: .pe) ?? []
        pe32 = try c.decodeIfPresent([String].self, forKey: .pe32)
    }

    /// Every file name, as "<subdir>/<name>" relative to `<pack>/wine`.
    public var relativePaths: [String] {
        unix.map { "x86_64-unix/\($0)" } + pe.map { "x86_64-windows/\($0)" } + (pe32 ?? []).map { "i386-windows/\($0)" }
    }
}

/// What the engine must offer for the pack to work.
public struct RendererRequires: Codable, Equatable, Sendable {
    /// Lowest Wine release ("10.18" for DXMT 0.80's `winemetal.so` ABI).
    public var wineMin: String?
    /// Needs `winemac.so` to export `macdrv_functions` (DXMT, D3DMetal). The right ABI gate:
    /// DXMT's `winemetal.so` does `dlsym(RTLD_DEFAULT, "macdrv_functions")` and reads slots of
    /// that 24-entry table, binding nothing else from `winemac.so`. REA L-60, L-61.
    public var macdrvExports: Bool

    public init(wineMin: String? = nil, macdrvExports: Bool = false) {
        self.wineMin = wineMin
        self.macdrvExports = macdrvExports
    }

    enum CodingKeys: String, CodingKey { case wineMin, macdrvExports }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wineMin = try c.decodeIfPresent(String.self, forKey: .wineMin)
        macdrvExports = try c.decodeIfPresent(Bool.self, forKey: .macdrvExports) ?? false
    }

    /// Reasons `engine` cannot host this pack; empty when it can.
    public func unmet(by engine: EngineManifest) -> [String] {
        var reasons: [String] = []
        if let wineMin, let floor = Version(wineMin), let have = engine.wineVersionParsed, have < floor {
            reasons.append("needs Wine \(wineMin) or later, engine has \(engine.wineVersion)")
        }
        if macdrvExports, !engine.capabilities.macdrvExports {
            reasons.append("needs winemac.so to export macdrv_functions, which engine \(engine.id) lacks")
        }
        return reasons
    }
}

/// `renderers/<id>.json` in the repo, `renderers/<id>/manifest.json` once installed. Two
/// on-disk shapes (REA L-23, L-65): an installed pack keeps plan §4's nested
/// `renderers/<id>/wine/{x86_64-unix/*.so,x86_64-windows/*.dll,i386-windows/*.dll}` (+ `external/`
/// for D3DMetal), while an engine overlay is bare, CrossOver's `lib/<backend>/` shape, with
/// `{x86_64-unix,x86_64-windows,i386-windows}` directly under `overlays/<kind>/`.
public struct RendererPackManifest: Codable, Equatable, Sendable, Identifiable, SchemaDocument {
    public static let currentSchema = "ossover.renderer-pack/1"

    public var schema: String
    /// Directory name, e.g. `dxmt-0.80`.
    public var id: String
    public var kind: RendererKind
    public var version: String
    /// Absent for a user-imported pack (D3DMetal from the GPTK dmg).
    public var source: ArtifactSource?
    /// Whether the PE DLLs carry the 17-byte "Wine builtin DLL" DOS-stub mark at offset `0x40`
    /// (`PEBuiltinMark`; REA L-25). Strategy B must strip it before copying into a prefix's
    /// system32 (a marked file there only redirects to the engine's own builtin); strategy C
    /// wants it kept.
    public var builtinMarked: Bool
    public var requires: RendererRequires
    public var layout: RendererLayout
    /// `WINEDLLOVERRIDES` fragments this pack needs, e.g. `"dxgi,d3d11,d3d10core=n,b"`.
    public var overrides: [String]
    public var notes: [String]

    public init(id: String, kind: RendererKind, version: String, source: ArtifactSource? = nil, builtinMarked: Bool = false,
                requires: RendererRequires = RendererRequires(), layout: RendererLayout = RendererLayout(),
                overrides: [String] = [], notes: [String] = []) {
        self.schema = Self.currentSchema
        self.id = id
        self.kind = kind
        self.version = version
        self.source = source
        self.builtinMarked = builtinMarked
        self.requires = requires
        self.layout = layout
        self.overrides = overrides
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case schema, id, kind, version, source, builtinMarked, requires, layout, overrides, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(RendererKind.self, forKey: .kind)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        source = try c.decodeIfPresent(ArtifactSource.self, forKey: .source)
        builtinMarked = try c.decodeIfPresent(Bool.self, forKey: .builtinMarked) ?? false
        requires = try c.decodeIfPresent(RendererRequires.self, forKey: .requires) ?? RendererRequires()
        layout = try c.decodeIfPresent(RendererLayout.self, forKey: .layout) ?? RendererLayout()
        overrides = try c.decodeIfPresent([String].self, forKey: .overrides) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public func validate() throws {
        try validateSchema()
        guard EngineManifest.isValidID(id) else { throw OssoverError.invalid("renderer id '\(id)' is not a valid directory name") }
        try source?.validate()
        if let wineMin = requires.wineMin, Version(wineMin) == nil {
            throw OssoverError.invalid("renderer \(id): requires.wineMin '\(wineMin)' is not a version")
        }
        for name in layout.unix + layout.pe + (layout.pe32 ?? []) where name.contains("/") || name.isEmpty {
            throw OssoverError.invalid("renderer \(id): layout entries are bare file names, got '\(name)'")
        }
    }

    /// Reasons `engine` cannot host this pack; empty when it can.
    public func unmet(by engine: EngineManifest) -> [String] { requires.unmet(by: engine) }

    public static func load(from url: URL) throws -> RendererPackManifest {
        let manifest = try JSONDocument.load(RendererPackManifest.self, from: url)
        try manifest.validate()
        return manifest
    }

    public func save(to url: URL) throws { try JSONDocument.save(self, to: url) }
}

/// An installed renderer pack resolved against its directory.
public struct RendererPack: Sendable, Equatable, Identifiable {
    public static let manifestFileName = "manifest.json"

    public let root: URL
    public let manifest: RendererPackManifest

    public init(root: URL, manifest: RendererPackManifest) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
    }

    public var id: String { manifest.id }
    public var kind: RendererKind { manifest.kind }

    public var manifestURL: URL { root.appending(path: Self.manifestFileName) }
    /// The directory holding `x86_64-unix/` and `x86_64-windows/` — what `WINEDLLPATH`
    /// (strategy B) or `WINEDLLPATH_PREPEND` (C) points at: the pack root itself when it is
    /// bare in CrossOver's shape (`<root>/x86_64-windows` exists; an engine's `overlays/<kind>`),
    /// else `<root>/wine` (an installed pack, extracted with `into: wine`). REA L-23, L-65.
    public var wineDir: URL {
        if FileManager.default.fileExists(atPath: root.appending(path: EngineArch.x86_64.pe64LibDir).path) { return root }
        return root.appending(path: "wine", directoryHint: .isDirectory)
    }
    public var unixDir: URL { wineDir.appending(path: "x86_64-unix", directoryHint: .isDirectory) }
    public var peDir: URL { wineDir.appending(path: "x86_64-windows", directoryHint: .isDirectory) }
    public var pe32Dir: URL { wineDir.appending(path: "i386-windows", directoryHint: .isDirectory) }
    /// `<pack>/external` — D3DMetal.framework and libd3dshared.dylib for a d3dmetal pack.
    public var externalDir: URL { root.appending(path: "external", directoryHint: .isDirectory) }

    // MARK: D3DMetal (Game Porting Toolkit) layout

    /// The Rosetta/D3DMetal bridge `CX_APPLEGPTK_LIBD3DSHARED_PATH` names, under `external/`.
    public static let gptkSharedLibraryName = "libd3dshared.dylib"
    /// Where every `x86_64-unix/*.so` of a GPTK pack points: the same `libd3dshared.dylib`,
    /// reached relative to `wine/x86_64-unix/`.
    public static let gptkUnixLinkTarget = "../../external/libd3dshared.dylib"

    /// `<pack>/external/libd3dshared.dylib`.
    public var gptkSharedLibrary: URL { externalDir.appending(path: Self.gptkSharedLibraryName) }

    /// The layout a D3DMetal pack must keep, verbatim from the GPTK dmg's `redist/lib` (REA
    /// L-55, L-75; decision 14): `external/{libd3dshared.dylib, D3DMetal.framework}` beside
    /// `wine/x86_64-{unix,windows}`, where each `x86_64-unix/<name>.so` is a symbolic link to
    /// `../../external/libd3dshared.dylib` (six of them in GPTK 3: d3d9, d3d10, d3d11, d3d12,
    /// dxgi and the DLSS shim). Wine pairs `wine/x86_64-windows/<name>.dll` with that `.so`
    /// from the prepended directory, `libd3dshared` finds `D3DMetal.framework` through its own
    /// `LC_RPATH @loader_path` (so `external/` must stay next to `wine/`), and the Apple
    /// signatures must stay intact — never re-signed, stripped or install-name-rewritten.
    /// `RendererStore.importGPTK` produces this shape; this returns what deviates from it for a
    /// d3dmetal pack (an entry of `layout.unix` that is not a link, or links elsewhere), empty
    /// for other kinds and for a conforming pack. Missing files are `missingFiles`' business.
    public func gptkLinkIssues() -> [String] {
        guard kind == .d3dmetal else { return [] }
        let fm = FileManager.default
        let expected = gptkSharedLibrary.standardizedFileURL.path
        return manifest.layout.unix.compactMap { name -> String? in
            let link = unixDir.appending(path: name)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
                return fm.fileExists(atPath: link.path)
                    ? "x86_64-unix/\(name) is a file, not a link to \(Self.gptkUnixLinkTarget)" : nil
            }
            let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : link.deletingLastPathComponent().appending(path: target)
            return resolved.standardizedFileURL.path == expected ? nil
                : "x86_64-unix/\(name) links to \(target), not \(Self.gptkUnixLinkTarget)"
        }
    }

    /// Every file the layout says must exist.
    public var expectedFiles: [URL] { manifest.layout.relativePaths.map { wineDir.appending(path: $0) } }

    public static func load(root: URL) throws -> RendererPack {
        let url = root.appending(path: manifestFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OssoverError.missing("renderer manifest \(url.path)")
        }
        return RendererPack(root: root, manifest: try RendererPackManifest.load(from: url))
    }

    /// Files the layout lists that are not on disk.
    public var missingFiles: [URL] { expectedFiles.filter { !FileManager.default.fileExists(atPath: $0.path) } }

    public func validateLayout() throws {
        let missing = missingFiles
        guard missing.isEmpty else {
            throw OssoverError.missing("renderer \(id): " + missing.map { $0.path }.joined(separator: ", "))
        }
    }
}
