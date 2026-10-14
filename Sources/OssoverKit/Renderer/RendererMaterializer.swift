// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Extensions/FileManager+Extensions.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors (replaceDLLs → system32/syswow64)

import Foundation

/// One file the materializer put into a prefix (strategy B), so it can be taken out again.
public struct PlacedFile: Codable, Equatable, Sendable {
    /// Relative to the bottle directory (`prefix/drive_c/windows/system32/d3d11.dll`).
    public var path: String
    /// SHA-256 of the placed file (after any mark strip), to tell our copy from a later replacement.
    public var sha256: String
    /// Absolute path of the pack file it came from.
    public var source: String
    public var markStripped: Bool
    /// Relative path of the original file moved aside (`…/d3d11.dll.ossover-orig`), when there was one.
    public var backup: String?

    public init(path: String, sha256: String, source: String, markStripped: Bool, backup: String? = nil) {
        self.path = path
        self.sha256 = sha256
        self.source = source
        self.markStripped = markStripped
        self.backup = backup
    }
}

/// `bottles/<name>/.renderer-state.json`: what strategy B placed in the prefix.
public struct RendererState: Codable, Equatable, Sendable, SchemaDocument {
    public static let currentSchema = "ossover.renderer-state/1"

    public var schema: String
    public var kind: RendererKind
    public var packID: String
    public var packRoot: String
    public var strategy: OverlayStrategy
    public var placed: [PlacedFile]
    public var appliedAt: Date

    public init(kind: RendererKind, packID: String, packRoot: String, strategy: OverlayStrategy, placed: [PlacedFile], appliedAt: Date = Date()) {
        self.schema = Self.currentSchema
        self.kind = kind
        self.packID = packID
        self.packRoot = packRoot
        self.strategy = strategy
        self.placed = placed
        self.appliedAt = appliedAt.secondPrecision
    }

    enum CodingKeys: String, CodingKey { case schema, kind, packID = "packId", packRoot, strategy, placed, appliedAt }

    public static func load(from url: URL) throws -> RendererState { try JSONDocument.loadDocument(RendererState.self, from: url) }
    public func save(to url: URL) throws { try JSONDocument.save(self, to: url) }
}

/// What a renderer adds to a launch environment: variables (`KEY+` keys append) and the
/// `WINEDLLOVERRIDES` fragments `WineEnvironment` folds in.
public struct EnvFragment: Sendable, Equatable {
    public let variables: [String: String]
    public let overrides: [String]

    public init(variables: [String: String], overrides: [String]) {
        self.variables = variables
        self.overrides = overrides
    }
}

/// The outcome of `RendererMaterializer.prepare`.
public struct Materialization: Sendable, Equatable {
    public let selection: RendererSelection
    public let fragment: EnvFragment
    /// Files now in the prefix (empty for strategies C and none).
    public let placed: [PlacedFile]
    public let notes: [String]

    public init(selection: RendererSelection, fragment: EnvFragment, placed: [PlacedFile], notes: [String]) {
        self.selection = selection
        self.fragment = fragment
        self.placed = placed
        self.notes = notes
    }
}

