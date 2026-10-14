// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Scripts/mark-builtin.py (GPL-3.0), Copyright © 2026 Gauthier Piarrette
// (the inverse of that script, plus detection).

import Foundation

/// Wine's "builtin DLL" mark in a PE file's DOS stub, and how to add or remove it.
///
/// `wineserver` (`server/mapping.c`, `get_image_params`) reads the 17 bytes right after the
/// 64-byte DOS header — offset `0x40` — and sets `IMAGE_FLAGS_WineBuiltin` when they are
/// `"Wine builtin DLL\0"`. Confirmed against CrossOver 26.3.0's overlay PEs, which carry
/// exactly this mark in the DOS stub and start with `MZ` at offset 0 — no prefix, unlike the
/// "16-byte prefix" wording of plan §4 (REA L-25; decision 15). The loader then never treats
/// that file as a native DLL: a marked file in `system32` is a redirect to whatever builtin of
/// that name the dll search path finds first (the engine's own `lib/wine` is always searched
/// before `WINEDLLPATH`, REA L-20), and `wineboot --update` overwrites it like any other fake
/// DLL. DXMT's release asset ships every PE marked (it targets `WINEDLLPATH_PREPEND` engines,
/// strategy C, where the mark is wanted), so under strategy B the materializer copies only the
/// Direct3D DLLs and strips the mark from each of them — nothing is ever copied marked, so
/// there is no "keep marked" set; `mark` is the inverse, for tests and for building strategy-C
/// overlays from unmarked DLLs.
public enum PEBuiltinMark {
    /// The text Wine looks for; the compared span includes its trailing NUL.
    public static let signature = "Wine builtin DLL"
    /// The sibling mark Wine's `fakedll` puts on placeholder DLLs (`IMAGE_FLAGS_WineFakeDll`).
    public static let placeholderSignature = "Wine placeholder DLL"
    /// Where the mark sits: right after `IMAGE_DOS_HEADER`.
    public static let offset = 0x40
    /// `signature` plus NUL.
    public static let length = signature.utf8.count + 1
    /// Offset of `e_lfanew` in the DOS header.
    static let lfanewOffset = 0x3C
    /// Enough of a file to decide: the DOS header, the mark and `e_lfanew`.
    static let headerProbeLength = 0x200

    /// Bytes of the mark as Wine compares them (17 bytes).
    public static var signatureBytes: [UInt8] { Array(signature.utf8) + [0] }

    // MARK: Pure

    /// `e_lfanew` of a PE image, or nil when `data` is not an `MZ` file with room for it.
    public static func peHeaderOffset(_ data: Data) -> Int? {
        guard data.count >= lfanewOffset + 4, data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A else { return nil }
        let base = data.startIndex + lfanewOffset
        let value = UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
        return Int(value)
    }

    /// True when the DOS stub has room for the mark (`e_lfanew >= 0x40 + 17`), as Wine requires.
    public static func hasRoom(_ data: Data) -> Bool {
        guard let lfanew = peHeaderOffset(data) else { return false }
        return lfanew >= offset + length && data.count >= offset + length
    }

    /// Whether the mark is present (and Wine would honour it).
    public static func isMarked(_ data: Data) -> Bool {
        guard hasRoom(data) else { return false }
        let start = data.startIndex + offset
        return Array(data[start..<(start + length)]) == signatureBytes
    }

    /// Whether the file carries Wine's placeholder ("fake dll") mark instead.
    public static func isPlaceholder(_ data: Data) -> Bool {
        let bytes = Array(placeholderSignature.utf8) + [0]
        guard let lfanew = peHeaderOffset(data), lfanew >= offset + bytes.count, data.count >= offset + bytes.count else { return false }
        let start = data.startIndex + offset
        return Array(data[start..<(start + bytes.count)]) == bytes
    }

    /// The image with the mark removed (the 17 bytes zeroed). Unmarked input comes back as is.
    /// Throws `.invalid` for something that is not a PE file.
    public static func strip(_ data: Data) throws -> Data {
        guard peHeaderOffset(data) != nil else { throw OssoverError.invalid("not a PE file (no MZ header)") }
        guard isMarked(data) else { return data }
        var out = data
        let start = out.startIndex + offset
        out.replaceSubrange(start..<(start + length), with: [UInt8](repeating: 0, count: length))
        return out
    }

    /// The image with the mark added. Throws `.invalid` when the DOS stub is too short for it.
    public static func mark(_ data: Data) throws -> Data {
        guard peHeaderOffset(data) != nil else { throw OssoverError.invalid("not a PE file (no MZ header)") }
        guard hasRoom(data) else { throw OssoverError.invalid("PE DOS stub too short for the builtin mark (e_lfanew < 0x51)") }
        guard !isMarked(data) else { return data }
        var out = data
        let start = out.startIndex + offset
        out.replaceSubrange(start..<(start + length), with: signatureBytes)
        return out
    }

    // MARK: Files

    /// Reads just the head of a file and says whether it is marked.
    public static func isMarked(file url: URL) throws -> Bool {
        try isMarked(readHead(of: url))
    }

    /// Copies `source` to `destination`, removing the mark on the way. Returns true when the
    /// source was marked. `destination`'s directory must exist; an existing file is replaced.
    @discardableResult
    public static func strip(file source: URL, to destination: URL) throws -> Bool {
        let data = try read(source)
        let marked = isMarked(data)
        try write(marked ? try strip(data) : data, to: destination)
        return marked
    }

    /// Adds the mark to a file in place (for tests and overlay builds). Returns true when it changed.
    @discardableResult
    public static func mark(file url: URL) throws -> Bool {
        let data = try read(url)
        guard !isMarked(data) else { return false }
        try write(try mark(data), to: url)
        return true
    }

    static func readHead(of url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw OssoverError.missing("\(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        do {
            return try handle.read(upToCount: headerProbeLength) ?? Data()
        } catch {
            throw OssoverError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw OssoverError.missing("\(url.path): \(error.localizedDescription)")
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw OssoverError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
    }
}
