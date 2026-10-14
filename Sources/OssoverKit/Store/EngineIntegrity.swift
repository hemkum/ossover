// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/EngineIntegrity.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// `SHA256SUMS` for an installed engine: every Mach-O file (the loader, `*.so`, `*.dylib`,
/// framework binaries) hashed at install time, so `engine verify` can tell a damaged engine (an
/// antivirus quarantine, a half-finished copy, a tampered binary) from a healthy one. PE DLLs
/// are not Mach-O and are left out: Wine itself checks those.
public enum EngineIntegrity {
    /// Thin and fat Mach-O magic numbers, in both byte orders.
    public static let machOMagics: Set<UInt32> = [0xfeed_face, 0xcefa_edfe, 0xfeed_facf, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca]

    /// True when `bytes` starts with a Mach-O or fat-binary magic. Pure.
    public static func isMachOMagic(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magic = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return machOMagics.contains(magic)
    }

    /// True when the file at `url` starts with a Mach-O magic (symlinks are followed).
    public static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return isMachOMagic(head)
    }

    /// Relative paths (sorted) of every regular, non-symlink Mach-O file below `root`.
    public static func binaryFiles(under root: URL) throws -> [String] {
        let fm = FileManager.default
        let base = root.standardizedFileURL
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.producesRelativePathURLs]) else {
            throw OssoverError.missing(base.path)
        }
        var found: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            if isMachO(url) { found.append(url.relativePath) }
        }
        return found.sorted()
    }

    /// Hashes every Mach-O file below `root`.
    public static func computeSums(root: URL) throws -> [SHA256Hasher.Entry] {
        try binaryFiles(under: root).map { path in
            SHA256Hasher.Entry(path: path, sha256: try SHA256Hasher.hex(ofFile: root.appending(path: path)))
        }
    }

    /// Writes `SHA256SUMS` (shasum format, paths relative to `root`) and returns the entries.
    /// `merging` adds entries the Mach-O pass does not produce — the packager's own sums for PE
    /// DLLs and data files (`engine/package.sh` hashes every regular file) — keeping only those
    /// whose file still exists and that the Mach-O pass did not hash itself (`merge(_:into:root:)`).
    @discardableResult
    public static func writeSums(root: URL, to file: URL, merging extra: [SHA256Hasher.Entry] = []) throws -> [SHA256Hasher.Entry] {
        let entries = merge(extra, into: try computeSums(root: root), root: root)
        do {
            try SHA256Hasher.formatSums(entries).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw OssoverError.io("cannot write \(file.path): \(error.localizedDescription)")
        }
        return entries
    }

    /// `computed` plus those of `extra` that name a file present under `root`, are not
    /// `manifest.json` or `SHA256SUMS` (both rewritten at install) and are not already in
    /// `computed`; sorted by path.
    public static func merge(_ extra: [SHA256Hasher.Entry], into computed: [SHA256Hasher.Entry], root: URL) -> [SHA256Hasher.Entry] {
        let excluded: Set<String> = [Engine.manifestFileName, Engine.sha256sumsFileName]
        var seen = Set(computed.map(\.path))
        var out = computed
        for entry in extra where !excluded.contains(entry.path) && !seen.contains(entry.path) {
            guard FileManager.default.fileExists(atPath: root.appending(path: entry.path).path) else { continue }
            seen.insert(entry.path)
            out.append(entry)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Outcome of re-hashing an engine against its `SHA256SUMS`.
    public struct Report: Sendable, Equatable {
        /// Entries the sums file lists.
        public let checked: Int
        /// Files whose hash no longer matches.
        public let changed: [String]
        /// Files the sums file lists that are gone.
        public let missing: [String]
        /// Mach-O files on disk that the sums file does not list (added after install).
        public let unlisted: [String]

        public init(checked: Int, changed: [String], missing: [String], unlisted: [String]) {
            self.checked = checked
            self.changed = changed
            self.missing = missing
            self.unlisted = unlisted
        }

        /// True when nothing changed or went missing (unlisted extras are reported, not failed).
        public var ok: Bool { changed.isEmpty && missing.isEmpty }

        public var summary: String {
            if ok { return "\(checked) files verified" + (unlisted.isEmpty ? "" : ", \(unlisted.count) unlisted") }
            return "\(changed.count) changed, \(missing.count) missing of \(checked)"
        }
    }

    /// Re-hashes the files `sumsFile` lists under `root`.
    public static func verify(root: URL, sumsFile: URL) throws -> Report {
        let text: String
        do {
            text = try String(contentsOf: sumsFile, encoding: .utf8)
        } catch {
            throw OssoverError.missing("\(sumsFile.path): \(error.localizedDescription)")
        }
        let expected = SHA256Hasher.parseSums(text)
        guard !expected.isEmpty else { throw OssoverError.invalid("\(sumsFile.path) lists no files") }
        let fm = FileManager.default
        var changed: [String] = []
        var missing: [String] = []
        for entry in expected {
            let url = root.appending(path: entry.path)
            guard fm.fileExists(atPath: url.path) else {
                missing.append(entry.path)
                continue
            }
            if (try? SHA256Hasher.hex(ofFile: url)) != entry.sha256 { changed.append(entry.path) }
        }
        let listed = Set(expected.map(\.path))
        let unlisted = (try? binaryFiles(under: root))?.filter { !listed.contains($0) } ?? []
        return Report(checked: expected.count, changed: changed, missing: missing, unlisted: unlisted)
    }
}