/// Puts a renderer pack in front of Wine's Direct3D for one bottle (plan §4 "Renderer overlay";
/// decisions 12–15, REA L-20, L-24, L-25, L-26, L-63).
///
/// - Strategy C (`engine.capabilities.dllPathPrepend`): environment only
///   (`WINEDLLPATH_PREPEND=<overlay>`); the builtin-marked overlay files win by path, the
///   prefix is never touched. CrossOver's own mechanism since CX 24 (L-26).
/// - Strategy B (bootstrap engines, `WINEDLLPATH` only): copy the pack's Direct3D DLLs
///   (`RendererStore.d3dDLLNames`: d3d9, d3d10, d3d10_1, d3d10core, d3d11, d3d12, dxgi,
///   whichever the pack carries) into `prefix/drive_c/windows/system32` (and `syswow64` for a
///   32-bit half) with the "Wine builtin DLL" mark stripped, so they load as native DLLs under
///   the `n,b` override. Nothing else is copied: a builtin-marked `winemetal.dll` in `system32`
///   is a no-op redirect to the engine's own builtin (`load_builtin` turns a marked file into
///   `LO_BUILTIN_NATIVE` and `find_builtin_dll` walks `dll_paths` from `dll_dir`, pairing the PE
///   and its `.so` from the same entry; L-20, L-25) and `wineboot --update` overwrites it as a
///   fake DLL; `nvapi64`/`nvngx` are the proprietary DLSS redirect and never land in a prefix
///   (L-63). The pack's `winemetal.{dll,so}` are reached through `WINEDLLPATH=<pack>/wine` only
///   on an engine whose `lib/wine` has no winemetal of its own (names absent from `lib/wine`
///   are all `WINEDLLPATH` serves); otherwise the engine's pair is in effect — an ABI coupling
///   `RendererResolver.winemetalCoupling` gates and `Materialization.notes` states. Placed
///   files are recorded in `.renderer-state.json` so the overlay is fully revertible (L-26).
/// - wined3d: nothing placed, and any earlier overlay is reverted.
public enum RendererMaterializer {
    public static let backupSuffix = ".ossover-orig"

    /// One file copy of a strategy-B plan.
    public struct Copy: Sendable, Equatable {
        public let source: URL
        public let destination: URL
        public let stripMark: Bool
        public init(source: URL, destination: URL, stripMark: Bool) {
            self.source = source
            self.destination = destination
            self.stripMark = stripMark
        }
    }

    // MARK: Pure planning

    /// The copies strategy B makes for `selection` into `layout`'s prefix: only the Direct3D
    /// DLLs of the pack's layout, every one with the mark stripped (a no-op on an unmarked
    /// file); empty for other strategies. 32-bit DLLs go to `syswow64` only when the pack has
    /// a `pe32` list.
    public static func plan(selection: RendererSelection, layout: BottleLayout) -> [Copy] {
        guard selection.strategy == .prefixCopy, let pack = selection.pack else { return [] }
        var copies = direct3DNames(pack.manifest.layout.pe).map { name in
            Copy(source: pack.peDir.appending(path: name), destination: layout.system32.appending(path: name), stripMark: true)
        }
        copies += direct3DNames(pack.manifest.layout.pe32 ?? []).map { name in
            Copy(source: pack.pe32Dir.appending(path: name), destination: layout.syswow64.appending(path: name), stripMark: true)
        }
        return copies
    }

    /// The file names among `names` that are Direct3D DLLs (`RendererStore.d3dDLLNames`), in order.
    public static func direct3DNames(_ names: [String]) -> [String] {
        names.filter { RendererStore.d3dDLLNames.contains(($0 as NSString).deletingPathExtension.lowercased()) }
    }

