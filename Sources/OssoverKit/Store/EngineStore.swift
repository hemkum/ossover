// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/EngineStore.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// Installs, lists, verifies and removes engines under `<home>/engines/<id>/`.
///
/// Installed layout: `engines/<id>/{manifest.json, SHA256SUMS, <extracted tree>}` where the
/// extracted tree lands wherever the manifest's `source.extract.into` says (`engine/` for the
/// bootstrap engine, `.` for our own). The tree is unpacked into `engines/.<id>.partial` and only
/// renamed into place once it checked out, so an interrupted install never leaves a half engine.
public struct EngineStore: Sendable {
    public typealias Log = @Sendable (String) -> Void

    public static let xattrExecutable = "/usr/bin/xattr"
    public static let quarantineAttribute = "com.apple.quarantine"
    public static let stagingSuffix = ".partial"

    public let paths: OssoverPaths

    public init(paths: OssoverPaths = OssoverPaths()) { self.paths = paths }

    // MARK: Query

    /// Every engine under `engines/` whose manifest loads, sorted by id. A directory with a
    /// broken manifest is skipped (and named in `log`).
    public func list(log: Log? = nil) -> [Engine] {
        paths.installedEngineIDs().compactMap { id in
            do {
                return try Engine.load(root: paths.engine(id))
            } catch {
                log?("warning: engine \(id) skipped: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// The installed engine `id`, or `.missing`.
    public func engine(_ id: String) throws -> Engine {
        guard EngineManifest.isValidID(id) else { throw OssoverError.invalid("engine id '\(id)'") }
        let root = paths.engine(id)
        guard FileManager.default.fileExists(atPath: root.appending(path: Engine.manifestFileName).path) else {
            throw OssoverError.missing("engine \(id) is not installed (looked in \(root.path))")
        }
        return try Engine.load(root: root)
    }

    public func isInstalled(_ id: String) -> Bool {
        (try? engine(id))?.isInstalled ?? false
    }

    /// The manifests in a catalog directory (`engines/*.json` in the repo), sorted by file name.
    public static func catalog(in directory: URL) throws -> [EngineManifest] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw OssoverError.missing("\(directory.path): \(error.localizedDescription)")
        }
        return try entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try EngineManifest.load(from: $0) }
    }

    /// `engines/.<id>.partial`.
    public static func stagingDirectory(for id: String, under engines: URL) -> URL {
        engines.appending(path: ".\(id)\(stagingSuffix)", directoryHint: .isDirectory)
    }

    // MARK: Install

    /// Downloads (or reads, for a `file://` source), verifies, unpacks, de-quarantines, probes
    /// and records an engine. Returns the installed engine, whose manifest carries the
    /// capabilities the binaries actually have.
    ///
    /// - `replace`: reinstall over an existing `engines/<id>` instead of throwing `.alreadyExists`.
    ///   Refused while a process runs from inside that directory (Wine re-execs
    ///   `<engine>/bin/wine` for every new process, so pulling the tree away kills a running
    ///   session) unless `force`.
    /// - `progress`: download progress.
    /// - `log`: one line per step, including every warning (a capability the manifest got wrong,
    ///   Rosetta missing, a tool that could not run).
    public func install(_ manifest: EngineManifest, replace: Bool = false, force: Bool = false,
                        progress: DownloadProgressHandler? = nil, log: Log? = nil) async throws -> Engine {
        try manifest.validate()
        guard manifest.source.isPinned else {
            throw OssoverError.invalid("engine \(manifest.id): source.sha256 is TBD; pin the hash before installing")
        }
        guard manifest.runs(onMacOS: Version.currentMacOS) else {
            throw OssoverError.unsupported("engine \(manifest.id) needs macOS \(manifest.minMacOS) or later; this Mac runs \(Version.currentMacOS.text)")
        }
        let fm = FileManager.default
        let root = paths.engine(manifest.id)
        if fm.fileExists(atPath: root.path) {
            guard replace else { throw OssoverError.alreadyExists("engine \(manifest.id) at \(root.path) (pass replace to reinstall)") }
            try await Self.requireNotInUse(engineID: manifest.id, root: root, force: force)
        }
        try paths.ensureLayout()

        if manifest.requiresRosetta, SysInfo.isAppleSilicon(), !(await SysInfo.rosettaInstalled()) {
            log?("warning: engine \(manifest.id) needs Rosetta 2, which is not installed (softwareupdate --install-rosetta)")
        }

        log?("fetching \(manifest.source.url.absoluteString)")
        let archive = try await Download.fetch(manifest.source, into: paths.downloads, progress: progress)
        log?("verified \(archive.lastPathComponent) (sha256 \(manifest.source.sha256.prefix(12))…)")
        try Task.checkCancellation()

        let staging = Self.stagingDirectory(for: manifest.id, under: paths.engines)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(staging.path): \(error.localizedDescription)")
        }

        do {
            let spec = manifest.source.extract ?? ExtractSpec()
            let destination = spec.destination(under: staging)
            log?("extracting into \(spec.into) (strip \(spec.strip))")
            try await Tar.extract(archive, into: destination, stripComponents: spec.strip)
            try Task.checkCancellation()
            try Self.requireNoEscapingSymlinks(under: staging, what: "engine \(manifest.id)")
            let packagerSums = try Self.verifyPackagerSums(in: destination, under: staging, engineID: manifest.id, log: log)

            log?("removing \(Self.quarantineAttribute)")
            try await Self.stripQuarantine(staging, log: log)

            var installed = try Self.normalizeBundledRenderers(manifest, root: staging, log: log)
            let staged = Engine(root: staging, manifest: installed)
            try staged.validateLayout()

            log?("probing capabilities")
            let probe = await EngineProbe.detect(engine: staged, log: log)
            for line in probe.disagreements(with: manifest.capabilities) {
                log?("warning: engine \(manifest.id): \(line)")
            }
            installed.capabilities = probe.capabilities(over: manifest.capabilities)
            log?("capabilities: \(installed.capabilities.enabled.joined(separator: ", "))")
            if let probed = probe.wineVersionString {
                // `strings ntdll.so | grep -m1 -E 'wine-[0-9]+\.[0-9]+'`, never `wine --version` (REA L-45).
                installed.wineVersionString = probed
                log?("wine version string: \(probed) (ntdll.so)")
                if let line = EngineProbe.wineVersionDisagreement(probed: probed, declared: installed.wineVersion) {
                    log?("warning: engine \(manifest.id): \(line)")
                }
            } else if let declared = manifest.wineVersionString {
                log?("wine version string: \(declared) (from the manifest; ntdll.so not probed)")
            }

            let floor = Self.minMacOSFloor(for: installed, root: staging)
            if floor != installed.minMacOS {
                log?("minMacOS \(installed.minMacOS) → \(floor): a DXMT/D3DMetal overlay needs macOS \(Self.overlayMinMacOS) (REA L-62; decision 29)")
                installed.minMacOS = floor
                guard installed.runs(onMacOS: Version.currentMacOS) else {
                    throw OssoverError.unsupported("engine \(manifest.id) needs macOS \(floor) or later with its bundled overlay; this Mac runs \(Version.currentMacOS.text)")
                }
            }

            log?("hashing Mach-O files")
            let sums = try EngineIntegrity.writeSums(root: staging, to: staged.sha256sumsURL, merging: packagerSums)
            log?("recorded \(sums.count) files in \(Engine.sha256sumsFileName)" + (packagerSums.isEmpty ? "" : " (the packager's entries carried over)"))

            try installed.save(to: staged.manifestURL)
            try Task.checkCancellation()

            if replace, fm.fileExists(atPath: root.path) {
                // Checked again: the download may have taken a while.
                try await Self.requireNotInUse(engineID: manifest.id, root: root, force: force)
                do {
                    try fm.removeItem(at: root)
                } catch {
                    throw OssoverError.io("cannot remove the previous \(root.path): \(error.localizedDescription)")
                }
            }
            do {
                try fm.moveItem(at: staging, to: root)
            } catch {
                throw OssoverError.io("cannot move \(staging.lastPathComponent) to \(root.path): \(error.localizedDescription)")
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let engine = try Engine.load(root: root)
        log?("installed engine \(engine.id) at \(engine.root.path)")
        return engine
    }

    /// Throws `.invalid` while a process runs from inside `root`, unless `force`.
    static func requireNotInUse(engineID: String, root: URL, force: Bool) async throws {
        guard !force else { return }
        let running = try await ProcessTable.processes(underExecutable: root)
        guard running.isEmpty else {
            throw OssoverError.invalid("engine \(engineID) is in use by \(running.count) process(es) (pids \(running.map(String.init).joined(separator: ", "))); stop them first")
        }
    }

    // MARK: Bundled renderers

    /// Brings every `bundledRenderers` entry into a shape `RendererResolver.bundledPacks` can
    /// resolve (REA L-23, L-65; decision 16(d)). A bundle in Whisky's layout (`DXMT/{x64,x32}`,
    /// the bootstrap tarball) gets its directories renamed to Wine's (`x64` → `x86_64-windows`,
    /// `x32` → `i386-windows`, via `RendererStore.normalizeLayout`), any `*.so` beside the 64-bit
    /// PEs moved to `x86_64-unix/` (`RendererStore.separateUnixHalf`), and is moved to
    /// `overlays/<kind>/` — the bare root CrossOver's `lib/<backend>/` has and `engine/package.sh`
    /// already produces — with the manifest's `path` rewritten. Every bare bundle then has its
    /// `layout` recorded from the files on disk and its `builtinMarked` from the first PE's DOS
    /// stub (a manifest that said otherwise is corrected with a warning, as `RendererStore.install`
    /// does for packs). A pack-shaped bundle (`<path>/wine/…`) is left where it is. Returns the
    /// manifest to install. A bundle whose directory is missing is logged, not fatal: the engine
    /// still runs with Wine's own Direct3D.
    public static func normalizeBundledRenderers(_ manifest: EngineManifest, root: URL, log: Log? = nil) throws -> EngineManifest {
        let fm = FileManager.default
        var out = manifest
        for (index, bundled) in manifest.bundledRenderers.enumerated() {
            let kind = bundled.kind.rawValue
            let directory = root.appending(path: bundled.path, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                log?("warning: engine \(manifest.id): bundled \(kind) directory \(bundled.path) is missing; the bundle will not resolve")
                continue
            }
            for (from, to) in try RendererStore.normalizeLayout(in: directory).sorted(by: { $0.key < $1.key }) {
                log?("bundled \(kind): mapped \(bundled.path)/\(from)/ to \(to)/")
            }
            for name in try RendererStore.separateUnixHalf(in: directory) {
                log?("bundled \(kind): moved \(EngineArch.x86_64.pe64LibDir)/\(name) to \(EngineArch.x86_64.unixLibDir)/")
            }
            let pe64 = EngineArch.x86_64.pe64LibDir
            let packShaped = fm.fileExists(atPath: directory.appending(path: "\(RendererStore.wineDirectoryName)/\(pe64)").path)
            let bare = fm.fileExists(atPath: directory.appending(path: pe64).path)
            guard bare || packShaped else {
                log?("warning: engine \(manifest.id): bundled \(kind) at \(bundled.path) has no \(pe64)/ directory; the bundle will not resolve")
                continue
            }
            guard bare else { continue }
            let overlayPath = "\(Engine.overlaysDirectoryName)/\(kind)"
            let target = root.appending(path: overlayPath, directoryHint: .isDirectory)
            if directory.standardizedFileURL.path != target.standardizedFileURL.path {
                guard !fm.fileExists(atPath: target.path) else {
                    throw OssoverError.invalid("engine \(manifest.id): both \(bundled.path) and \(overlayPath) exist; the manifest must name one")
                }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: directory, to: target)
                } catch {
                    throw OssoverError.io("cannot move \(directory.path) to \(target.path): \(error.localizedDescription)")
                }
                out.bundledRenderers[index].path = overlayPath
                log?("bundled \(kind): \(bundled.path) → \(overlayPath)")
            }

            // What is really there, so `RendererResolver.bundledPacks` synthesises a pack that
            // matches the files (the DXMT file set of REA L-65, or whatever this tarball holds).
            let layout = RendererStore.layout(ofWineDir: target)
            if let declared = bundled.layout, declared != layout {
                log?("bundled \(kind): layout recorded from the files: unix \(layout.unix), pe \(layout.pe), pe32 \(layout.pe32 ?? [])")
            }
            out.bundledRenderers[index].layout = layout
            if let first = layout.pe.first, let marked = RendererStore.isBuiltinMarked(target.appending(path: "\(pe64)/\(first)")) {
                if let declared = bundled.builtinMarked, declared != marked {
                    log?("warning: engine \(manifest.id): bundled \(kind): manifest says builtinMarked \(declared), \(first) says \(marked); recording \(marked)")
                }
                out.bundledRenderers[index].builtinMarked = marked
            }
        }
        return out
    }

