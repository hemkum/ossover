// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Recipe.swift (RecipeRunner.apply) (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette

import Foundation

/// The Wine-side operations a recipe needs (`winecfg -v`, `reg add`, winetricks). The Wine
/// stage's `WinVersion`, `Registry` and `Winetricks` are adapted onto this by the CLI; tests
/// pass a recorder. Keeping the engine behind a protocol also keeps `plan()` free of I/O.
public protocol RecipeWineOperations: Sendable {
    /// `winecfg -v <version>` (and whatever registry keys that implies).
    func setWindowsVersion(_ version: WindowsVersion) async throws
    /// `wine reg add <key> /v <name> /t <type> /d <data> /f`.
    func registryAdd(key: String, name: String, type: RegistryValueType, data: String) async throws
    /// `winetricks --unattended <verbs>`.
    func winetricks(verbs: [String]) async throws
}

/// One fully resolved thing `apply` does. Windows paths are already Unix URLs, `${gameDir}` and
/// `%USERPROFILE%` are expanded, so an action can be printed as a dry run and executed without
/// looking at the recipe again.
public enum RecipeAction: Equatable, Sendable {
    /// `settings.windowsVersion` + `winecfg -v`.
    case setWindowsVersion(WindowsVersion)
    /// `settings.sync` only; the launcher materialises it.
    case setSync(SyncMode)
    /// `settings.renderer` only; the launcher materialises the overlay.
    case setRenderer(RendererChoice)
    /// `settings.retina`/`settings.dpi` + `RetinaMode`/`LogPixels` registry values.
    case setRetina(enabled: Bool, dpi: Int?)
    case addRegistry(key: String, name: String, type: RegistryValueType, data: String)
    /// Appended to `settings.dllOverrides` when not already there.
    case addDLLOverride(String)
    /// `settings.env[name] = value`.
    case setBottleEnv(name: String, value: String)
    /// `optional` failures are reported, not thrown.
    case winetricks(verbs: [String], optional: Bool, note: String?)
    /// Write `contents` at a Unix path inside the prefix; `ifMissing` keeps an existing file.
    case writeFile(url: URL, contents: String, ifMissing: Bool)
    /// `IniFile.set` on the file at `url` (created when missing).
    case setIni(url: URL, section: String?, key: String, value: String)
    /// Copy one file (parent directories created, an existing target replaced).
    case copyFile(from: URL, to: URL)
    /// Add or replace (by id) a program on the bottle; `${gameDir}` already expanded.
    case upsertProgram(Program)
    /// Collected into the report.
    case note(String)
    /// A step whose `when` clause does not hold here (`step` is its summary); reported under
    /// `RecipeReport.skipped`, nothing runs.
    case skipped(step: String, reason: String)

    /// True for actions that run a Wine process and so need `RecipeWineOperations`.
    public var needsWine: Bool {
        switch self {
        case .setWindowsVersion, .setRetina, .addRegistry, .winetricks: return true
        default: return false
        }
    }

    /// One line for a dry run.
    public var summary: String {
        switch self {
        case let .setWindowsVersion(v): return "set Windows version \(v.rawValue)"
        case let .setSync(m): return "set sync \(m.rawValue)"
        case let .setRenderer(r): return "set renderer \(r.rawValue)"
        case let .setRetina(enabled, dpi): return "set retina \(enabled ? "on" : "off")" + (dpi.map { ", dpi \($0)" } ?? "")
        case let .addRegistry(key, name, type, data): return "reg add \(key)\\\(name) (\(type.rawValue)) = \(data)"
        case let .addDLLOverride(v): return "dll override \(v)"
        case let .setBottleEnv(name, value): return "bottle env \(name)=\(value)"
        case let .winetricks(verbs, optional, _): return "winetricks \(verbs.joined(separator: " "))" + (optional ? " (optional)" : "")
        case let .writeFile(url, _, ifMissing): return "write \(url.path)" + (ifMissing ? " (if missing)" : "")
        case let .setIni(url, section, key, value): return "ini \(url.path) [\(section ?? "*")] \(key)=\(value)"
        case let .copyFile(from, to): return "copy \(from.path) → \(to.path)"
        case let .upsertProgram(p): return "program \(p.id): \(p.exe)" + (p.args.isEmpty ? "" : " " + p.args.joined(separator: " "))
        case let .note(text): return "note: \(text)"
        case let .skipped(step, reason): return "skip \(step): \(reason)"
        }
    }
}