    /// Reasons `selection` cannot be materialised on `engine` (file presence is checked in
    /// `prepare`; the strategy-B winemetal gate hashes two files when both exist). D3DMetal is
    /// refused without `dllPathPrepend`: there is no environment-only activation (decision 14,
    /// REA L-20, L-53, L-55).
    public static func unmet(selection: RendererSelection, engine: Engine) -> [String] {
        var reasons: [String] = []
        if selection.kind == .d3dmetal {
            if !engine.capabilities.d3dmetalHost { reasons.append("engine \(engine.id) lacks capability d3dmetalHost") }
            if !engine.capabilities.dllPathPrepend { reasons.append(RendererResolver.d3dmetalPrependReason) }
            if selection.pack?.kind != .d3dmetal { reasons.append("D3DMetal needs a d3dmetal pack") }
        }
        if let pack = selection.pack {
            reasons += RendererResolver.unmet(pack: pack, engine: engine)
            if pack.kind != selection.kind { reasons.append("pack \(pack.id) is \(pack.kind.rawValue), not \(selection.kind.rawValue)") }
        }
        if selection.kind.needsPack, selection.pack == nil { reasons.append("\(selection.kind.displayName) needs a pack") }
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// Which `winemetal.so` a strategy-B DXMT launch runs against: the engine's own when its
    /// `lib/wine` ships one (a `WINEDLLPATH` entry never shadows `dll_dir`, REA L-20), else the
    /// pack's through `WINEDLLPATH`. Nil when the selection has no such coupling.
    public static func winemetalNote(selection: RendererSelection, engine: Engine) -> String? {
        guard selection.strategy == .prefixCopy, selection.kind == .dxmt, let pack = selection.pack else { return nil }
        let engineSO = engine.unixLibDir.appending(path: RendererResolver.winemetalUnixName)
        if FileManager.default.fileExists(atPath: engineSO.path) {
            return "winemetal.so in effect: \(engineSO.path) (the engine's own; the pack's unix half is not loaded)"
        }
        return "winemetal.so in effect: \(pack.unixDir.appending(path: RendererResolver.winemetalUnixName).path) (via WINEDLLPATH)"
    }

    /// The env fragment for `selection` (what `WineEnvironment` also computes).
    public static func fragment(selection: RendererSelection, engine: Engine, layout: BottleLayout, settings: BottleSettings) -> EnvFragment {
        EnvFragment(variables: WineEnvironment.rendererVariables(selection, engine: engine, layout: layout, settings: settings),
                    overrides: selection.overrides)
    }

    // MARK: Files

    public static func state(layout: BottleLayout) -> RendererState? {
        guard FileManager.default.fileExists(atPath: layout.rendererState.path) else { return nil }
        return try? RendererState.load(from: layout.rendererState)
    }

    /// Makes the prefix match `selection` and returns the env fragment. Idempotent: an overlay
    /// already in place (same pack, same hashes) is left alone; a different one is reverted first.
    public static func prepare(bottle: Bottle, layout: BottleLayout, engine: Engine, selection: RendererSelection) throws -> Materialization {
        let reasons = unmet(selection: selection, engine: engine)
        guard reasons.isEmpty else { throw OssoverError.unsupported(reasons.joined(separator: "; ")) }
        var notes: [String] = []
        if let pack = selection.pack {
            try pack.validateLayout()
            if selection.kind == .d3dmetal {
                // The GPTK layout (`RendererPack.gptkLinkIssues`; REA L-55): `external/` beside
                // `wine/`, every unix half a link to libd3dshared. A deviation is reported, not
                // refused — the files exist (`validateLayout`), only the shape is unexpected.
                let shared = pack.gptkSharedLibrary
                guard FileManager.default.fileExists(atPath: shared.path) else {
                    throw OssoverError.missing("D3DMetal pack \(pack.id): \(shared.path) (import the GPTK dmg again)")
                }
                notes += pack.gptkLinkIssues().map { "D3DMetal pack \(pack.id): \($0)" }
            }
        }
        let fragment = fragment(selection: selection, engine: engine, layout: layout, settings: bottle.settings)
        if let note = selection.note { notes.append(note) }
        if let note = winemetalNote(selection: selection, engine: engine) { notes.append(note) }

        let existing = state(layout: layout)
        guard selection.strategy == .prefixCopy, let pack = selection.pack else {
            if let existing, !existing.placed.isEmpty {
                let removed = try revert(layout: layout)
                notes.append("reverted the \(existing.kind.rawValue) overlay (\(removed.count) files) from the prefix")
            } else if existing != nil {
                try? FileManager.default.removeItem(at: layout.rendererState)
            }
            return Materialization(selection: selection, fragment: fragment, placed: [], notes: notes)
        }

        guard layout.prefixInitialised, FileManager.default.fileExists(atPath: layout.system32.path) else {
            throw OssoverError.missing("prefix \(layout.prefix.path) is not initialised (no system32); run wineboot first")
        }
        if let existing, existing.packRoot == pack.root.path, isIntact(existing, layout: layout) {
            notes.append("\(pack.id) overlay already in place")
            return Materialization(selection: selection, fragment: fragment, placed: existing.placed, notes: notes)
        }
        if let existing, !existing.placed.isEmpty {
            let removed = try revert(layout: layout)
            notes.append("replaced the \(existing.kind.rawValue) overlay (\(removed.count) files)")
        }

        var placed: [PlacedFile] = []
        for copy in plan(selection: selection, layout: layout) {
            placed.append(try place(copy, layout: layout))
        }
        let state = RendererState(kind: selection.kind, packID: pack.id, packRoot: pack.root.path, strategy: .prefixCopy, placed: placed)
        try state.save(to: layout.rendererState)
        notes.append("placed \(placed.count) files from \(pack.id) into the prefix (strategy B)")
        return Materialization(selection: selection, fragment: fragment, placed: placed, notes: notes)
    }

    /// Removes what strategy B placed and restores what it moved aside. Files someone replaced
    /// since (hash differs) are left and reported in the returned notes. Returns the removed paths.
    @discardableResult
    public static func revert(layout: BottleLayout) throws -> [String] {
        guard let state = state(layout: layout) else {
            try? FileManager.default.removeItem(at: layout.rendererState)
            return []
        }
        let fm = FileManager.default
        var removed: [String] = []
        for file in state.placed.reversed() {
            let url = layout.root.appending(path: file.path)
            if fm.fileExists(atPath: url.path) {
                let current = try? SHA256Hasher.hex(ofFile: url)
                if current == file.sha256 {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        throw OssoverError.io("cannot remove \(url.path): \(error.localizedDescription)")
                    }
                    removed.append(file.path)
                } else {
                    continue   // someone else's file now; leave it and its backup alone
                }
            }
            if let backup = file.backup {
                let backupURL = layout.root.appending(path: backup)
                if fm.fileExists(atPath: backupURL.path), !fm.fileExists(atPath: url.path) {
                    do {
                        try fm.moveItem(at: backupURL, to: url)
                    } catch {
                        throw OssoverError.io("cannot restore \(url.path): \(error.localizedDescription)")
                    }
                }
            }
        }
        do {
            try fm.removeItem(at: layout.rendererState)
        } catch {
            throw OssoverError.io("cannot remove \(layout.rendererState.path): \(error.localizedDescription)")
        }
        return removed
    }

