// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Bottle.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// What `ossover steam fetch` recorded, so a re-fetch is refused unless `--allow-update` (Steam
/// would otherwise move Witcher 3 4.04 to the DX12-only 5.x Remastered).
public struct SteamState: Codable, Equatable, Sendable {
    public var appID: Int
    public var branch: String?
    /// `buildid` from `appmanifest_<app>.acf`.
    public var buildID: String?
    /// `betakey` from the ACF (the branch Steam actually served).
    public var betaKey: String?
    /// Windows path of the install directory passed as `force_install_dir`.
    public var installDir: String?
    public var fetchedAt: Date?
    /// Steam account name used; never a password.
    public var account: String?

    public init(appID: Int, branch: String? = nil, buildID: String? = nil, betaKey: String? = nil,
                installDir: String? = nil, fetchedAt: Date? = nil, account: String? = nil) {
        self.appID = appID
        self.branch = branch
        self.buildID = buildID
        self.betaKey = betaKey
        self.installDir = installDir
        self.fetchedAt = fetchedAt?.secondPrecision
        self.account = account
    }

    enum CodingKeys: String, CodingKey {
        case appID = "appId"
        case branch
        case buildID = "buildId"
        case betaKey, installDir, fetchedAt, account
    }
}

/// Which engine (id + manifest `version`) last ran the prefix-init steps (`wineboot -u`,
/// `winecfg -v`, the registry batch). `BottleStore.create` writes it and every
/// `Prefix.initialize` refreshes it; before a launch `BottleStore.ensureInitialized` compares it
/// with the bottle's engine and re-runs the idempotent init steps when it differs — the open
/// equivalent of CrossOver's `[CrossOver] BuildTimestamp` ≠ `[Bottle] Timestamp` trigger
/// (REA L-42; decision 25).
public struct EngineStamp: Codable, Equatable, Sendable {
    public var engineID: String
    /// `EngineManifest.version` (the engine's own release, not the Wine version).
    public var version: String
    public var stampedAt: Date

    public init(engineID: String, version: String, stampedAt: Date = Date()) {
        self.engineID = engineID
        self.version = version
        self.stampedAt = stampedAt.secondPrecision
    }

    public init(engine: Engine, stampedAt: Date = Date()) {
        self.init(engineID: engine.id, version: engine.manifest.version, stampedAt: stampedAt)
    }

    /// True when `engine` is the one this stamp records (id and version; the date is history).
    public func matches(_ engine: Engine) -> Bool {
        engineID == engine.id && version == engine.manifest.version
    }

    public var summary: String { version.isEmpty ? engineID : "\(engineID) \(version)" }

    enum CodingKeys: String, CodingKey {
        case engineID = "engineId"
        case version, stampedAt
    }
}

/// `bottles/<name>/bottle.json`.
public struct Bottle: Codable, Equatable, Sendable, SchemaDocument {
    public static let currentSchema = "ossover.bottle/1"
    public static let fileName = "bottle.json"

    public var schema: String
    public var name: String
    public var created: Date
    public var engineID: String
    public var settings: BottleSettings
    public var programs: [Program]
    /// Recipe ids applied, in order.
    public var recipesApplied: [String]
    /// What each recipe run recorded ({id, version, at}); `RecipeEngine.apply` appends here.
    public var recipeHistory: [RecipeApplied]
    public var steam: SteamState?
    /// The engine that last initialised the prefix; nil until the first init (or on a
    /// `bottle.json` written before stamps existed, which `ensureInitialized` treats as stale).
    public var engineStamp: EngineStamp?

    public init(name: String, engineID: String, settings: BottleSettings = BottleSettings(), created: Date = Date(),
                programs: [Program] = [], recipesApplied: [String] = [], recipeHistory: [RecipeApplied] = [],
                steam: SteamState? = nil, engineStamp: EngineStamp? = nil) {
        self.schema = Self.currentSchema
        self.name = name
        self.created = created.secondPrecision
        self.engineID = engineID
        self.settings = settings
        self.programs = programs
        self.recipesApplied = recipesApplied
        self.recipeHistory = recipeHistory
        self.steam = steam
        self.engineStamp = engineStamp
    }

    enum CodingKeys: String, CodingKey {
        case schema, name, created
        case engineID = "engineId"
        case settings, programs, recipesApplied, recipeHistory, steam, engineStamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        name = try c.decode(String.self, forKey: .name)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        engineID = try c.decode(String.self, forKey: .engineID)
        settings = try c.decodeIfPresent(BottleSettings.self, forKey: .settings) ?? BottleSettings()
        programs = try c.decodeIfPresent([Program].self, forKey: .programs) ?? []
        recipesApplied = try c.decodeIfPresent([String].self, forKey: .recipesApplied) ?? []
        recipeHistory = try c.decodeIfPresent([RecipeApplied].self, forKey: .recipeHistory) ?? []
        steam = try c.decodeIfPresent(SteamState.self, forKey: .steam)
        engineStamp = try c.decodeIfPresent(EngineStamp.self, forKey: .engineStamp)
    }