/// What a bottle remembers about one recipe run (`bottle.json` → `recipeHistory`).
public struct RecipeApplied: Codable, Equatable, Sendable {
    public var id: String
    /// Recipes carry no version field (the id names the game version, `witcher3-4.04-dx11`),
    /// so this is a content fingerprint, `sha256:<12 hex>` of the canonical JSON, enough to see
    /// that the recipe file changed since it was applied.
    public var version: String
    public var at: Date

    public init(id: String, version: String, at: Date = Date()) {
        self.id = id
        self.version = version
        self.at = at.secondPrecision
    }
}

/// The outcome of `RecipeEngine.apply`.
public struct RecipeReport: Equatable, Sendable {
    public var applied: RecipeApplied
    /// Summaries of the actions that ran, in order.
    public var performed: [String]
    /// Optional steps that failed, and steps whose `when` clause did not hold, with the reason.
    public var skipped: [String]
    /// `note` steps, for the CLI to print after the run.
    public var notes: [String]
    /// The bottle as saved.
    public var bottle: Bottle

    public init(applied: RecipeApplied, performed: [String] = [], skipped: [String] = [], notes: [String] = [], bottle: Bottle) {
        self.applied = applied
        self.performed = performed
        self.skipped = skipped
        self.notes = notes
        self.bottle = bottle
    }

    /// Whether the run changed `settings.sync` from `previous` (the bottle as the run started).
    /// One `WINEMSYNC` per wineserver lifetime (decision 19, REA L-30, L-31): a server started
    /// under the old mode must be stopped (`wineserver -k` → `-w`) before the next launch, or
    /// that launch is refused. A `sync` step runs no Wine process itself (`RecipeAction.needsWine`
    /// is false for `.setSync`), so `recipe apply` checks this independently of whether Wine ran.
    public func changedSync(from previous: Bottle) -> Bool {
        bottle.settings.sync != previous.settings.sync
    }
}

/// Turns a recipe into actions (pure) and runs them against a bottle.
///
/// Step semantics: `winver` → `settings.windowsVersion` + Wine; `sync`/`renderer` → settings
/// only (materialised at launch); `retina` → settings + `RetinaMode`/`LogPixels`; `registry` →
/// `reg add`; `dlloverride` → `settings.dllOverrides`; `env` → bottle env or the env of the
/// programs the recipe adds; `winetricks` → winetricks (optional ones log and continue);
/// `file`/`ini`/`copy` → filesystem inside the prefix; `program` → `bottle.programs` by id;
/// `note` → the report; a step with a `when` clause that does not hold on this host/engine →
/// `skipped` in the plan and the report. The run is recorded in `bottle.recipesApplied` (id)
/// and `bottle.recipeHistory` ({id, version, at}).
public enum RecipeEngine {
    public static let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#
    public static let desktopKey = #"HKCU\Control Panel\Desktop"#
    public static let retinaValueName = "RetinaMode"
    public static let logPixelsValueName = "LogPixels"

    // MARK: Plan

