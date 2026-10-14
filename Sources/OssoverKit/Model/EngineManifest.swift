// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Manifest.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// The CPU architecture of an engine's Unix side. v1 is x86_64 under Rosetta; arm64 (+FEX) is v3.
public enum EngineArch: String, Codable, CaseIterable, Sendable {
    case x86_64
    case arm64

    /// Directory under `lib/wine` holding the Unix halves of Wine's builtins (`ntdll.so`, `winemac.so`).
    public var unixLibDir: String { self == .arm64 ? "aarch64-unix" : "x86_64-unix" }
    /// Directory under `lib/wine` holding the 64-bit PE builtins.
    public var pe64LibDir: String { self == .arm64 ? "aarch64-windows" : "x86_64-windows" }
    /// The 32-bit PE builtins, the same on both (32-bit programs run through WoW64).
    public static let pe32LibDir = "i386-windows"
}

/// Where the engine's binaries sit, relative to the engine directory.
public struct EnginePaths: Codable, Equatable, Sendable {
    public var wine: String
    public var wineserver: String
    /// The `lib/wine` directory (holds `x86_64-unix`, `x86_64-windows`, `i386-windows`).
    public var libWine: String
    /// Optional directory of bundled dylibs/frameworks (GStreamer, MoltenVK). Informational only:
    /// no `DYLD_*` row is ever derived from it — CrossOver sets none, hardened-runtime loaders
    /// ignore them, and the tree resolves through its own `.so` rpaths (REA L-12, L-54; decision 1).
    public var frameworks: String?

    public init(wine: String = "wine/bin/wine", wineserver: String = "wine/bin/wineserver",
                libWine: String = "wine/lib/wine", frameworks: String? = nil) {
        self.wine = wine
        self.wineserver = wineserver
        self.libWine = libWine
        self.frameworks = frameworks
    }

    public func validate() throws {
        for (name, value) in [("wine", wine), ("wineserver", wineserver), ("libWine", libWine), ("frameworks", frameworks ?? "")]
        where !value.isEmpty {
            guard !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else {
                throw OssoverError.invalid("paths.\(name) must be relative to the engine directory without '..': '\(value)'")
            }
        }
        guard !wine.isEmpty, !wineserver.isEmpty, !libWine.isEmpty else {
            throw OssoverError.invalid("paths.wine, paths.wineserver and paths.libWine are required")
        }
    }
}

/// What an engine build can do. Recipes and the renderer materializer check these instead of
/// probing binaries at launch; the engine packager verifies them once (plan §5 gates).
public struct EngineCapabilities: Codable, Equatable, Sendable {
    /// Mach-semaphore sync (`WINEMSYNC`); only CrossOver-derived trees have it.
    public var msync: Bool
    /// eventfd-style sync (`WINEESYNC`).
    public var esync: Bool
    /// WoW64 (32-bit PE on a 64-bit Unix side; no i386-unix).
    public var wow64: Bool
    /// `winemac.so` exports `macdrv_functions`, which DXMT's `winemetal.so` and D3DMetal need.
    public var macdrvExports: Bool
    /// ntdll honours `WINEDLLPATH_PREPEND` (highball patch 0003) → renderer overlay strategy C.
    public var dllPathPrepend: Bool
    /// The tree carries CrossOver's D3DMetal glue (`CX_APPLEGPTK_LIBD3DSHARED_PATH` loader hook).
    public var d3dmetalHost: Bool

    public init(msync: Bool = false, esync: Bool = false, wow64: Bool = false, macdrvExports: Bool = false,
                dllPathPrepend: Bool = false, d3dmetalHost: Bool = false) {
        self.msync = msync
        self.esync = esync
        self.wow64 = wow64
        self.macdrvExports = macdrvExports
        self.dllPathPrepend = dllPathPrepend
        self.d3dmetalHost = d3dmetalHost
    }

