// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Recipe.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// Registry value types `wine reg add -t` accepts.
public enum RegistryValueType: String, Codable, CaseIterable, Sendable {
    case string = "REG_SZ"
    case expandString = "REG_EXPAND_SZ"
    case multiString = "REG_MULTI_SZ"
    case dword = "REG_DWORD"
    case qword = "REG_QWORD"
    case binary = "REG_BINARY"
}

/// Where an `env` recipe step lands.
public enum EnvScope: String, Codable, CaseIterable, Sendable {
    /// `bottle.json` → `settings.env`: every launch in the bottle.
    case bottle
    /// The `env` of the program(s) the same recipe adds.
    case program
}

// MARK: - when

/// The host a recipe is planned for: what a step's `when.platform` and `when.locale` are
/// matched against. The platform is always `mac` (ossover runs nowhere else); the locale is
/// the user's, in CrossTie's `ll_CC` spelling (`ja_JP`).
public struct RecipeHost: Sendable, Equatable {
    public static let mac = "mac"

    public var platform: String
    public var locale: String

    public init(platform: String = RecipeHost.mac, locale: String) {
        self.platform = platform
        self.locale = locale
    }

    /// This Mac and `Locale.current`.
    public static var current: RecipeHost {
        RecipeHost(locale: normalisedLocale(Locale.current.identifier))
    }

    /// `en_US@rg=gbzzzz` → `en_US`, `en-US` → `en_US`, `C.UTF-8` → `C`.
    public static func normalisedLocale(_ identifier: String) -> String {
        var out = identifier
        if let at = out.firstIndex(of: "@") { out = String(out[..<at]) }
        if let dot = out.firstIndex(of: ".") { out = String(out[..<dot]) }
        return out.replacingOccurrences(of: "-", with: "_")
    }
}

/// A step's `when` clause: CrossTie's `useif platform|locale` (REA L-67) plus the
/// engine-capability predicate decision 36 needs (`WINE_WAIT_CHILD_PIPE_IGNORE` only on
/// CX-derived engines). Every given field must hold, else the step is skipped and the plan says
/// why. `platform` is `mac`; `locale` matches the host locale exactly (`ja_JP`) or by language
/// (`ja` matches `ja_JP`); `engineCapabilities` is all-of over `EngineCapabilities.names`.
public struct RecipeCondition: Codable, Equatable, Sendable {
    public static let knownPlatforms = [RecipeHost.mac]

    public var platform: String?
    public var locale: String?
    public var engineCapabilities: [String]

    public init(platform: String? = nil, locale: String? = nil, engineCapabilities: [String] = []) {
        self.platform = platform
        self.locale = locale
        self.engineCapabilities = engineCapabilities
    }

    enum CodingKeys: String, CodingKey { case platform, locale, engineCapabilities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        engineCapabilities = try c.decodeIfPresent([String].self, forKey: .engineCapabilities) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(locale, forKey: .locale)
        if !engineCapabilities.isEmpty { try c.encode(engineCapabilities, forKey: .engineCapabilities) }
    }

    public var isEmpty: Bool { platform == nil && locale == nil && engineCapabilities.isEmpty }

    /// Whether `wanted` (`ja` or `ja_JP`) matches the host locale (`ja_JP`): equal, or the host
    /// is a region of the wanted language. Case and `-`/`_` are ignored.
    public static func localeMatches(_ wanted: String, host: String) -> Bool {
        let want = RecipeHost.normalisedLocale(wanted).lowercased()
        let have = RecipeHost.normalisedLocale(host).lowercased()
        return have == want || have.hasPrefix(want + "_")
    }

    /// Reasons the clause does not hold on `host` with `capabilities`; empty when it does.
    public func unmet(host: RecipeHost, capabilities: EngineCapabilities) -> [String] {
        var reasons: [String] = []
        if let platform, platform != host.platform { reasons.append("platform is \(host.platform), not \(platform)") }
        if let locale, !Self.localeMatches(locale, host: host.locale) { reasons.append("locale is \(host.locale), not \(locale)") }
        reasons += capabilities.unmet(engineCapabilities).map { "engine lacks capability \($0)" }
        return reasons
    }