    /// Resolves every step against the bottle's prefix, the engine and the host. No I/O: the
    /// prefix need not exist, and the caller passes the renderer packs it found
    /// (`paths.installedRendererIDs()`). A step whose `when` clause does not hold on `host` with
    /// the engine's capabilities becomes a `skipped` action with the reasons. Throws `.invalid`
    /// for a recipe that does not validate or a path that cannot be resolved, `.unsupported`
    /// when the engine lacks what the recipe requires.
    public static func plan(_ recipe: Recipe, bottle: Bottle, engine: Engine, paths: OssoverPaths,
                            installedRenderers: Set<RendererKind> = [], userName: String = NSUserName(),
                            host: RecipeHost = .current) throws -> [RecipeAction] {
        try recipe.validate()
        let unmet = recipe.requires.unmet(engine: engine.manifest, installedRenderers: installedRenderers)
        guard unmet.isEmpty else {
            throw OssoverError.unsupported("recipe \(recipe.id) cannot run: " + unmet.joined(separator: "; "))
        }
        let layout = paths.bottleLayout(bottle.name)
        let variables = WindowsPath.standardVariables(userName: userName, gameDir: recipe.gameDir, engineRoot: engine.root)
        let gameDirVariables = recipe.gameDir.map { ["gameDir": WindowsPath.normalize($0)] } ?? [:]

        // Every `when` evaluated once, so the program-scoped env and the actions agree.
        let evaluated: [(step: RecipeStep, skipped: String?)] = recipe.steps.map { raw in
            guard let condition = raw.condition else { return (raw, nil) }
            let reasons = condition.unmet(host: host, capabilities: engine.capabilities)
            return (raw.base, reasons.isEmpty ? nil : reasons.joined(separator: "; "))
        }

        // Program-scoped env rides the programs the recipe adds, whatever the step order.
        var programEnv: [String: String] = [:]
        for entry in evaluated where entry.skipped == nil {
            if case let .env(name, value, .program) = entry.step { programEnv[name] = value }
        }

        var actions: [RecipeAction] = []
        for (index, entry) in evaluated.enumerated() {
            let step = entry.step
            if let reason = entry.skipped {
                actions.append(.skipped(step: step.summary, reason: reason))
                continue
            }
            let where_ = "recipe \(recipe.id) step \(index) (\(step.typeName))"
            switch step {
            case let .winver(v):
                actions.append(.setWindowsVersion(v))
            case let .sync(m):
                actions.append(.setSync(m))
            case let .renderer(r):
                actions.append(.setRenderer(r))
            case let .retina(value, dpi):
                actions.append(.setRetina(enabled: value, dpi: dpi))
            case let .registry(key, name, type, data):
                actions.append(.addRegistry(key: key, name: name, type: type, data: data))
            case let .dlloverride(value):
                actions.append(.addDLLOverride(value))
            case let .env(name, value, scope):
                switch scope {
                case .bottle:
                    actions.append(.setBottleEnv(name: name, value: value))
                case .program:
                    if recipe.programs.isEmpty {
                        actions.append(.note("env \(name)=\(value) has program scope but the recipe adds no program; it was not applied"))
                    }
                }
            case let .winetricks(verbs, optional, note):
                actions.append(.winetricks(verbs: verbs, optional: optional, note: note))
            case let .file(path, contents, ifMissing):
                let url = try resolveTarget(path, variables: variables, layout: layout, what: where_)
                actions.append(.writeFile(url: url, contents: contents, ifMissing: ifMissing))
            case let .ini(path, section, key, value):
                let url = try resolveTarget(path, variables: variables, layout: layout, what: where_)
                actions.append(.setIni(url: url, section: section, key: key, value: value))
            case let .copy(from, to):
                let source = try resolveCopySource(from, variables: variables, engine: engine, layout: layout, what: where_)
                let target = try resolveTarget(to, variables: variables, layout: layout, what: where_)
                actions.append(.copyFile(from: source, to: target))
            case let .program(p):
                var program = p
                program.exe = WindowsPath.expand(p.exe, variables: gameDirVariables)
                program.workingDir = p.workingDir.map { WindowsPath.expand($0, variables: gameDirVariables) }
                program.args = p.args.map { WindowsPath.expand($0, variables: gameDirVariables) }
                program.env.merge(programEnv) { _, step in step }
                actions.append(.upsertProgram(program))
            case let .note(text):
                actions.append(.note(text))
            case .conditional:
                break   // unwrapped above; nesting is rejected by `Recipe.validate`
            }
        }
        return actions
    }

