// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/EngineStore.swift (staging-then-rename install) and
//   Sources/HighballApp/AppState.swift (hdiutil -plist parsing) (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// `hdiutil` for the Game Porting Toolkit dmg: attached read-only and hidden from Finder,
/// detached when the import ends whatever happened.
public enum DiskImage {
    public static let executable = "/usr/bin/hdiutil"
    public static let attachTimeout: TimeInterval = 600

    /// Mount points from `hdiutil attach -plist` output (`system-entities[].mount-point`). Pure.
    public static func mountPoints(fromAttachPlist text: String) -> [URL] {
        // Newer macOS prints a deprecation warning before the plist on the same stream.
        let xml = text.range(of: "<?xml").map { String(text[$0.lowerBound...]) } ?? text
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { entity in
            (entity["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    /// Attaches `image` and returns its mount points.
    // TODO(REA): a dmg with an embedded licence agreement makes hdiutil prompt on stdin, which
    // Shell closes; if Apple's GPTK dmg ever ships one, the CLI must attach it in the foreground.
    public static func attach(_ image: URL) async throws -> [URL] {
        guard FileManager.default.fileExists(atPath: image.path) else { throw OssoverError.missing(image.path) }
        let args = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", image.path]
        let result = try await Shell.run(executable: executable, args: args, timeout: attachTimeout)
        try result.check(command: Shell.commandLine(executable, args))
        let points = mountPoints(fromAttachPlist: result.stdout)
        guard !points.isEmpty else { throw OssoverError.invalid("\(image.lastPathComponent) attached but mounted no volume") }
        return points
    }

    /// `hdiutil detach`, then `-force` when the plain detach fails. Never throws: by the time
    /// this runs the import has already succeeded or failed.
    public static func detach(_ mountPoint: URL) async {
        for extra in [[String](), ["-force"]] {
            let args = ["detach", mountPoint.path] + extra
            if let result = try? await Shell.run(executable: executable, args: args, timeout: 120), result.succeeded { return }
        }
    }
}

/// `codesign` for imported Apple binaries: verify (`--strict`), test the `anchor apple`
/// requirement, and read who signed them. The GPTK's `libd3dshared.dylib` and `D3DMetal`
/// are Apple-signed (`Software Signing` → `Apple Code Signing Certification Authority` →
/// `Apple Root CA`, designated requirement `anchor apple`; REA L-75) and must stay so:
/// nothing here re-signs, strips or rewrites install names.
public enum CodeSign {
    public static let executable = "/usr/bin/codesign"
    /// `codesign -R`'s inline-requirement form (the leading `=` marks text, not a file path).
    public static let appleAnchorRequirement = "=anchor apple"
    /// The leaf of Apple's own software-signing chain, as `codesign -d` prints it.
    public static let appleSoftwareSigningAuthority = "Software Signing"
    public static let appleRootAuthority = "Apple Root CA"

    /// `Identifier=` and `Authority=` lines of `codesign -d --verbose=2` output. Pure.
    public static func parseInfo(_ text: String) -> (identifier: String?, authorities: [String]) {
        var identifier: String?
        var authorities: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Identifier="), identifier == nil {
                identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("Authority=") {
                authorities.append(String(line.dropFirst("Authority=".count)))
            }
        }
        return (identifier, authorities)
    }

    /// Whether an `Authority=` chain is Apple's own software-signing chain (what `anchor apple`
    /// accepts): leaf `Software Signing`, root `Apple Root CA`. A Developer ID or Mac App Store
    /// chain also ends at `Apple Root CA` but has another leaf, and is `anchor apple generic`
    /// at most. Pure; the live test is `satisfiesAppleAnchor`.
    public static func chainAnchorsAtApple(_ authorities: [String]) -> Bool {
        guard let leaf = authorities.first, let root = authorities.last else { return false }
        return leaf == appleSoftwareSigningAuthority && root == appleRootAuthority
    }

    /// The Mach-O inside a framework bundle (`Versions/Current/<name>`, else `<name>`), or nil
    /// when `url` is not a framework. `codesign` refuses some framework directories as "bundle
    /// format is ambiguous"; the binary carries the same signature and is unambiguous.
    public static func frameworkBinary(_ url: URL) -> URL? {
        guard url.pathExtension == "framework" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for candidate in [url.appending(path: "Versions/Current/\(name)"), url.appending(path: name)] where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// `codesign --verify --strict -R '=anchor apple' <file>`: true only when the signature is
    /// valid and Apple's own. A framework is tested through its binary.
    public static func satisfiesAppleAnchor(_ file: URL) async throws -> Bool {
        let target = frameworkBinary(file) ?? file
        let result = try await Shell.run(executable: executable, args: ["--verify", "--strict", "-R", appleAnchorRequirement, target.path], timeout: 300)
        return result.succeeded
    }

    /// Verifies `file` (a Mach-O or a framework bundle) strictly, tests the `anchor apple`
    /// requirement and reads its signing chain. Never re-signs.
    public static func inspect(_ file: URL, recordedAs path: String) async throws -> SignedFile {
        let target = frameworkBinary(file) ?? file
        let verify = try await Shell.run(executable: executable, args: ["--verify", "--strict", "--verbose=2", target.path], timeout: 300)
        let info = try await Shell.run(executable: executable, args: ["-d", "--verbose=2", target.path], timeout: 120)
        let parsed = parseInfo(info.combined)
        let anchored = try await satisfiesAppleAnchor(file)
        return SignedFile(path: path, identifier: parsed.identifier, authorities: parsed.authorities, verified: verify.succeeded,
                          anchorApple: anchored)
    }
}

/// Installs, imports, lists and removes renderer packs under `<home>/renderers/<id>/`.
///
/// Installed layout (plan §4): `renderers/<id>/{manifest.json, wine/{x86_64-unix, x86_64-windows,
/// i386-windows}}` plus `external/` for D3DMetal. Downloaded packs (DXMT, DXVK) come from the
/// catalog manifests; D3DMetal only ever comes from the user's own GPTK dmg through
/// `importGPTK`, and is usable only after `accept` records the licence.
public struct RendererStore: Sendable {
    public typealias Log = @Sendable (String) -> Void

    public static let stagingSuffix = ".partial"
    public static let wineDirectoryName = "wine"
    public static let externalDirectoryName = "external"
    /// Archive directory names → pack directory names: the DXVK-macOS repack ships `x64/` and
    /// `x32/`, DXMT's release asset already uses Wine's names.
    public static let directoryMap: [String: String] = [
        "x64": "x86_64-windows", "x32": "i386-windows", "x86": "i386-windows",
        "x86_64-windows": "x86_64-windows", "i386-windows": "i386-windows", "x86_64-unix": "x86_64-unix",
    ]
    /// Direct3D DLLs a pack may override in `WINEDLLOVERRIDES` (helper DLLs such as nvapi64 are not).
    public static let d3dDLLNames: Set<String> = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "d3d12", "dxgi"]
    public static let builtinMark = "Wine builtin DLL"
    /// The GPTK's Rosetta/D3DMetal bridge under `external/`, what `CX_APPLEGPTK_LIBD3DSHARED_PATH` names (REA L-53).
    public static let gptkSharedLibraryName = "libd3dshared.dylib"
    /// Where the GPTK's six `wine/x86_64-unix/*.so` point, relative to that directory (REA L-55).
    public static let gptkUnixLinkTarget = "../../external/libd3dshared.dylib"
    /// A signature inspector (`CodeSign.inspect` by default; tests inject one).
    public typealias SignatureInspector = @Sendable (_ file: URL, _ recordedAs: String) async throws -> SignedFile

    public let paths: OssoverPaths

    public init(paths: OssoverPaths = OssoverPaths()) { self.paths = paths }

    // MARK: Query

    /// Every pack under `renderers/` whose manifest loads, sorted by id.
    public func list(log: Log? = nil) -> [RendererPack] {
        paths.installedRendererIDs().compactMap { id in
            do {
                return try RendererPack.load(root: paths.renderer(id))
            } catch {
                log?("warning: renderer \(id) skipped: \(error.localizedDescription)")
                return nil
            }
        }
    }

    public func pack(_ id: String) throws -> RendererPack {
        guard EngineManifest.isValidID(id) else { throw OssoverError.invalid("renderer id '\(id)'") }
        let root = paths.renderer(id)
        guard FileManager.default.fileExists(atPath: root.appending(path: RendererPack.manifestFileName).path) else {
            throw OssoverError.missing("renderer \(id) is not installed (looked in \(root.path))")
        }
        return try RendererPack.load(root: root)
    }

    public func isInstalled(_ id: String) -> Bool { (try? pack(id)) != nil }

    /// The manifests in a catalog directory (`renderers/*.json` in the repo), sorted by file name.
    public static func catalog(in directory: URL) throws -> [RendererPackManifest] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw OssoverError.missing("\(directory.path): \(error.localizedDescription)")
        }
        return try entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try RendererPackManifest.load(from: $0) }
    }