    /// True when every recorded file is still there with the recorded hash.
    public static func isIntact(_ state: RendererState, layout: BottleLayout) -> Bool {
        state.placed.allSatisfy { file in
            (try? SHA256Hasher.hex(ofFile: layout.root.appending(path: file.path))) == file.sha256
        }
    }

    static func place(_ copy: Copy, layout: BottleLayout) throws -> PlacedFile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: copy.source.path) else { throw OssoverError.missing(copy.source.path) }
        let parent = copy.destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(parent.path): \(error.localizedDescription)")
        }
        var backup: String?
        if fm.fileExists(atPath: copy.destination.path) {
            let aside = URL(fileURLWithPath: copy.destination.path + backupSuffix)
            do {
                if fm.fileExists(atPath: aside.path) {
                    try fm.removeItem(at: copy.destination)   // an older backup stands; this copy is ours
                } else {
                    try fm.moveItem(at: copy.destination, to: aside)
                }
            } catch {
                throw OssoverError.io("cannot set aside \(copy.destination.path): \(error.localizedDescription)")
            }
            if fm.fileExists(atPath: aside.path) { backup = relative(aside, to: layout.root) }
        }
        var stripped = false
        if copy.stripMark {
            stripped = try PEBuiltinMark.strip(file: copy.source, to: copy.destination)
        } else {
            do {
                try fm.copyItem(at: copy.source, to: copy.destination)
            } catch {
                throw OssoverError.io("cannot copy \(copy.source.path) to \(copy.destination.path): \(error.localizedDescription)")
            }
        }
        return PlacedFile(path: relative(copy.destination, to: layout.root), sha256: try SHA256Hasher.hex(ofFile: copy.destination),
                          source: copy.source.path, markStripped: stripped, backup: backup)
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
