// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OssoverKit

/// The Wine stage's running program is what the bench harness watches.
extension RunningProgram: LaunchedProcess {}

/// Starts bottle programs through `WineRunner` for `BenchHarness` (smoke, bench). The renderer
/// overlay is materialised once by the command before the harness runs; every launch then gets
/// the same selection. Shutdown is the plan's `wineserver -k` → `-w` → signals.
struct WineProgramLauncher: ProgramLauncher {
    let engine: Engine
    let bottle: Bottle
    let renderer: RendererSelection

    func launch(_ request: LaunchRequest) async throws -> any LaunchedProcess {
        let runner = WineRunner(engine: engine, bottle: request.bottle, layout: request.layout)
        return try await runner.launch(program: request.program, renderer: renderer, extra: request.extraEnvironment,
                                       logFile: request.logFile)
    }

    func shutdown(_ layout: BottleLayout) async throws {
        let report = try await WineServer.shutdown(engine: engine, bottle: bottle, layout: layout)
        Console.note(report.summary)
    }
}

/// `RecipeEngine`'s Wine operations on top of `WinVersion`, `Registry` and `Winetricks`.
struct WineRecipeOperations: RecipeWineOperations {
    let runner: WineRunner
    let paths: OssoverPaths
    /// Winetricks output goes to stdout when set (the verbs take minutes).
    let streamWinetricks: Bool

    func setWindowsVersion(_ version: WindowsVersion) async throws {
        try await WinVersion.set(version, runner: runner)
    }

    func registryAdd(key: String, name: String, type: RegistryValueType, data: String) async throws {
        try await Registry(runner: runner).add(key: key, name: name, type: type, data: data)
    }

    func winetricks(verbs: [String]) async throws {
        let onOutput: (@Sendable (Data) -> Void)? = streamWinetricks ? { @Sendable data in Console.stream(data) } : nil
        let log = try await Winetricks.run(verbs: verbs, engine: runner.engine, bottle: runner.bottle, layout: runner.layout,
                                           paths: paths, onOutput: onOutput)
        Console.note("winetricks log: \(log.path)")
    }
}

/// A bottle with its engine resolved: what `run`, `recipe apply`, `smoke` and `bench` start from.
struct BottleSession {
    let paths: OssoverPaths
    let bottle: Bottle
    let engine: Engine
    let layout: BottleLayout

    static func open(_ name: String, paths: OssoverPaths) throws -> BottleSession {
        let store = BottleStore(paths: paths)
        let bottle = try store.load(name)
        let engine = try EngineStore(paths: paths).engine(bottle.engineID)
        guard engine.isInstalled else {
            throw OssoverError.missing("engine \(bottle.engineID) of bottle \(name) is not installed (wine at \(engine.wine.path))")
        }
        return BottleSession(paths: paths, bottle: bottle, engine: engine, layout: store.layout(name))
    }

    /// The same bottle with a fresh `bottle.json` (after a recipe or a settings change).
    func reloaded() throws -> BottleSession {
        try BottleSession.open(bottle.name, paths: paths)
    }

    var runner: WineRunner { WineRunner(engine: engine, bottle: bottle, layout: layout) }

    /// Renderer packs this bottle may use: the engine's bundled ones plus installed packs whose
    /// files are complete and whose licence (D3DMetal) is accepted.
    func availablePacks() -> [RendererPack] {
        RendererResolver.bundledPacks(engine: engine) + RendererStore(paths: paths).usable()
    }

    /// The bottle's renderer (or `override`) resolved against the engine; an installed but
    /// unaccepted D3DMetal pack is reported as a licence problem, not a missing pack.
    func resolveRenderer(override: RendererChoice? = nil) throws -> RendererSelection {
        let choice = override ?? bottle.settings.renderer
        do {
            return try RendererResolver.resolve(choice: choice, engine: engine, packs: availablePacks())
        } catch let error as OssoverError {
            guard case .missing = error, choice.kind == .d3dmetal else { throw error }
            let store = RendererStore(paths: paths)
            if let pack = store.list().first(where: { $0.kind == .d3dmetal }), let reason = store.unusableReason(pack) {
                throw OssoverError.licenceNotAccepted("D3DMetal pack \(pack.id): \(reason) (ossover renderer accept \(pack.id))")
            }
            throw error
        }
    }