    /// `licenses/apple-gptk-<pack id>.json`.
    public func licenceRecordURL(for packID: String) -> URL {
        paths.licenses.appending(path: LicenceRecord.fileName(forPack: packID))
    }

    public func licenceRecord(for packID: String) -> LicenceRecord? {
        try? LicenceRecord.load(from: licenceRecordURL(for: packID))
    }

    /// A pack a launch may use: every layout file present and, for D3DMetal, the licence accepted.
    public func isUsable(_ pack: RendererPack) -> Bool {
        guard pack.missingFiles.isEmpty else { return false }
        guard pack.kind.needsLicence else { return true }
        return licenceRecord(for: pack.id)?.isAccepted == true
    }

    /// Why `pack` cannot be used, nil when it can.
    public func unusableReason(_ pack: RendererPack) -> String? {
        let missing = pack.missingFiles
        if !missing.isEmpty { return "missing " + missing.map(\.lastPathComponent).joined(separator: ", ") }
        if pack.kind.needsLicence, licenceRecord(for: pack.id)?.isAccepted != true {
            return "Apple's licence not accepted (run: ossover renderer accept \(pack.id))"
        }
        return nil
    }

    public func usable(log: Log? = nil) -> [RendererPack] { list(log: log).filter(isUsable) }

    /// Kinds with at least one usable pack (what `RecipeRequires.unmet` wants).
    public func usableKinds() -> Set<RendererKind> { Set(usable().map(\.kind)) }