    public func holds(host: RecipeHost, capabilities: EngineCapabilities) -> Bool {
        unmet(host: host, capabilities: capabilities).isEmpty
    }

    /// `when platform=mac, locale=ja, engineCapabilities=msync`.
    public var summary: String {
        var parts: [String] = []
        if let platform { parts.append("platform=\(platform)") }
        if let locale { parts.append("locale=\(locale)") }
        if !engineCapabilities.isEmpty { parts.append("engineCapabilities=" + engineCapabilities.joined(separator: "+")) }
        return "when " + parts.joined(separator: ", ")
    }

    /// Throws for an empty clause, a platform or a capability name this build does not know.
    public func validate() throws {
        guard !isEmpty else { throw OssoverError.invalid("when clause is empty") }
        if let platform, !Self.knownPlatforms.contains(platform) {
            throw OssoverError.invalid("when clause: unknown platform '\(platform)' (known: \(Self.knownPlatforms.joined(separator: ", ")))")
        }
        if let locale, locale.isEmpty { throw OssoverError.invalid("when clause: locale is empty") }
        for name in engineCapabilities where !EngineCapabilities.names.contains(name) {
            throw OssoverError.invalid("when clause: unknown capability '\(name)' (known: \(EngineCapabilities.names.joined(separator: ", ")))")
        }
    }
}

// MARK: - status / reports

/// A recipe's verdict on ossover, the open counterpart of a CrossTie medal (L-67): `works` ≈
/// gold, `partial` ≈ silver/bronze, `broken` ≈ knownnottowork, `untested` until someone ran it.
public enum RecipeStatus: String, Codable, CaseIterable, Sendable {
    case untested, works, partial, broken
}

/// One observation behind a recipe's `status` (a medal entry's rating/version/date): what ran,
/// where, and what was seen.
public struct CompatibilityReport: Codable, Equatable, Sendable {
    public var status: RecipeStatus
    /// `YYYY-MM-DD`.
    public var date: String
    /// Engine id the report was made on.
    public var engine: String?
    public var renderer: RendererKind?
    /// macOS version ("26.0").
    public var macOS: String?
    /// "M5 Pro 48 GB".
    public var hardware: String?
    public var note: String?

    public init(status: RecipeStatus, date: String, engine: String? = nil, renderer: RendererKind? = nil,
                macOS: String? = nil, hardware: String? = nil, note: String? = nil) {
        self.status = status
        self.date = date
        self.engine = engine
        self.renderer = renderer
        self.macOS = macOS
        self.hardware = hardware
        self.note = note
    }

    /// `YYYY-MM-DD`: ten ASCII characters, digits around two dashes.
    public static func isValidDate(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 {
                guard scalar == "-" else { return false }
            } else {
                guard scalar.value >= 48, scalar.value <= 57 else { return false }
            }
        }
        return true
    }

    public func validate() throws {
        guard Self.isValidDate(date) else { throw OssoverError.invalid("report date '\(date)' is not YYYY-MM-DD") }
    }
}

// MARK: - Steps