    /// Places the overlay for `selection` (strategy B copies into system32; C and wined3d touch
    /// nothing) and reports what it did.
    func materialize(_ selection: RendererSelection) throws -> Materialization {
        let result = try RendererMaterializer.prepare(bottle: bottle, layout: layout, engine: engine, selection: selection)
        for note in result.notes { Console.note("renderer: \(note)") }
        return result
    }

    /// `wineboot` + settings when the prefix has never been booted, and the same idempotent steps
    /// again when `bottle.json`'s engine stamp no longer names this engine id + version
    /// (`BottleStore.ensureInitialized`, REA L-42). The new stamp goes to `bottle.json`; this
    /// session's `bottle` copy stays as loaded (a launch does not read the stamp, and
    /// `Bottle.save` keeps the newer stamp on disk if this copy is saved later).
    func ensurePrefix() async throws {
        let result = try await BottleStore(paths: paths).ensureInitialized(bottle, engine: engine, log: Console.logger)
        for note in result.report?.notes ?? [] { Console.warn(note) }
    }

    /// Warns when the engine cannot give the bottle the sync it asks for.
    func warnAboutSync() {
        let effective = WineEnvironment.effectiveSync(bottle.settings.sync, capabilities: engine.capabilities)
        if effective != bottle.settings.sync {
            Console.warn("bottle asks for \(bottle.settings.sync.rawValue) but engine \(engine.id) lacks it; launches use \(effective.rawValue)")
        }
    }

    /// A program of the bottle by id, or an ad-hoc one for an exe given as a Windows or Unix
    /// path. `arguments` are appended to the program's own.
    func program(_ reference: String, arguments: [String]) throws -> Program {
        if var program = bottle.program(id: reference) {
            program.args += arguments
            return program
        }
        let exe = try Self.executableReference(reference, driveC: layout.driveC)
        let name = (exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last).map(String.init) ?? exe
        return Program(id: Program.slug((name as NSString).deletingPathExtension), name: name, exe: exe, args: arguments)
    }

    /// Turns what the user typed into a `Program.exe`: a Windows path stays one, a Unix path is
    /// made absolute, a path relative to `drive_c` becomes `C:\...`.
    static func executableReference(_ reference: String, driveC: URL) throws -> String {
        let fm = FileManager.default
        if WindowsPath.isAbsolute(reference) { return reference }
        if reference.hasPrefix("/") || reference.hasPrefix("~") || reference.hasPrefix(".") {
            let expanded = NSString(string: reference).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)).standardizedFileURL
            guard fm.fileExists(atPath: url.path) else { throw OssoverError.missing("executable \(url.path)") }
            return url.path
        }
        let inPrefix = driveC.appending(path: WindowsPath.normalize(reference).replacingOccurrences(of: "\\", with: "/"))
        if fm.fileExists(atPath: inPrefix.path) { return WindowsPath.join("C:\\", reference) }
        throw OssoverError.missing("program '\(reference)': not a program id of this bottle and not a file (give a Windows path like C:\\Games\\x.exe, a Unix path, or a path under drive_c)")
    }
}

/// Runs `body` as a task that Ctrl-C cancels: the harness's sleeps throw `.cancelled`, which
/// routes through its `end(live)` (program, wineserver, log stream) and `defer`s (caffeinate)
/// before the error surfaces here as exit status 1.
func withInterruptCancellation<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task { try await body() }
    let interrupt = InterruptGuard { task.cancel() }
    defer { interrupt.cancel() }
    do {
        return try await task.value
    } catch {
        if interrupt.wasInterrupted {
            Console.note("interrupted; the program and the bottle's wineserver were stopped")
            throw failure()
        }
        throw error
    }
}

/// Ctrl-C while a program runs: ends the program instead of leaving it attached to a dead pipe.
final class InterruptGuard: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let lock = NSLock()
    private var interrupted = false

    init(onInterrupt: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            self?.mark()
            onInterrupt()
        }
        source.resume()
    }

    private func mark() {
        lock.lock()
        interrupted = true
        lock.unlock()
    }

    var wasInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func cancel() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