    /// A Windows path a step writes to, as a Unix URL inside the prefix. `${...}`/`%...%` are
    /// expanded first; a relative path is taken from `drive_c`. `Z:` and anything that climbs
    /// out of the prefix are refused: recipes are data and must not reach the rest of the Mac.
    static func resolveTarget(_ text: String, variables: [String: String], layout: BottleLayout, what: String) throws -> URL {
        let expanded = try expand(text, variables: variables, what: what)
        let url: URL
        if WindowsPath.isAbsolute(expanded) {
            guard let mapped = WindowsPath.toUnix(expanded, prefix: layout.prefix) else {
                throw OssoverError.invalid("\(what): cannot map '\(expanded)'")
            }
            url = mapped
        } else {
            url = try relative(expanded, under: layout.driveC, what: what)
        }
        guard isInside(url, layout.prefix) else {
            throw OssoverError.invalid("\(what): '\(text)' resolves outside the prefix (\(url.path))")
        }
        return url
    }

    /// The file a `copy` step reads: `${engine}/...` or an engine-relative path (inside the
    /// engine), or a Windows path inside the prefix.
    static func resolveCopySource(_ text: String, variables: [String: String], engine: Engine, layout: BottleLayout, what: String) throws -> URL {
        let expanded = try expand(text, variables: variables, what: what)
        if WindowsPath.isAbsolute(expanded) {
            guard let url = WindowsPath.toUnix(expanded, prefix: layout.prefix), isInside(url, layout.prefix) else {
                throw OssoverError.invalid("\(what): copy source '\(text)' is not inside the prefix")
            }
            return url
        }
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = try relative(expanded, under: engine.root, what: what)
        }
        guard isInside(url, engine.root) else {
            throw OssoverError.invalid("\(what): copy source '\(text)' is not inside engine \(engine.id)")
        }
        return url
    }

    static func expand(_ text: String, variables: [String: String], what: String) throws -> String {
        let expanded = WindowsPath.expand(text, variables: variables)
        let unresolved = WindowsPath.unresolvedVariables(in: expanded)
        guard unresolved.isEmpty else {
            throw OssoverError.invalid("\(what): unresolved variable(s) \(unresolved.joined(separator: ", ")) in '\(text)'")
        }
        return expanded
    }

    static func relative(_ text: String, under base: URL, what: String) throws -> URL {
        let components = WindowsPath.normalize(text).split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("..") else {
            throw OssoverError.invalid("\(what): '\(text)' is not a usable relative path")
        }
        var url = base
        for component in components { url.appendPathComponent(component) }
        return url.standardizedFileURL
    }

    /// Textual containment (Wine's own symlinks inside the prefix, such as a non-isolated
    /// `Documents`, are not followed). Both sides are standardized and `/private` is dropped,
    /// because `standardizedFileURL` strips it only when the path already exists.
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = canonicalPath(url)
        let rootPath = canonicalPath(root)
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return path
    }

    /// `sha256:<12 hex>` of the recipe's canonical JSON (sorted keys), the `version` recorded
    /// in `bottle.recipeHistory`.
    public static func fingerprint(of recipe: Recipe) throws -> String {
        "sha256:" + SHA256Hasher.hex(of: try JSONDocument.encode(recipe)).prefix(12)
    }

    // MARK: Apply

    /// Runs `actions` in order, mutating and saving `bottle.json` under `paths`. `wine` is
    /// required when any action `needsWine`. On failure the bottle is saved with what did run
    /// (its settings match the prefix) and the error is rethrown; the run is not recorded.
    public static func apply(_ actions: [RecipeAction], recipe: Recipe, bottle: Bottle, engine: Engine, paths: OssoverPaths,
                             wine: (any RecipeWineOperations)?, log: (@Sendable (String) -> Void)? = nil) async throws -> RecipeReport {
        if wine == nil, let first = actions.first(where: \.needsWine) {
            throw OssoverError.missing("Wine operations for '\(first.summary)' (recipe \(recipe.id))")
        }
        let layout = paths.bottleLayout(bottle.name)
        var bottle = bottle
        var report = RecipeReport(applied: RecipeApplied(id: recipe.id, version: try fingerprint(of: recipe)), bottle: bottle)
        do {
            for (index, action) in actions.enumerated() {
                log?("[\(recipe.id)] \(index + 1)/\(actions.count) \(action.summary)")
                try await perform(action, bottle: &bottle, report: &report, wine: wine, log: log)
            }
        } catch {
            try? bottle.save(to: layout.bottleJSON)
            throw error
        }
        if !bottle.recipesApplied.contains(recipe.id) { bottle.recipesApplied.append(recipe.id) }
        bottle.recipeHistory.append(report.applied)
        try bottle.validate()
        try bottle.save(to: layout.bottleJSON)
        report.bottle = bottle
        return report
    }

    static func perform(_ action: RecipeAction, bottle: inout Bottle, report: inout RecipeReport,
                        wine: (any RecipeWineOperations)?, log: (@Sendable (String) -> Void)?) async throws {
        let fm = FileManager.default
        switch action {
        case let .setWindowsVersion(v):
            bottle.settings.windowsVersion = v
            try await wine?.setWindowsVersion(v)
            report.performed.append(action.summary)
        case let .setSync(m):
            bottle.settings.sync = m
            report.performed.append(action.summary)
        case let .setRenderer(r):
            bottle.settings.renderer = r
            report.performed.append(action.summary)
        case let .setRetina(enabled, dpi):
            bottle.settings.retina = enabled
            if let dpi { bottle.settings.dpi = dpi }
            try await wine?.registryAdd(key: macDriverKey, name: retinaValueName, type: .string, data: enabled ? "y" : "n")
            try await wine?.registryAdd(key: desktopKey, name: logPixelsValueName, type: .dword, data: String(bottle.settings.dpi))
            report.performed.append(action.summary)
        case let .addRegistry(key, name, type, data):
            try await wine?.registryAdd(key: key, name: name, type: type, data: data)
            report.performed.append(action.summary)
        case let .addDLLOverride(value):
            if !bottle.settings.dllOverrides.contains(value) { bottle.settings.dllOverrides.append(value) }
            report.performed.append(action.summary)
        case let .setBottleEnv(name, value):
            bottle.settings.env[name] = value
            report.performed.append(action.summary)
        case let .winetricks(verbs, optional, note):
            do {
                try await wine?.winetricks(verbs: verbs)
                report.performed.append(action.summary)
            } catch {
                guard optional else { throw error }
                let reason = (error as? OssoverError)?.errorDescription ?? error.localizedDescription
                let line = "winetricks \(verbs.joined(separator: " ")) failed (optional): \(reason)" + (note.map { " — \($0)" } ?? "")
                log?("[skipped] \(line)")
                report.skipped.append(line)
            }
        case let .writeFile(url, contents, ifMissing):
            if ifMissing, fm.fileExists(atPath: url.path) {
                report.performed.append("kept existing \(url.path)")
                return
            }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
            } catch {
                throw OssoverError.io("cannot write \(url.path): \(error.localizedDescription)")
            }
            report.performed.append(action.summary)
        case let .setIni(url, section, key, value):
            var ini = try IniFile.load(from: url)
            let changed = ini.set(section: section, key: key, value: value)
            if changed || !fm.fileExists(atPath: url.path) { try ini.save(to: url) }
            report.performed.append(action.summary + (changed ? "" : " (unchanged)"))
        case let .copyFile(from, to):
            guard fm.fileExists(atPath: from.path) else { throw OssoverError.missing("copy source \(from.path)") }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            } catch {
                throw OssoverError.io("cannot copy \(from.path) to \(to.path): \(error.localizedDescription)")
            }
            report.performed.append(action.summary)
        case let .upsertProgram(p):
            bottle.upsert(p)
            report.performed.append(action.summary)
        case let .note(text):
            report.notes.append(text)
        case let .skipped(step, reason):
            log?("[skipped] \(step): \(reason)")
            report.skipped.append("\(step): \(reason)")
        }
    }
}