    /// The usable pack of `kind` with the highest version, nil when none.
    public func pack(ofKind kind: RendererKind) -> RendererPack? {
        usable().filter { $0.kind == kind }.max { a, b in
            (Version(a.manifest.version) ?? Version([0])) < (Version(b.manifest.version) ?? Version([0]))
        }
    }

    /// `renderers/.<id>.partial`.
    public static func stagingDirectory(for id: String, under renderers: URL) -> URL {
        renderers.appending(path: ".\(id)\(stagingSuffix)", directoryHint: .isDirectory)
    }

    // MARK: Install (downloaded packs)

    /// Downloads, verifies and unpacks a catalog pack into `renderers/<id>/wine/…`, mapping the
    /// archive's directory names onto Wine's. D3DMetal is refused here: it is imported.
    /// `replace` is refused while a running process has the pack on its DLL path or a bottle
    /// with the pack placed in its prefix (`.renderer-state.json`) is running, unless `force`.
    public func install(_ manifest: RendererPackManifest, replace: Bool = false, force: Bool = false,
                        progress: DownloadProgressHandler? = nil, log: Log? = nil) async throws -> RendererPack {
        try manifest.validate()
        guard !manifest.kind.needsLicence else {
            throw OssoverError.unsupported("\(manifest.kind.displayName) is never downloaded; import Apple's GPTK dmg (renderer import-gptk)")
        }
        guard let source = manifest.source else {
            throw OssoverError.invalid("renderer \(manifest.id) has no download source")
        }
        guard source.isPinned else {
            throw OssoverError.invalid("renderer \(manifest.id): source.sha256 is TBD; pin the hash before installing")
        }
        let fm = FileManager.default
        let root = paths.renderer(manifest.id)
        if fm.fileExists(atPath: root.path) {
            guard replace else { throw OssoverError.alreadyExists("renderer \(manifest.id) at \(root.path) (pass replace to reinstall)") }
            try await requireNotInUse(packID: manifest.id, root: root, force: force)
        }
        try paths.ensureLayout()

        log?("fetching \(source.url.absoluteString)")
        let archive = try await Download.fetch(source, into: paths.downloads, progress: progress)
        log?("verified \(archive.lastPathComponent) (sha256 \(source.sha256.prefix(12))…)")
        try Task.checkCancellation()

        let staging = Self.stagingDirectory(for: manifest.id, under: paths.renderers)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(staging.path): \(error.localizedDescription)")
        }