/// One step of a recipe. On disk each is an object with a `type` discriminator and the case's
/// fields beside it (`{"type": "winver", "value": "win10"}`); an optional `when` object beside
/// them decodes to `.conditional(when:step:)` around the step.
///
/// The `registry` step's value type is stored under `valueType`, because `type` is the
/// discriminator.
public indirect enum RecipeStep: Equatable, Sendable {
    /// `winecfg -v <value>`.
    case winver(WindowsVersion)
    /// Bottle sync mode.
    case sync(SyncMode)
    /// Bottle renderer.
    case renderer(RendererChoice)
    /// `RetinaMode` and, when given, `LogPixels`.
    case retina(value: Bool, dpi: Int?)
    /// `wine reg add <key> /v <name> /t <type> /d <data> /f`.
    case registry(key: String, name: String, type: RegistryValueType, data: String)
    /// A `WINEDLLOVERRIDES` fragment the bottle keeps ("amd_ags_x64=").
    case dlloverride(value: String)
    /// A persistent environment variable.
    case env(name: String, value: String, scope: EnvScope)
    /// winetricks verbs, unattended. `optional` steps may fail without failing the recipe.
    case winetricks(verbs: [String], optional: Bool, note: String?)
    /// Write a text file at a Windows path (variables expanded). `ifMissing` keeps an existing file.
    case file(path: String, contents: String, ifMissing: Bool)
    /// Set `key=value` in `[section]` of an INI file at a Windows path; nil section = wherever the key already is, else the first section.
    case ini(path: String, section: String?, key: String, value: String)
    /// Copy a file; `from` may be `${engine}`-relative or a Windows path, `to` is a Windows path.
    case copy(from: String, to: String)
    /// Add (or replace by id) a program on the bottle.
    case program(Program)
    /// Free text shown after the recipe ran.
    case note(text: String)
    /// `step` only where `when` holds (platform, locale, engine capabilities); the plan skips it
    /// otherwise and says why. Never nested.
    case conditional(when: RecipeCondition, step: RecipeStep)

    /// The step itself, out of its `when` wrapper.
    public var base: RecipeStep {
        if case let .conditional(_, step) = self { return step }
        return self
    }

    /// The `when` clause, nil for an unconditional step.
    public var condition: RecipeCondition? {
        if case let .conditional(when, _) = self { return when }
        return nil
    }

    /// The `type` discriminator (of the wrapped step for a conditional one).
    public var typeName: String {
        switch self {
        case .winver: return "winver"
        case .sync: return "sync"
        case .renderer: return "renderer"
        case .retina: return "retina"
        case .registry: return "registry"
        case .dlloverride: return "dlloverride"
        case .env: return "env"
        case .winetricks: return "winetricks"
        case .file: return "file"
        case .ini: return "ini"
        case .copy: return "copy"
        case .program: return "program"
        case .note: return "note"
        case let .conditional(_, step): return step.typeName
        }
    }

    /// True for steps that spawn a Wine process (and so need the prefix's wineserver to agree
    /// on the sync mode) or can take a long time.
    public var touchesWine: Bool {
        switch self {
        case .winver, .registry, .retina, .winetricks: return true
        case .sync, .renderer, .dlloverride, .env, .file, .ini, .copy, .program, .note: return false
        case let .conditional(_, step): return step.touchesWine
        }
    }

    /// One line for a dry-run plan.
    public var summary: String {
        switch self {
        case let .winver(v): return "winver \(v.rawValue)"
        case let .sync(m): return "sync \(m.rawValue)"
        case let .renderer(r): return "renderer \(r.rawValue)"
        case let .retina(value, dpi): return "retina \(value ? "on" : "off")" + (dpi.map { " dpi \($0)" } ?? "")
        case let .registry(key, name, type, data): return "registry \(key)\\\(name) = (\(type.rawValue)) \(data)"
        case let .dlloverride(value): return "dlloverride \(value)"
        case let .env(name, value, scope): return "env \(name)=\(value) (\(scope.rawValue))"
        case let .winetricks(verbs, optional, _): return "winetricks \(verbs.joined(separator: " "))" + (optional ? " (optional)" : "")
        case let .file(path, _, ifMissing): return "file \(path)" + (ifMissing ? " (if missing)" : "")
        case let .ini(path, section, key, value): return "ini \(path) [\(section ?? "*")] \(key)=\(value)"
        case let .copy(from, to): return "copy \(from) → \(to)"
        case let .program(p): return "program \(p.id): \(p.exe)"
        case let .note(text): return "note: \(text)"
        case let .conditional(when, step): return "\(step.summary) [\(when.summary)]"
        }
    }
}

extension RecipeStep: Codable {
    enum CodingKeys: String, CodingKey {
        case type, value, dpi, key, name, valueType, data, scope, verbs, optional, note, path, contents, ifMissing,
             section, from, to, text, when
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let step = try Self.decodePlain(from: decoder, container: c)
        if let when = try c.decodeIfPresent(RecipeCondition.self, forKey: .when) {
            self = .conditional(when: when, step: step)
        } else {
            self = step
        }
    }