    // MARK: Floors and sums

    /// macOS floor of a DXMT or D3DMetal overlay: `winemetal.so`, `libd3dshared.dylib` and
    /// `D3DMetal` are all built `minos 14.0` (REA L-62, L-78).
    public static let overlayMinMacOS = "14.0"
    public static let overlayMinMacOSKinds: Set<RendererKind> = [.dxmt, .d3dmetal]

    /// `manifest.minMacOS`, raised to `overlayMinMacOS` when a bundled DXMT or D3DMetal overlay
    /// is present under `root` (decision 29). The plain Wine engine keeps the toolchain's floor.
    public static func minMacOSFloor(for manifest: EngineManifest, root: URL) -> String {
        let fm = FileManager.default
        let active = manifest.bundledRenderers.contains { bundled in
            var isDir: ObjCBool = false
            return overlayMinMacOSKinds.contains(bundled.kind)
                && fm.fileExists(atPath: root.appending(path: bundled.path).path, isDirectory: &isDir) && isDir.boolValue
        }
        guard active, let floor = Version(overlayMinMacOS) else { return manifest.minMacOS }
        if let current = Version(manifest.minMacOS), current >= floor { return manifest.minMacOS }
        return overlayMinMacOS
    }

    /// A `SHA256SUMS` the packager left at the root of the extracted tree (`engine/package.sh`
    /// hashes every regular file) is checked before anything else happens to the tree: every
    /// listed file must be present with its hash, or the install stops. Returns the entries with
    /// paths rebased to `staging` (the tree may sit in a subdirectory, `extract.into`), so
    /// `EngineIntegrity.writeSums(root:to:merging:)` can carry them into the installed
    /// `SHA256SUMS`; empty when the tree carries none (the bootstrap tarball).
    public static func verifyPackagerSums(in destination: URL, under staging: URL, engineID: String, log: Log? = nil) throws -> [SHA256Hasher.Entry] {
        let sumsFile = destination.appending(path: Engine.sha256sumsFileName)
        guard FileManager.default.fileExists(atPath: sumsFile.path) else { return [] }
        let report = try EngineIntegrity.verify(root: destination, sumsFile: sumsFile)
        guard report.ok else {
            let shown = (report.changed.map { "changed \($0)" } + report.missing.map { "missing \($0)" }).prefix(5)
            throw OssoverError.invalid("engine \(engineID): the packager's \(Engine.sha256sumsFileName) does not match the extracted tree (\(report.summary)): " + shown.joined(separator: ", "))
        }
        log?("verified \(report.checked) files against the packager's \(Engine.sha256sumsFileName)")
        let text: String
        do {
            text = try String(contentsOf: sumsFile, encoding: .utf8)
        } catch {
            throw OssoverError.io("cannot read \(sumsFile.path): \(error.localizedDescription)")
        }
        let base = staging.standardizedFileURL.path
        let inner = destination.standardizedFileURL.path
        var prefix = inner == base ? "" : String(inner.dropFirst(base.count))
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        return SHA256Hasher.parseSums(text).map { entry in
            prefix.isEmpty ? entry : SHA256Hasher.Entry(path: prefix + "/" + entry.path, sha256: entry.sha256)
        }
    }