    enum CodingKeys: String, CodingKey { case msync, esync, wow64, macdrvExports, dllPathPrepend, d3dmetalHost }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? false
        esync = try c.decodeIfPresent(Bool.self, forKey: .esync) ?? false
        wow64 = try c.decodeIfPresent(Bool.self, forKey: .wow64) ?? false
        macdrvExports = try c.decodeIfPresent(Bool.self, forKey: .macdrvExports) ?? false
        dllPathPrepend = try c.decodeIfPresent(Bool.self, forKey: .dllPathPrepend) ?? false
        d3dmetalHost = try c.decodeIfPresent(Bool.self, forKey: .d3dmetalHost) ?? false
    }

    /// The capability names a recipe's `requires.capabilities` may use.
    public static let names: [String] = CodingKeys.allCases.map(\.rawValue)

    /// Whether the named capability is on; nil for a name this build does not know.
    public func has(_ name: String) -> Bool? {
        switch name {
        case "msync": return msync
        case "esync": return esync
        case "wow64": return wow64
        case "macdrvExports": return macdrvExports
        case "dllPathPrepend": return dllPathPrepend
        case "d3dmetalHost": return d3dmetalHost
        default: return nil
        }
    }

    /// Names of the capabilities that are on, in declaration order.
    public var enabled: [String] { Self.names.filter { has($0) == true } }

    /// Of `wanted`, the names this engine lacks (unknown names count as lacking).
    public func unmet(_ wanted: [String]) -> [String] { wanted.filter { has($0) != true } }
}

extension EngineCapabilities.CodingKeys: CaseIterable {}

/// Add-on versions under `share/wine` (`mono/wine-mono-<v>`, `gecko/wine-gecko-<v>-x86{,_64}`),
/// as `engine/package.sh` records them in `addons`. Informational: `gates.sh addons` checks the
/// pins against `dlls/appwiz.cpl/addons.c` (REA L-49), nothing at run time reads them.
public struct EngineAddons: Codable, Equatable, Sendable {
    public var wineMono: String?
    public var wineGecko: String?

    public init(wineMono: String? = nil, wineGecko: String? = nil) {
        self.wineMono = wineMono
        self.wineGecko = wineGecko
    }

    enum CodingKeys: String, CodingKey { case wineMono, wineGecko }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wineMono = try c.decodeIfPresent(String.self, forKey: .wineMono)
        wineGecko = try c.decodeIfPresent(String.self, forKey: .wineGecko)
    }
}

/// A renderer that ships inside the engine tarball (the bootstrap engine carries DXMT 0.80 at
/// `DXMT/`). `path` is relative to the engine directory and holds a renderer-pack-shaped tree
/// or, when `layout` is given, the listed files directly under it. `EngineStore.install` moves a
/// bare bundle to `overlays/<kind>/` and records `layout` and `builtinMarked` from the files
/// (REA L-23, L-65); keys `engine/package.sh` adds beside these (`id`, `requires`) are ignored.
public struct BundledRenderer: Codable, Equatable, Sendable {
    public var kind: RendererKind
    public var version: String?
    public var path: String
    public var layout: RendererLayout?
    /// Whether the PE DLLs carry Wine's "builtin" DOS-stub mark (DXMT's release asset does).
    public var builtinMarked: Bool?

    public init(kind: RendererKind, version: String? = nil, path: String, layout: RendererLayout? = nil, builtinMarked: Bool? = nil) {
        self.kind = kind
        self.version = version
        self.path = path
        self.layout = layout
        self.builtinMarked = builtinMarked
    }
}

/// `engines/<id>.json` in the repo and `engines/<id>/manifest.json` once installed. Plan §4.
public struct EngineManifest: Codable, Equatable, Sendable, Identifiable, SchemaDocument {
    public static let currentSchema = "ossover.engine-manifest/1"

    public var schema: String
    /// Stable identifier and directory name, e.g. `x64-frankea-wine11.16-cx26.3-v4.6.4b1`.
    public var id: String
    public var displayName: String
    /// The engine's own release/revision ("v4.6.4-beta.1", "r1").
    public var version: String
    /// The Wine release inside ("11.16").
    public var wineVersion: String
    /// The fork string `ntdll.so` carries (`wine-11.16` on the bootstrap engine; a CrossOver
    /// 26.3 build says `wine-11.0-8726-g2e2f5fca349`, REA L-45). `EngineStore.install` records
    /// it from `strings` without running Wine; `engine/package.sh` from `wine --version`.
    public var wineVersionString: String?
    public var arch: EngineArch
    /// Lowest macOS this engine was built for ("15.0").
    public var minMacOS: String
    /// Host prerequisites by name; "rosetta2" is the one v1 knows.
    public var requires: [String]
    public var source: ArtifactSource
    public var paths: EnginePaths
    /// Environment every launch on this engine starts from; `${engine}` expands to the engine
    /// directory. Merged below bottle env and program env (plan §4 env table).
    public var baseEnv: [String: String]
    public var capabilities: EngineCapabilities
    public var bundledRenderers: [BundledRenderer]
    /// wine-mono / wine-gecko versions bundled under `share/wine`, when the packager says.
    public var addons: EngineAddons?
    public var notes: [String]