    /// The step without its `when` wrapper.
    static func decodePlain(from decoder: Decoder, container c: KeyedDecodingContainer<CodingKeys>) throws -> RecipeStep {
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "winver":
            return .winver(try c.decode(WindowsVersion.self, forKey: .value))
        case "sync":
            return .sync(try c.decode(SyncMode.self, forKey: .value))
        case "renderer":
            return .renderer(try c.decode(RendererChoice.self, forKey: .value))
        case "retina":
            return .retina(value: try c.decodeIfPresent(Bool.self, forKey: .value) ?? true,
                           dpi: try c.decodeIfPresent(Int.self, forKey: .dpi))
        case "registry":
            return .registry(key: try c.decode(String.self, forKey: .key),
                             name: try c.decode(String.self, forKey: .name),
                             type: try c.decodeIfPresent(RegistryValueType.self, forKey: .valueType) ?? .string,
                             data: try c.decode(String.self, forKey: .data))
        case "dlloverride":
            return .dlloverride(value: try c.decode(String.self, forKey: .value))
        case "env":
            return .env(name: try c.decode(String.self, forKey: .name),
                        value: try c.decode(String.self, forKey: .value),
                        scope: try c.decodeIfPresent(EnvScope.self, forKey: .scope) ?? .bottle)
        case "winetricks":
            return .winetricks(verbs: try c.decode([String].self, forKey: .verbs),
                               optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false,
                               note: try c.decodeIfPresent(String.self, forKey: .note))
        case "file":
            return .file(path: try c.decode(String.self, forKey: .path),
                         contents: try c.decode(String.self, forKey: .contents),
                         ifMissing: try c.decodeIfPresent(Bool.self, forKey: .ifMissing) ?? false)
        case "ini":
            return .ini(path: try c.decode(String.self, forKey: .path),
                        section: try c.decodeIfPresent(String.self, forKey: .section),
                        key: try c.decode(String.self, forKey: .key),
                        value: try c.decode(String.self, forKey: .value))
        case "copy":
            return .copy(from: try c.decode(String.self, forKey: .from), to: try c.decode(String.self, forKey: .to))
        case "program":
            // The program's own keys sit beside `type` (and `when`); none of them is either.
            return .program(try Program(from: decoder))
        case "note":
            return .note(text: try c.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown recipe step type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case let .conditional(when, step) = self {
            // Same keyed storage: the step's keys first, `when` beside them.
            try step.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(when, forKey: .when)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case let .winver(v): try c.encode(v, forKey: .value)
        case let .sync(m): try c.encode(m, forKey: .value)
        case let .renderer(r): try c.encode(r, forKey: .value)
        case let .retina(value, dpi):
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(dpi, forKey: .dpi)
        case let .registry(key, name, type, data):
            try c.encode(key, forKey: .key)
            try c.encode(name, forKey: .name)
            try c.encode(type, forKey: .valueType)
            try c.encode(data, forKey: .data)
        case let .dlloverride(value): try c.encode(value, forKey: .value)
        case let .env(name, value, scope):
            try c.encode(name, forKey: .name)
            try c.encode(value, forKey: .value)
            try c.encode(scope, forKey: .scope)
        case let .winetricks(verbs, optional, note):
            try c.encode(verbs, forKey: .verbs)
            try c.encode(optional, forKey: .optional)
            try c.encodeIfPresent(note, forKey: .note)
        case let .file(path, contents, ifMissing):
            try c.encode(path, forKey: .path)
            try c.encode(contents, forKey: .contents)
            try c.encode(ifMissing, forKey: .ifMissing)
        case let .ini(path, section, key, value):
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(section, forKey: .section)
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        case let .copy(from, to):
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case let .program(p):
            // Same encoder, same keyed storage: the program's keys land beside `type`.
            try p.encode(to: encoder)
        case let .note(text): try c.encode(text, forKey: .text)
        case .conditional: break   // handled above
        }
    }
}

/// What a recipe needs from the engine and the installed renderers.
public struct RecipeRequires: Codable, Equatable, Sendable {
    /// Names from `EngineCapabilities.names` ("msync", "macdrvExports").
    public var capabilities: [String]
    /// Renderer kinds that must be installed (or bundled with the engine).
    public var renderers: [RendererKind]