        do {
            let spec: ExtractSpec
            if let given = source.extract {
                spec = given
            } else {
                let entries = try await Tar.list(archive)
                spec = ExtractSpec(strip: Tar.commonTopLevel(of: entries) == nil ? 0 : 1, into: Self.wineDirectoryName)
            }
            let destination = spec.destination(under: staging)
            log?("extracting into \(spec.into) (strip \(spec.strip))")
            try await Tar.extract(archive, into: destination, stripComponents: spec.strip)
            try Task.checkCancellation()

            let wineDir = staging.appending(path: Self.wineDirectoryName, directoryHint: .isDirectory)
            for (from, to) in try Self.normalizeLayout(in: wineDir).sorted(by: { $0.key < $1.key }) {
                log?("mapped \(from)/ to \(to)/")
            }
            for name in try Self.separateUnixHalf(in: wineDir) {
                log?("moved \(EngineArch.x86_64.pe64LibDir)/\(name) to \(EngineArch.x86_64.unixLibDir)/")
            }
            try EngineStore.requireNoEscapingSymlinks(under: staging, what: "renderer \(manifest.id)")
            try await EngineStore.stripQuarantine(staging, log: log)

            var installed = manifest
            let staged = RendererPack(root: staging, manifest: installed)
            try staged.validateLayout()
            if let first = installed.layout.pe.first, let marked = Self.isBuiltinMarked(staged.peDir.appending(path: first)),
               marked != installed.builtinMarked {
                log?("warning: renderer \(manifest.id): manifest says builtinMarked \(installed.builtinMarked), \(first) says \(marked); recording \(marked)")
                installed.builtinMarked = marked
            }
            try installed.save(to: staged.manifestURL)
            try Task.checkCancellation()

            if replace, fm.fileExists(atPath: root.path) {
                try await requireNotInUse(packID: manifest.id, root: root, force: force)
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
        let pack = try RendererPack.load(root: root)
        log?("installed renderer \(pack.id) at \(pack.root.path)")
        return pack
    }

    /// Pids that depend on the pack at `root` right now: processes whose `WINEDLLPATH` or
    /// `WINEDLLPATH_PREPEND` names it (strategy B and C launches) and the Wine processes of
    /// every bottle whose `.renderer-state.json` says the pack's files sit in its prefix.
    public func processesUsing(packRoot root: URL) async throws -> [pid_t] {
        var pids = Set(try await ProcessTable.processes(usingDLLPath: root))
        for name in paths.bottleNames() {
            let layout = paths.bottleLayout(name)
            guard let state = RendererMaterializer.state(layout: layout),
                  state.packRoot == root.standardizedFileURL.path else { continue }
            pids.formUnion(try await ProcessTable.processes(ofPrefix: layout.prefix))
        }
        return pids.sorted()
    }

    /// Throws `.invalid` while `processesUsing` finds anything, unless `force`.
    func requireNotInUse(packID: String, root: URL, force: Bool) async throws {
        guard !force else { return }
        let running = try await processesUsing(packRoot: root)
        guard running.isEmpty else {
            throw OssoverError.invalid("renderer \(packID) is in use by \(running.count) process(es) (pids \(running.map(String.init).joined(separator: ", "))); stop them first")
        }
    }

    /// The pack directory an archive directory maps to, nil for an unknown name. Pure.
    public static func packDirectoryName(forArchiveDirectory name: String) -> String? { directoryMap[name] }

    /// Renames the directories under `wineDir` that `directoryMap` knows (`x64` → `x86_64-windows`)
    /// and returns what moved. Throws when both spellings exist.
    @discardableResult
    public static func normalizeLayout(in wineDir: URL) throws -> [String: String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: wineDir.path, isDirectory: &isDir), isDir.boolValue else { return [:] }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: wineDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            throw OssoverError.io("cannot list \(wineDir.path): \(error.localizedDescription)")
        }
        var moved: [String: String] = [:]
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = entry.lastPathComponent
            guard let target = packDirectoryName(forArchiveDirectory: name), target != name else { continue }
            let destination = wineDir.appending(path: target, directoryHint: .isDirectory)
            guard !fm.fileExists(atPath: destination.path) else {
                throw OssoverError.invalid("archive holds both \(name)/ and \(target)/ under \(wineDir.lastPathComponent)/")
            }
            do {
                try fm.moveItem(at: entry, to: destination)
            } catch {
                throw OssoverError.io("cannot rename \(entry.path): \(error.localizedDescription)")
            }
            moved[name] = target
        }
        return moved
    }

    /// Moves every `*.so` found in `<wineDir>/x86_64-windows` (an archive that keeps a Unix
    /// half beside its 64-bit PEs, Whisky's `x64/`) into `<wineDir>/x86_64-unix`, so the overlay
    /// has CrossOver's `<arch>-{unix,windows}` split (REA L-23). Returns the names moved.
    @discardableResult
    public static func separateUnixHalf(in wineDir: URL) throws -> [String] {
        let fm = FileManager.default
        let pe64 = wineDir.appending(path: EngineArch.x86_64.pe64LibDir, directoryHint: .isDirectory)
        let unix = wineDir.appending(path: EngineArch.x86_64.unixLibDir, directoryHint: .isDirectory)
        let names = fileNames(in: pe64, extension: "so")
        guard !names.isEmpty else { return [] }
        do {
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            for name in names {
                let destination = unix.appending(path: name)
                guard !fm.fileExists(atPath: destination.path) else {
                    throw OssoverError.invalid("archive holds \(name) under both \(EngineArch.x86_64.pe64LibDir)/ and \(EngineArch.x86_64.unixLibDir)/")
                }
                try fm.moveItem(at: pe64.appending(path: name), to: destination)
            }
        } catch let error as OssoverError {
            throw error
        } catch {
            throw OssoverError.io("cannot move the Unix half under \(wineDir.path): \(error.localizedDescription)")
        }
        return names
    }

    /// The layout on disk under `wineDir` (`x86_64-unix/*.so`, `x86_64-windows/*.dll`,
    /// `i386-windows/*.dll` when that directory exists), names sorted; symlinks count.
    public static func layout(ofWineDir wineDir: URL) -> RendererLayout {
        let pe32 = wineDir.appending(path: EngineArch.pe32LibDir, directoryHint: .isDirectory)
        return RendererLayout(
            unix: fileNames(in: wineDir.appending(path: EngineArch.x86_64.unixLibDir), extension: "so"),
            pe: fileNames(in: wineDir.appending(path: EngineArch.x86_64.pe64LibDir), extension: "dll"),
            pe32: FileManager.default.fileExists(atPath: pe32.path) ? fileNames(in: pe32, extension: "dll") : nil)
    }

    /// Name → link destination for every symbolic link in `<wineDir>/x86_64-unix` (the GPTK's
    /// six `*.so` → `../../external/libd3dshared.dylib`). Empty when none.
    public static func unixLinkTargets(in wineDir: URL) -> [String: String] {
        let fm = FileManager.default
        let unix = wineDir.appending(path: EngineArch.x86_64.unixLibDir, directoryHint: .isDirectory)
        let entries = (try? fm.contentsOfDirectory(at: unix, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        var out: [String: String] = [:]
        for entry in entries where (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            if let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) { out[entry.lastPathComponent] = target }
        }
        return out
    }

    /// Makes `<copy>/x86_64-unix` carry the same symbolic links as `<source>/x86_64-unix`, with
    /// the same (relative) destinations: a link the copy already has is left alone, a regular
    /// file or a link elsewhere is replaced. Returns name → destination for the links ensured.
    /// (`FileManager.copyItem` keeps links, so this is a guarantee, not a repair, in practice.)
    @discardableResult
    public static func recreateUnixLinks(from source: URL, to copy: URL) throws -> [String: String] {
        let fm = FileManager.default
        let links = unixLinkTargets(in: source)
        guard !links.isEmpty else { return [:] }
        let unix = copy.appending(path: EngineArch.x86_64.unixLibDir, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            for (name, target) in links.sorted(by: { $0.key < $1.key }) {
                let link = unix.appending(path: name)
                if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target { continue }
                if fm.fileExists(atPath: link.path) || (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    try fm.removeItem(at: link)
                }
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        } catch {
            throw OssoverError.io("cannot recreate the x86_64-unix links under \(copy.path): \(error.localizedDescription)")
        }
        return links
    }

    /// Relative paths under `source` whose counterpart under `copy` is not byte-identical (a
    /// regular file with another hash or size), links to somewhere else, or is missing. Empty
    /// when `copy` is a verbatim copy of `source`. Symbolic links are compared by destination,
    /// never followed.
    public static func verbatimMismatches(source: URL, copy: URL) throws -> [String] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: source.standardizedFileURL, includingPropertiesForKeys: Array(keys),
                                             options: [.producesRelativePathURLs]) else {
            throw OssoverError.missing(source.path)
        }
        var mismatches: [String] = []
        for case let url as URL in enumerator {
            let relative = url.relativePath
            let twin = copy.appending(path: relative)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                let want = try? fm.destinationOfSymbolicLink(atPath: url.path)
                let have = try? fm.destinationOfSymbolicLink(atPath: twin.path)
                if want == nil || want != have { mismatches.append(relative) }
            } else if values.isDirectory == true {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: twin.path, isDirectory: &isDir) || !isDir.boolValue { mismatches.append(relative) }
            } else if values.isRegularFile == true {
                let twinValues = try? twin.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard twinValues?.isRegularFile == true, twinValues?.isSymbolicLink != true, twinValues?.fileSize == values.fileSize,
                      let a = try? SHA256Hasher.hex(ofFile: url), let b = try? SHA256Hasher.hex(ofFile: twin), a == b else {
                    mismatches.append(relative)
                    continue
                }
            }
        }
        return mismatches.sorted()
    }

    /// Whether a PE file carries Wine's 16-byte "Wine builtin DLL" DOS-stub mark at offset 64;
    /// nil when the file cannot be read. (`PEBuiltinMark` in Renderer/ strips and re-applies it.)
    public static func isBuiltinMarked(_ dll: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: dll) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 64)) != nil, let bytes = try? handle.read(upToCount: builtinMark.utf8.count) else { return nil }
        return bytes == Data(builtinMark.utf8)
    }

    // MARK: Import (D3DMetal from the Game Porting Toolkit dmg)

    /// Imports Apple's D3DMetal from a GPTK dmg the user downloaded: mounts it read-only (a dmg
    /// nested inside is mounted too), copies `redist/lib/{external,wine}` **verbatim** into
    /// `renderers/d3dmetal-<version>/` (`stageGPTK`: the six `x86_64-unix/*.so` symlinks kept,
    /// Apple's signatures verified with `codesign --verify --strict` and the `anchor apple`
    /// requirement, nothing re-signed, stripped or install-name-rewritten; REA L-55, L-75,
    /// decision 14), writes the manifest and a licence record with `acceptedAt: null`. The pack
    /// stays unusable until `accept`.
    public func importGPTK(dmgURL: URL, version explicitVersion: String? = nil, replace: Bool = false, force: Bool = false,
                           log: Log? = nil) async throws -> RendererPack {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dmgURL.path) else { throw OssoverError.missing(dmgURL.path) }
        try paths.ensureLayout()

        log?("hashing \(dmgURL.lastPathComponent)")
        let dmgSHA = try SHA256Hasher.hex(ofFile: dmgURL)
        let dmg = ImportedArtifact(fileName: dmgURL.lastPathComponent, sha256: dmgSHA, size: Download.fileSize(dmgURL))

        var mounted: [URL] = []
        var staging: URL?
        do {
            log?("attaching \(dmgURL.lastPathComponent)")
            let outer = try await DiskImage.attach(dmgURL)
            mounted += outer
            var redistLib = outer.lazy.compactMap { Self.findRedistLib(under: $0) }.first
            if redistLib == nil {
                search: for mount in outer {
                    for nested in Self.nestedDiskImages(under: mount) {
                        log?("attaching nested \(nested.lastPathComponent)")
                        let inner = try await DiskImage.attach(nested)
                        mounted += inner
                        if let found = inner.lazy.compactMap({ Self.findRedistLib(under: $0) }).first {
                            redistLib = found
                            break search
                        }
                    }
                }
            }
            guard let redistLib else {
                throw OssoverError.missing("redist/lib (with external/ and wine/) inside \(dmgURL.lastPathComponent)")
            }
            log?("found \(redistLib.path)")
            let external = redistLib.appending(path: Self.externalDirectoryName, directoryHint: .isDirectory)
            let version = explicitVersion
                ?? Self.gptkVersion(frameworkDirectory: external.appending(path: "D3DMetal.framework", directoryHint: .isDirectory))
                ?? Self.version(fromFileName: dmgURL.lastPathComponent)
                ?? "unknown"
            let id = Self.packID(kind: .d3dmetal, version: version)
            let root = paths.renderer(id)
            if fm.fileExists(atPath: root.path) {
                guard replace else { throw OssoverError.alreadyExists("renderer \(id) at \(root.path) (pass replace to reimport)") }
                try await requireNotInUse(packID: id, root: root, force: force)
            }

            let stage = Self.stagingDirectory(for: id, under: paths.renderers)
            staging = stage
            try? fm.removeItem(at: stage)
            let staged = try await Self.stageGPTK(redistLib: redistLib, into: stage, id: id, version: version, dmg: dmg, log: log)

            var record = staged.record
            if let previous = licenceRecord(for: id), previous.source.sha256 == dmgSHA, let accepted = previous.acceptedAt {
                record.acceptedAt = accepted   // the same bytes, already accepted once
            }
            try record.save(to: licenceRecordURL(for: id))

            if replace, fm.fileExists(atPath: root.path) {
                try await requireNotInUse(packID: id, root: root, force: force)
                do {
                    try fm.removeItem(at: root)
                } catch {
                    throw OssoverError.io("cannot remove the previous \(root.path): \(error.localizedDescription)")
                }
            }
            do {
                try fm.moveItem(at: stage, to: root)
            } catch {
                throw OssoverError.io("cannot move \(stage.lastPathComponent) to \(root.path): \(error.localizedDescription)")
            }
            staging = nil
            for mount in mounted.reversed() { await DiskImage.detach(mount) }
            let pack = try RendererPack.load(root: root)
            log?("imported renderer \(pack.id) at \(pack.root.path); run `ossover renderer accept \(pack.id)` to enable it")
            return pack
        } catch {
            if let staging { try? fm.removeItem(at: staging) }
            for mount in mounted.reversed() { await DiskImage.detach(mount) }
            throw error
        }
    }

    /// The names under `external/` a GPTK import must find and verify.
    public static let gptkExternalFiles = [gptkSharedLibraryName, "D3DMetal.framework"]

    /// Stages a D3DMetal pack from a mounted toolkit's `redist/lib` into `stage` (created here):
    /// copies `external/` and `wine/` verbatim, recreates the `x86_64-unix/*.so` links exactly as
    /// the toolkit has them, checks the copy against the source byte for byte and link for link,
    /// verifies that `libd3dshared.dylib` and `D3DMetal.framework` pass `codesign --verify
    /// --strict` and satisfy `anchor apple` (through `inspect`), and writes `manifest.json`.
    /// Returns the manifest and the licence record (not yet saved). The pack's `overrides` are
    /// empty: a prepended overlay wins by DLL path, CrossOver uses no `WINEDLLOVERRIDES` for any
    /// backend (REA L-05, L-20, L-26; decisions 14, 39).
    public static func stageGPTK(redistLib: URL, into stage: URL, id: String, version: String, dmg: ImportedArtifact,
                                 inspect: SignatureInspector = CodeSign.inspect, log: Log? = nil) async throws
        -> (manifest: RendererPackManifest, record: LicenceRecord) {
        let fm = FileManager.default
        let external = redistLib.appending(path: externalDirectoryName, directoryHint: .isDirectory)
        let wine = redistLib.appending(path: wineDirectoryName, directoryHint: .isDirectory)
        for required in gptkExternalFiles where !fm.fileExists(atPath: external.appending(path: required).path) {
            throw OssoverError.missing("\(required) in \(external.path)")
        }
        let stagedExternal = stage.appending(path: externalDirectoryName, directoryHint: .isDirectory)
        let stagedWine = stage.appending(path: wineDirectoryName, directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            log?("copying external/ and wine/ verbatim")
            try fm.copyItem(at: external, to: stagedExternal)
            try fm.copyItem(at: wine, to: stagedWine)
        } catch let error as OssoverError {
            throw error
        } catch {
            throw OssoverError.io("cannot copy the toolkit into \(stage.path): \(error.localizedDescription)")
        }
        let links = try recreateUnixLinks(from: wine, to: stagedWine)
        if links.isEmpty {
            log?("note: the toolkit's \(EngineArch.x86_64.unixLibDir)/ holds regular files, not links to \(gptkUnixLinkTarget)")
        } else {
            log?("\(EngineArch.x86_64.unixLibDir)/{\(links.keys.sorted().joined(separator: ","))} → \(Set(links.values).sorted().joined(separator: ", "))")
            for (name, target) in links.sorted(by: { $0.key < $1.key }) where target != gptkUnixLinkTarget {
                log?("warning: \(EngineArch.x86_64.unixLibDir)/\(name) links to \(target), not \(gptkUnixLinkTarget)")
            }
        }
        try EngineStore.requireNoEscapingSymlinks(under: stage, what: "renderer \(id)")
        let differing = try verbatimMismatches(source: external, copy: stagedExternal) + verbatimMismatches(source: wine, copy: stagedWine)
        guard differing.isEmpty else {
            throw OssoverError.invalid("renderer \(id): the copy is not verbatim: " + differing.prefix(5).joined(separator: ", ")
                                       + (differing.count > 5 ? " (+\(differing.count - 5))" : ""))
        }
        try await EngineStore.stripQuarantine(stage, log: log)

        try normalizeLayout(in: stagedWine)
        let layout = layout(ofWineDir: stagedWine)
        guard !layout.pe.isEmpty else { throw OssoverError.missing("no DLLs under \(wine.path)/\(EngineArch.x86_64.pe64LibDir)") }

        log?("verifying code signatures (codesign --verify --strict, anchor apple)")
        var signatures: [SignedFile] = []
        for name in gptkExternalFiles {
            let relative = "\(externalDirectoryName)/\(name)"
            let signed = try await inspect(stage.appending(path: relative), relative)
            let chain = signed.authorities.joined(separator: " / ")
            guard signed.verified else { throw OssoverError.invalid("codesign rejected \(relative) (authorities: \(chain))") }
            guard signed.anchorApple == true else {
                throw OssoverError.invalid("\(relative) is not Apple-signed (anchor apple failed; authorities: \(chain)); ossover only imports the toolkit as Apple ships it")
            }
            log?("\(relative): \(signed.identifier ?? "?") signed by \(chain)")
            signatures.append(signed)
        }
        let shared = signatures[0]
        for name in layout.unix {
            let relative = "\(wineDirectoryName)/\(EngineArch.x86_64.unixLibDir)/\(name)"
            if links[name] != nil {
                // A link to libd3dshared.dylib carries that file's signature; recorded as such.
                signatures.append(SignedFile(path: relative, identifier: shared.identifier, authorities: shared.authorities,
                                             verified: shared.verified, anchorApple: shared.anchorApple))
            } else {
                let signed = try await inspect(stage.appending(path: relative), relative)
                if !signed.verified || signed.anchorApple != true { log?("warning: \(relative) is not Apple-signed (\(signed.authorities.joined(separator: " / ")))") }
                signatures.append(signed)
            }
        }

        let builtinMarked = layout.pe.first.flatMap { isBuiltinMarked(stagedWine.appending(path: "\(EngineArch.x86_64.pe64LibDir)/\($0)")) } ?? false
        let linkNote = links.isEmpty
            ? "\(EngineArch.x86_64.unixLibDir)/ holds regular files (this toolkit ships no links)."
            : "\(EngineArch.x86_64.unixLibDir)/{\(links.keys.sorted().joined(separator: ","))} are symbolic links to \(Set(links.values).sorted().joined(separator: ", ")), kept as the toolkit has them (REA L-55)."
        let manifest = RendererPackManifest(
            id: id, kind: .d3dmetal, version: version, source: nil, builtinMarked: builtinMarked,
            requires: RendererRequires(wineMin: nil, macdrvExports: true),
            layout: layout,
            overrides: [],
            notes: [
                "Imported from \(dmg.fileName) (sha256 \(dmg.sha256)); never redistributed.",
                "Copied verbatim from redist/lib/{external,wine}; signed by \(shared.authorities.joined(separator: " / ")) (anchor apple verified with codesign --verify --strict; REA L-75); never re-signed, stripped or install-name-rewritten. See licenses/\(LicenceRecord.fileName(forPack: id)).",
                linkNote,
                "Activation (REA L-53, L-55; decision 14): overlay prepended with WINEDLLPATH_PREPEND (strategy C; capability dllPathPrepend), CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal and CX_APPLEGPTK_LIBD3DSHARED_PATH=<pack>/external/\(gptkSharedLibraryName); no WINEDLLOVERRIDES (decision 39). Needs an engine with d3dmetalHost and dllPathPrepend; macOS 14 or later (REA L-62).",
                "Usable only after `ossover renderer accept \(id)`.",
            ])
        try manifest.validate()
        try manifest.save(to: stage.appending(path: RendererPack.manifestFileName))

        let record = LicenceRecord(packID: id, source: dmg, signatures: signatures,
                                   notes: ["Apple Game Porting Toolkit software licence agreement; acceptedAt is set by `ossover renderer accept`."])
        return (manifest, record)
    }

    /// Records the user's acceptance of the licence a pack is gated behind.
    @discardableResult
    public func accept(_ id: String) throws -> LicenceRecord {
        let pack = try pack(id)
        guard pack.kind.needsLicence else {
            throw OssoverError.invalid("renderer \(id) (\(pack.kind.displayName)) needs no licence acceptance")
        }
        let url = licenceRecordURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OssoverError.missing("licence record \(url.path); import the GPTK dmg again")
        }
        var record = try LicenceRecord.load(from: url)
        if record.isAccepted { return record }
        record.accept()
        try record.save(to: url)
        return record
    }

    /// `redist/lib` (holding `external/` and `wine/`) below `root`, searched a few levels deep.
    public static func findRedistLib(under root: URL, maxDepth: Int = 4) -> URL? {
        let fm = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        func qualifies(_ lib: URL) -> Bool {
            isDirectory(lib.appending(path: externalDirectoryName)) && isDirectory(lib.appending(path: wineDirectoryName))
        }
        for candidate in [root.appending(path: "redist/lib"), root.appending(path: "lib")] where qualifies(candidate) {
            return candidate
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "lib", url.deletingLastPathComponent().lastPathComponent == "redist",
                  isDirectory(url), qualifies(url) else { continue }
            return url
        }
        return nil
    }

    /// `.dmg` files below `root` (a GPTK download can nest the real image inside another).
    public static func nestedDiskImages(under root: URL, maxDepth: Int = 2) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "dmg", (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `CFBundleShortVersionString` (else `CFBundleVersion`) of `D3DMetal.framework`.
    public static func gptkVersion(frameworkDirectory: URL) -> String? {
        for relative in ["Resources/Info.plist", "Versions/A/Resources/Info.plist", "Versions/Current/Resources/Info.plist"] {
            let url = frameworkDirectory.appending(path: relative)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
                if let value = plist[key] as? String, Version(value) != nil { return value }
            }
        }
        return nil
    }

    /// The first dotted number in a file name (`Game_Porting_Toolkit_3.0.dmg` → `3.0`). Pure.
    public static func version(fromFileName name: String) -> String? {
        guard let range = name.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    /// `<kind>-<version>` with anything a directory name cannot hold replaced by `-`. Pure.
    public static func packID(kind: RendererKind, version: String) -> String {
        let safe = String(version.map { ch -> Character in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") ? ch : "-"
        })
        return "\(kind.rawValue)-\(safe.isEmpty ? "unknown" : safe)"
    }

    /// `"d3d11,d3d12,dxgi=n,b"` for the Direct3D DLLs among `pe`, or nothing. Pure.
    public static func d3dOverrides(pe: [String]) -> [String] {
        let names = pe.map { ($0 as NSString).deletingPathExtension.lowercased() }.filter { d3dDLLNames.contains($0) }.sorted()
        return names.isEmpty ? [] : [names.joined(separator: ",") + "=n,b"]
    }

    /// Sorted file names with `extension` directly in `directory` (symlinks included), none when absent.
    static func fileNames(in directory: URL, extension ext: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { $0.pathExtension.lowercased() == ext }.map(\.lastPathComponent).sorted()
    }

    // MARK: Remove

    /// Deletes `renderers/<id>`. The licence record stays, so a re-import of the same dmg does not
    /// ask for acceptance again.
    public func remove(_ id: String) throws {
        let pack = try pack(id)
        do {
            try FileManager.default.removeItem(at: pack.root)
        } catch {
            throw OssoverError.io("cannot remove \(pack.root.path): \(error.localizedDescription)")
        }
    }
}