    // MARK: Verify

    /// Re-hashes every file the engine's `SHA256SUMS` lists.
    public func verify(_ engine: Engine) throws -> EngineIntegrity.Report {
        try engine.validateLayout()
        return try EngineIntegrity.verify(root: engine.root, sumsFile: engine.sha256sumsURL)
    }

    // MARK: Remove

    /// Deletes `engines/<id>`. Refuses while a process runs from inside the engine unless `force`.
    /// Bottles that name the engine are not touched; the caller decides what to do with them
    /// (`BottleStore.bottles(usingEngine:)`).
    public func remove(_ id: String, force: Bool = false) async throws {
        let engine = try engine(id)
        if !force {
            let running = try await ProcessTable.processes(underExecutable: engine.root)
            guard running.isEmpty else {
                throw OssoverError.invalid("engine \(id) is in use by \(running.count) process(es) (pids \(running.map(String.init).joined(separator: ", "))); stop them first")
            }
        }
        do {
            try FileManager.default.removeItem(at: engine.root)
        } catch {
            throw OssoverError.io("cannot remove \(engine.root.path): \(error.localizedDescription)")
        }
    }

    // MARK: Quarantine

    /// `xattr -drs com.apple.quarantine <directory>`: `-s` acts on a symbolic link itself instead
    /// of following it, so a link inside the tree can never de-quarantine a file outside it.
    /// A non-zero status (xattr complains about files that never had the attribute) is logged,
    /// not thrown; a tool that cannot start is.
    public static func stripQuarantine(_ directory: URL, log: Log? = nil) async throws {
        let args = ["-drs", quarantineAttribute, directory.path]
        let result = try await Shell.run(executable: xattrExecutable, args: args, timeout: 600)
        if !result.succeeded {
            log?("note: \(Shell.commandLine(xattrExecutable, args)) exited \(result.status): \(OssoverError.tail(of: result.combined, lines: 2))")
        }
    }

    /// Symbolic links under `root` whose resolved target lies outside `root` (bsdtar keeps
    /// absolute and `..` link targets). A dangling link points at nothing `xattr` could touch
    /// and is not reported.
    public static func escapingSymlinks(under root: URL) -> [URL] {
        let fm = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let basePrefix = base == "/" ? "/" : base + "/"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [] }
        var escaping: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            guard fm.fileExists(atPath: url.path) else { continue }   // dangling
            let resolved = url.resolvingSymlinksInPath().path
            if resolved != base, !resolved.hasPrefix(basePrefix) { escaping.append(url) }
        }
        return escaping.sorted { $0.path < $1.path }
    }

    /// Throws `.invalid` naming the first few links `escapingSymlinks` found under `root`.
    public static func requireNoEscapingSymlinks(under root: URL, what: String) throws {
        let escaping = escapingSymlinks(under: root)
        guard escaping.isEmpty else {
            let shown = escaping.prefix(5).map { "\($0.path) -> \((try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) ?? "?")" }
            throw OssoverError.invalid("\(what): the archive holds \(escaping.count) symbolic link(s) pointing outside the install directory: " + shown.joined(separator: ", "))
        }
    }
}