    public init(capabilities: [String] = [], renderers: [RendererKind] = []) {
        self.capabilities = capabilities
        self.renderers = renderers
    }

    enum CodingKeys: String, CodingKey { case capabilities, renderers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        renderers = try c.decodeIfPresent([RendererKind].self, forKey: .renderers) ?? []
    }

    /// Reasons the recipe cannot run on `engine` with `installedRenderers`; empty when it can.
    public func unmet(engine: EngineManifest, installedRenderers: Set<RendererKind>) -> [String] {
        var reasons = engine.capabilities.unmet(capabilities).map { "engine \(engine.id) lacks capability \($0)" }
        let available = installedRenderers.union(engine.bundledRendererKinds).union([.wined3d])
        reasons += renderers.filter { !available.contains($0) }.map { "renderer \($0.displayName) is not installed" }
        return reasons
    }
}

public struct KnownIssue: Codable, Equatable, Sendable {
    public var symptom: String
    public var cause: String?
    public var fix: String?

    public init(symptom: String, cause: String? = nil, fix: String? = nil) {
        self.symptom = symptom
        self.cause = cause
        self.fix = fix
    }
}

/// `recipes/<id>.json` (CC0): declarative steps that make one game or launcher work in a bottle.
public struct Recipe: Codable, Equatable, Sendable, Identifiable, SchemaDocument {
    public static let currentSchema = "ossover.recipe/1"

    public var schema: String
    /// e.g. `witcher3-4.04-dx11`.
    public var id: String
    public var title: String
    public var description: String?
    /// SPDX id of the recipe text itself; repo recipes are CC0-1.0.
    public var license: String?
    public var requires: RecipeRequires
    /// Windows path of the game directory, what `${gameDir}` expands to in steps.
    public var gameDir: String?
    public var steps: [RecipeStep]
    public var knownIssues: [KnownIssue]
    /// The maintainer's verdict, summarising `reports`; nil means nobody said (L-67).
    public var status: RecipeStatus?
    /// The observations behind `status`, newest last.
    public var reports: [CompatibilityReport]

    public init(id: String, title: String, description: String? = nil, license: String? = "CC0-1.0",
                requires: RecipeRequires = RecipeRequires(), gameDir: String? = nil, steps: [RecipeStep] = [],
                knownIssues: [KnownIssue] = [], status: RecipeStatus? = nil, reports: [CompatibilityReport] = []) {
        self.schema = Self.currentSchema
        self.id = id
        self.title = title
        self.description = description
        self.license = license
        self.requires = requires
        self.gameDir = gameDir
        self.steps = steps
        self.knownIssues = knownIssues
        self.status = status
        self.reports = reports
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, title, description, license, requires, gameDir, steps, knownIssues, status, reports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        requires = try c.decodeIfPresent(RecipeRequires.self, forKey: .requires) ?? RecipeRequires()
        gameDir = try c.decodeIfPresent(String.self, forKey: .gameDir)
        steps = try c.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        knownIssues = try c.decodeIfPresent([KnownIssue].self, forKey: .knownIssues) ?? []
        status = try c.decodeIfPresent(RecipeStatus.self, forKey: .status)
        reports = try c.decodeIfPresent([CompatibilityReport].self, forKey: .reports) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(license, forKey: .license)
        try c.encode(requires, forKey: .requires)
        try c.encodeIfPresent(gameDir, forKey: .gameDir)
        try c.encode(steps, forKey: .steps)
        try c.encode(knownIssues, forKey: .knownIssues)
        try c.encodeIfPresent(status, forKey: .status)
        if !reports.isEmpty { try c.encode(reports, forKey: .reports) }
    }

    /// Programs the recipe adds, in order (conditional ones included).
    public var programs: [Program] {
        steps.compactMap { if case let .program(p) = $0.base { return p } else { return nil } }
    }

    /// True when any step spawns Wine or takes long (so the caller stops the bottle first).
    public var touchesWine: Bool { steps.contains(where: \.touchesWine) }

