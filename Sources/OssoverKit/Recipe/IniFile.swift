// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A line-preserving INI reader/writer for files like The Witcher 3's `user.settings`:
/// `[Section]` headers, `key=value` lines, comments (`;` or `#`) and anything else kept
/// verbatim. Only the lines a `set` touches are rewritten; every other byte, the line ending
/// (CRLF or LF), a UTF-8 BOM and the presence of a trailing newline survive a round trip.
///
/// Values are opaque text: `Resolution="2560x1600"` keeps its quotes on read and a value passed
/// to `set` is written exactly as given (quote it yourself when the game expects quotes).
/// Key and section names compare case-insensitively, as Windows does.
///
/// Section-agnostic updates: when `set(section:key:value:)` finds the key in another section
/// and not in the requested one, it updates the existing line in place instead of adding a
/// duplicate. The Witcher 3 `user.settings` section for `HairWorksLevel` is unverified (plan
/// §4), so a recipe that names the wrong section still edits the right line. A missing section
/// is appended at the end of the file.
public struct IniFile: Equatable, Sendable {
    /// One physical line of the file.
    public enum Line: Equatable, Sendable {
        /// `[name]`, raw text kept for the writer.
        case section(name: String, raw: String)
        /// `prefix` is everything up to and including `=` and the whitespace after it, so the
        /// original spacing is kept when the value changes.
        case keyValue(key: String, value: String, prefix: String)
        /// Blank line, comment, or anything that is neither a header nor `key=value`.
        case other(raw: String)

        /// The text of the line without its terminator.
        public var text: String {
            switch self {
            case let .section(_, raw): return raw
            case let .keyValue(_, value, prefix): return prefix + value
            case let .other(raw): return raw
            }
        }
    }

    public static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    public private(set) var lines: [Line]
    /// `"\r\n"` when the file used CRLF anywhere, else `"\n"`.
    public private(set) var lineEnding: String
    /// Whether the file ended with a line terminator.
    public private(set) var trailingNewline: Bool
    /// Whether the file began with a UTF-8 BOM (written back when true).
    public private(set) var hasBOM: Bool

    public init(lines: [Line] = [], lineEnding: String = "\n", trailingNewline: Bool = true, hasBOM: Bool = false) {
        self.lines = lines
        self.lineEnding = lineEnding
        self.trailingNewline = trailingNewline
        self.hasBOM = hasBOM
    }

    // MARK: Parsing

    /// Parses INI text. Never fails: anything unrecognised becomes an `other` line.
    public init(text: String) {
        var body = text
        var bom = false
        if body.hasPrefix("\u{FEFF}") {
            bom = true
            body.removeFirst()
        }
        let crlf = body.contains("\r\n")
        let ending = crlf ? "\r\n" : "\n"
        // `"\r\n"` is one Character in Swift, so test the detected ending, not "\n".
        let endsWithNewline = body.hasSuffix(ending)
        var raws = body.isEmpty ? [] : body.components(separatedBy: ending)
        if endsWithNewline, raws.last == "" { raws.removeLast() }
        self.init(lines: raws.map(Self.parseLine), lineEnding: ending, trailingNewline: endsWithNewline || body.isEmpty, hasBOM: bom)
    }

    /// Decodes `data` as UTF-8 (lossily for a stray non-UTF-8 byte) and parses it.
    public init(data: Data) {
        var bytes = data
        var bom = false
        if bytes.starts(with: Self.utf8BOM) {
            bom = true
            bytes = bytes.dropFirst(Self.utf8BOM.count)
        }
        self.init(text: String(decoding: bytes, as: UTF8.self))
        hasBOM = bom
    }