    public init(id: String, displayName: String, version: String, wineVersion: String, arch: EngineArch = .x86_64,
                minMacOS: String = "15.0", requires: [String] = ["rosetta2"], source: ArtifactSource,
                paths: EnginePaths = EnginePaths(), baseEnv: [String: String] = [:],
                capabilities: EngineCapabilities = EngineCapabilities(), bundledRenderers: [BundledRenderer] = [],
                notes: [String] = [], wineVersionString: String? = nil, addons: EngineAddons? = nil) {
        self.schema = Self.currentSchema
        self.id = id
        self.displayName = displayName
        self.version = version
        self.wineVersion = wineVersion
        self.wineVersionString = wineVersionString
        self.arch = arch
        self.minMacOS = minMacOS
        self.requires = requires
        self.source = source
        self.paths = paths
        self.baseEnv = baseEnv
        self.capabilities = capabilities
        self.bundledRenderers = bundledRenderers
        self.addons = addons
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, displayName, version, wineVersion, wineVersionString, arch, minMacOS, requires, source, paths, baseEnv,
             capabilities, bundledRenderers, addons, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        wineVersion = try c.decode(String.self, forKey: .wineVersion)
        wineVersionString = try c.decodeIfPresent(String.self, forKey: .wineVersionString)
        arch = try c.decodeIfPresent(EngineArch.self, forKey: .arch) ?? .x86_64
        minMacOS = try c.decodeIfPresent(String.self, forKey: .minMacOS) ?? "15.0"
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        source = try c.decode(ArtifactSource.self, forKey: .source)
        paths = try c.decodeIfPresent(EnginePaths.self, forKey: .paths) ?? EnginePaths()
        baseEnv = try c.decodeIfPresent([String: String].self, forKey: .baseEnv) ?? [:]
        capabilities = try c.decodeIfPresent(EngineCapabilities.self, forKey: .capabilities) ?? EngineCapabilities()
        bundledRenderers = try c.decodeIfPresent([BundledRenderer].self, forKey: .bundledRenderers) ?? []
        addons = try c.decodeIfPresent(EngineAddons.self, forKey: .addons)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    // MARK: Derived

    public var requiresRosetta: Bool { requires.contains("rosetta2") }

    /// Whether this engine is meant for the given macOS (numeric compare of `minMacOS`).
    public func runs(onMacOS version: Version) -> Bool {
        guard let floor = Version(minMacOS) else { return true }
        return version >= floor
    }

    public var wineVersionParsed: Version? { Version(wineVersion) }

    /// Renderer kinds shipped inside the engine tarball.
    public var bundledRendererKinds: Set<RendererKind> { Set(bundledRenderers.map(\.kind)) }

    public func bundledRenderer(_ kind: RendererKind) -> BundledRenderer? {
        bundledRenderers.first { $0.kind == kind }
    }

    /// Identifiers are directory names: letters, digits, `.`, `_`, `-`, not starting with a dot.
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("."), id.count <= 128 else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    public func validate() throws {
        try validateSchema()
        guard Self.isValidID(id) else { throw OssoverError.invalid("engine id '\(id)' is not a valid directory name") }
        guard Version(wineVersion) != nil else { throw OssoverError.invalid("engine \(id): wineVersion '\(wineVersion)' is not a version") }
        guard Version(minMacOS) != nil else { throw OssoverError.invalid("engine \(id): minMacOS '\(minMacOS)' is not a version") }
        try source.validate()
        try paths.validate()
        for r in bundledRenderers {
            guard !r.path.hasPrefix("/"), !r.path.split(separator: "/").contains("..") else {
                throw OssoverError.invalid("engine \(id): bundled renderer \(r.kind.rawValue) path must be relative: '\(r.path)'")
            }
        }
        for key in baseEnv.keys where key.isEmpty || key.contains("=") {
            throw OssoverError.invalid("engine \(id): baseEnv has an invalid variable name '\(key)'")
        }
    }

    // MARK: Files

    public static func load(from url: URL) throws -> EngineManifest {
        let manifest = try JSONDocument.load(EngineManifest.self, from: url)
        try manifest.validate()
        return manifest
    }

    public func save(to url: URL) throws {
        try JSONDocument.save(self, to: url)
    }
}