    /// True when applying changes what a launch inherits (renderer, sync, env, overrides).
    public var changesLaunchEnvironment: Bool {
        steps.contains { step in
            switch step.base {
            case .renderer, .sync, .env, .dlloverride: return true
            default: return false
            }
        }
    }

    /// Variable names that resolve under the prefix's Windows user directory.
    public static let userProfileVariables = ["%USERPROFILE%", "%APPDATA%", "%LOCALAPPDATA%", "%TEMP%", "%TMP%"]

    /// Whether any `file`/`ini`/`copy` step writes under the Windows user directory
    /// (`%USERPROFILE%`, `%APPDATA%`, …), whose name only a booted prefix knows for sure.
    public var usesUserProfile: Bool {
        steps.contains { step in
            let paths: [String]
            switch step.base {
            case let .file(path, _, _), let .ini(path, _, _, _): paths = [path]
            case let .copy(from, to): paths = [from, to]
            default: return false
            }
            return paths.contains { path in Self.userProfileVariables.contains { path.uppercased().contains($0) } }
        }
    }

    /// Whether any step uses `${gameDir}`.
    public var usesGameDir: Bool {
        steps.contains { step in
            switch step.base {
            case let .file(path, _, _), let .ini(path, _, _, _): return path.contains("${gameDir}")
            case let .copy(from, to): return from.contains("${gameDir}") || to.contains("${gameDir}")
            case let .program(p): return p.exe.contains("${gameDir}") || (p.workingDir?.contains("${gameDir}") ?? false)
            default: return false
            }
        }
    }

    public func validate() throws {
        try validateSchema()
        guard EngineManifest.isValidID(id) else { throw OssoverError.invalid("recipe id '\(id)' is not valid") }
        for name in requires.capabilities where !EngineCapabilities.names.contains(name) {
            throw OssoverError.invalid("recipe \(id): unknown capability '\(name)' (known: \(EngineCapabilities.names.joined(separator: ", ")))")
        }
        if usesGameDir, gameDir == nil {
            throw OssoverError.invalid("recipe \(id): a step uses ${gameDir} but the recipe has no gameDir")
        }
        for (index, step) in steps.enumerated() {
            try validate(step, index: index)
        }
        for (index, report) in reports.enumerated() {
            do { try report.validate() } catch let error as OssoverError {
                throw OssoverError.invalid("recipe \(id) report \(index): \(error.errorDescription ?? "\(error)")")
            }
        }
    }

    func validate(_ step: RecipeStep, index: Int) throws {
        switch step {
        case let .conditional(when, inner):
            if case .conditional = inner {
                throw OssoverError.invalid("recipe \(id) step \(index): nested when clauses")
            }
            do { try when.validate() } catch let error as OssoverError {
                throw OssoverError.invalid("recipe \(id) step \(index): \(error.errorDescription ?? "\(error)")")
            }
            try validate(inner, index: index)
        case let .program(p):
            do { try p.validate() } catch let error as OssoverError {
                throw OssoverError.invalid("recipe \(id) step \(index): \(error.errorDescription ?? "\(error)")")
            }
        case let .env(name, _, _) where name.isEmpty || name.contains("="):
            throw OssoverError.invalid("recipe \(id) step \(index): invalid env name '\(name)'")
        case let .winetricks(verbs, _, _) where verbs.isEmpty:
            throw OssoverError.invalid("recipe \(id) step \(index): winetricks without verbs")
        case let .retina(_, dpi?) where !BottleSettings.dpiRange.contains(dpi):
            throw OssoverError.invalid("recipe \(id) step \(index): dpi \(dpi) is outside \(BottleSettings.dpiRange)")
        case let .dlloverride(value) where !value.contains("="):
            throw OssoverError.invalid("recipe \(id) step \(index): dlloverride '\(value)' is not '<dll>=<order>'")
        default:
            break
        }
    }

    public static func load(from url: URL) throws -> Recipe {
        let recipe = try JSONDocument.load(Recipe.self, from: url)
        try recipe.validate()
        return recipe
    }

    public func save(to url: URL) throws { try JSONDocument.save(self, to: url) }
}