    /// Reads a file; a missing file yields an empty document (so `set` + `save` creates it).
    public static func load(from url: URL) throws -> IniFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return IniFile() }
        do {
            return IniFile(data: try Data(contentsOf: url))
        } catch {
            throw OssoverError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    static func parseLine(_ raw: String) -> Line {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            return .section(name: name, raw: raw)
        }
        if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.isEmpty { return .other(raw: raw) }
        guard let eq = raw.firstIndex(of: "=") else { return .other(raw: raw) }
        let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return .other(raw: raw) }
        var valueStart = raw.index(after: eq)
        while valueStart < raw.endIndex, raw[valueStart] == " " || raw[valueStart] == "\t" {
            valueStart = raw.index(after: valueStart)
        }
        return .keyValue(key: key, value: String(raw[valueStart...]), prefix: String(raw[..<valueStart]))
    }

    // MARK: Rendering

    /// The file's text, with the original line ending and trailing-newline state.
    public func render() -> String {
        var out = hasBOM ? "\u{FEFF}" : ""
        out += lines.map(\.text).joined(separator: lineEnding)
        if trailingNewline, !lines.isEmpty { out += lineEnding }
        return out
    }

    public func data() -> Data { Data(render().utf8) }

    /// Writes atomically, creating the parent directory.
    public func save(to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data().write(to: url, options: .atomic)
        } catch {
            throw OssoverError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: Queries

    /// Section names in file order (duplicates kept).
    public var sections: [String] {
        lines.compactMap { if case let .section(name, _) = $0 { return name } else { return nil } }
    }

    /// The value of `key` in `section` (case-insensitive), nil when absent.
    public func value(section: String, key: String) -> String? {
        guard let index = index(ofKey: key, inSection: section) else { return nil }
        if case let .keyValue(_, value, _) = lines[index] { return value }
        return nil
    }

    /// The value of the first `key` anywhere in the file, whatever its section.
    public func value(key: String) -> String? {
        guard let index = index(ofKey: key) else { return nil }
        if case let .keyValue(_, value, _) = lines[index] { return value }
        return nil
    }

    /// Strips one pair of surrounding double quotes: `"2560x1600"` → `2560x1600`.
    public static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: Mutation

    /// Sets `key=value`. Resolution order:
    /// 1. the key inside `section` → updated in place;
    /// 2. the key in any other section (or before the first header) → updated in place
    ///    (section-agnostic; see the type comment);
    /// 3. otherwise appended to `section`, which is created at the end of the file when missing.
    ///
    /// With `section == nil`, step 1 is skipped and a new key goes into the first section, or
    /// at the top of a file that has none.
    /// Returns true when a line changed (false when the value was already there).
    @discardableResult
    public mutating func set(section: String?, key: String, value: String) -> Bool {
        if let section, let index = index(ofKey: key, inSection: section) {
            return replaceValue(at: index, with: value)
        }
        if let index = index(ofKey: key) {
            return replaceValue(at: index, with: value)
        }
        let target = section ?? sections.first
        let line = Line.keyValue(key: key, value: value, prefix: key + "=")
        guard let target else {
            // No section anywhere: a flat file.
            lines.insert(line, at: 0)
            return true
        }
        if let header = index(ofSection: target) {
            lines.insert(line, at: insertionIndex(afterSectionAt: header))
        } else {
            if let last = lines.last, case .other(let raw) = last, raw.trimmingCharacters(in: .whitespaces).isEmpty {
                // Keep the file's blank line before a new header.
            } else if !lines.isEmpty {
                lines.append(.other(raw: ""))
            }
            lines.append(.section(name: target, raw: "[\(target)]"))
            lines.append(line)
        }
        return true
    }

    /// Removes every `key` line in `section`; returns how many were removed.
    @discardableResult
    public mutating func remove(section: String, key: String) -> Int {
        var removed = 0
        while let index = index(ofKey: key, inSection: section) {
            lines.remove(at: index)
            removed += 1
        }
        return removed
    }

    private mutating func replaceValue(at index: Int, with value: String) -> Bool {
        guard case let .keyValue(key, old, prefix) = lines[index] else { return false }
        guard old != value else { return false }
        lines[index] = .keyValue(key: key, value: value, prefix: prefix)
        return true
    }

    // MARK: Index helpers

    func index(ofSection name: String) -> Int? {
        lines.firstIndex { if case let .section(n, _) = $0 { return Self.same(n, name) } else { return false } }
    }

    /// Index of `key` within `section`: between its header and the next header.
    func index(ofKey key: String, inSection section: String) -> Int? {
        guard let header = index(ofSection: section) else { return nil }
        var i = header + 1
        while i < lines.count {
            switch lines[i] {
            case .section: return nil
            case let .keyValue(k, _, _) where Self.same(k, key): return i
            default: i += 1
            }
        }
        return nil
    }

    /// Index of the first `key` line anywhere.
    func index(ofKey key: String) -> Int? {
        lines.firstIndex { if case let .keyValue(k, _, _) = $0 { return Self.same(k, key) } else { return false } }
    }

    /// Where a new key goes in the section whose header is at `header`: after its last
    /// non-blank line, so a blank line that separates sections stays at the end.
    func insertionIndex(afterSectionAt header: Int) -> Int {
        var end = header + 1
        var lastContent = header
        while end < lines.count {
            if case .section = lines[end] { break }
            if case let .other(raw) = lines[end], raw.trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
                continue
            }
            lastContent = end
            end += 1
        }
        return lastContent + 1
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}