    public func program(id: String) -> Program? { programs.first { $0.id == id } }

    /// Adds or replaces a program by id.
    public mutating func upsert(_ program: Program) {
        if let i = programs.firstIndex(where: { $0.id == program.id }) { programs[i] = program } else { programs.append(program) }
    }

    /// Bottle names are directory names: no slashes, no leading dot, printable ASCII.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("."), name != "..",
              name == name.trimmingCharacters(in: .whitespaces) else { return false }
        return name.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "/" && $0 != ":" && $0 != "\\" && !($0.asciiValue.map { $0 < 32 } ?? true) }
    }

    public func validate() throws {
        try validateSchema()
        guard Self.isValidName(name) else { throw OssoverError.invalid("bottle name '\(name)' is not a valid directory name") }
        guard EngineManifest.isValidID(engineID) else { throw OssoverError.invalid("bottle \(name): engineId '\(engineID)' is not valid") }
        if let stamp = engineStamp, !EngineManifest.isValidID(stamp.engineID) {
            throw OssoverError.invalid("bottle \(name): engineStamp.engineId '\(stamp.engineID)' is not valid")
        }
        try settings.validate()
        var seen = Set<String>()
        for p in programs {
            try p.validate()
            guard seen.insert(p.id).inserted else { throw OssoverError.invalid("bottle \(name): duplicate program id '\(p.id)'") }
        }
    }

    public static func load(from url: URL) throws -> Bottle {
        let bottle = try JSONDocument.load(Bottle.self, from: url)
        try bottle.validate()
        return bottle
    }

    /// Writes the document. The engine stamp belongs to the init path, not to whoever holds a
    /// copy of the bottle: a copy loaded before `BottleStore.ensureInitialized` re-stamped the
    /// file (a recipe run, a Steam fetch, a settings edit) must not roll the stamp back, so with
    /// `preservingStamp` (the default) a stamp already on disk is kept unless `self` carries a
    /// strictly newer one (`withStampPreserved`). The init path passes `false`: it is the writer
    /// the stamp belongs to.
    public func save(to url: URL, preservingStamp: Bool = true) throws {
        try JSONDocument.save(preservingStamp ? withStampPreserved(from: url) : self, to: url)
    }

    /// `self` with the stamp found in the document at `url` unless `self`'s own is strictly
    /// newer; `self` unchanged when there is no readable document or it carries no stamp. Equal
    /// `stampedAt` (second precision) goes to the disk: a copy loaded in the same second as a
    /// re-init is the stale one.
    public func withStampPreserved(from url: URL) -> Bottle {
        guard let existing = try? JSONDocument.load(Bottle.self, from: url), let onDisk = existing.engineStamp else { return self }
        if let mine = engineStamp, mine.stampedAt > onDisk.stampedAt { return self }
        var copy = self
        copy.engineStamp = onDisk
        return copy
    }
}

/// Directories of one bottle: `bottles/<name>/{bottle.json, prefix/, logs/, steamcmd/, .renderer-state.json}`.
public struct BottleLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var name: String { root.lastPathComponent }
    public var bottleJSON: URL { root.appending(path: Bottle.fileName) }
    /// `WINEPREFIX`.
    public var prefix: URL { root.appending(path: "prefix", directoryHint: .isDirectory) }
    public var driveC: URL { prefix.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var steamcmd: URL { root.appending(path: "steamcmd", directoryHint: .isDirectory) }
    /// Files the renderer materializer placed in the prefix (strategy B), so they can be removed.
    public var rendererState: URL { root.appending(path: ".renderer-state.json") }
    public var systemReg: URL { prefix.appending(path: "system.reg") }
    public var userReg: URL { prefix.appending(path: "user.reg") }
    public var system32: URL { driveC.appending(path: "windows/system32", directoryHint: .isDirectory) }
    public var syswow64: URL { driveC.appending(path: "windows/syswow64", directoryHint: .isDirectory) }
    public func userDirectory(_ userName: String) -> URL { driveC.appending(path: "users/\(userName)", directoryHint: .isDirectory) }

    public var exists: Bool { FileManager.default.fileExists(atPath: bottleJSON.path) }
    public var prefixInitialised: Bool { FileManager.default.fileExists(atPath: systemReg.path) }

    /// Creates `root`, `prefix/`, `logs/`, `steamcmd/`.
    public func ensureDirectories() throws {
        for dir in [root, prefix, logs, steamcmd] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw OssoverError.io("cannot create \(dir.path): \(error.localizedDescription)")
            }
        }
    }

    /// `logs/<timestamp>-<program>.log`.
    public func logFile(program: String, at date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = Program.slug(program)
        return logs.appending(path: "\(formatter.string(from: date))-\(safe).log")
    }
}
