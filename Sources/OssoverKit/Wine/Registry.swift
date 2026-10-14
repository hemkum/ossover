// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors (reg add/query)
// Adapted from highball Sources/HighballKit/WineRunner.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (regQuery parsing)

import Foundation

/// One registry value to write: `key` is a Windows registry path with a root abbreviation
/// (`HKCU\Software\Wine\Mac Driver`), `name` the value name (empty or `@` for the default value).
public struct RegistryEntry: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var type: RegistryValueType
    /// REG_SZ/REG_EXPAND_SZ text; REG_MULTI_SZ lines joined by `\n`; REG_DWORD/REG_QWORD decimal
    /// or `0x` hex; REG_BINARY hex digits (spaces or commas allowed).
    public var data: String

    public init(key: String, name: String, type: RegistryValueType = .string, data: String) {
        self.key = key
        self.name = name
        self.type = type
        self.data = data
    }

    public static func string(_ key: String, _ name: String, _ data: String) -> RegistryEntry {
        RegistryEntry(key: key, name: name, type: .string, data: data)
    }

    public static func dword(_ key: String, _ name: String, _ value: Int) -> RegistryEntry {
        RegistryEntry(key: key, name: name, type: .dword, data: String(value))
    }
}

/// `.reg` files for `regedit /S` (pure): "Windows Registry Editor Version 5.00", Windows line
/// endings, UTF-16LE with BOM as the format specifies, strings escaped, DWORDs as `dword:hex`.
public enum RegFile {
    public static let header = "Windows Registry Editor Version 5.00"
    public static let lineEnding = "\r\n"

    static let roots: [String: String] = [
        "HKCU": "HKEY_CURRENT_USER", "HKLM": "HKEY_LOCAL_MACHINE", "HKCR": "HKEY_CLASSES_ROOT",
        "HKU": "HKEY_USERS", "HKCC": "HKEY_CURRENT_CONFIG",
    ]

    /// `HKCU\X` → `HKEY_CURRENT_USER\X`; a full root is kept; separators normalised.
    public static func expandRoot(_ key: String) -> String {
        let normalized = WindowsPath.normalize(key)
        guard let slash = normalized.firstIndex(of: "\\") else {
            return roots[normalized.uppercased()] ?? normalized
        }
        let root = String(normalized[..<slash])
        let rest = normalized[slash...]
        return (roots[root.uppercased()] ?? root) + rest
    }

    /// Backslashes and quotes escaped as regedit reads them.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `"name"=...` for one value. Throws `.invalid` for data that does not fit the type.
    public static func valueLine(_ entry: RegistryEntry) throws -> String {
        let lhs = entry.name.isEmpty || entry.name == "@" ? "@" : "\"\(escape(entry.name))\""
        switch entry.type {
        case .string:
            return "\(lhs)=\"\(escape(entry.data))\""
        case .dword:
            guard let value = parseInteger(entry.data), value >= 0, value <= UInt64(UInt32.max) else {
                throw OssoverError.invalid("registry \(entry.key)\\\(entry.name): '\(entry.data)' is not a DWORD")
            }
            return "\(lhs)=dword:" + String(format: "%08x", UInt32(value))
        case .qword:
            guard let value = parseInteger(entry.data) else {
                throw OssoverError.invalid("registry \(entry.key)\\\(entry.name): '\(entry.data)' is not a QWORD")
            }
            return "\(lhs)=hex(b):" + hexList((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
        case .expandString:
            return "\(lhs)=hex(2):" + hexList(utf16Bytes(entry.data) + [0, 0])
        case .multiString:
            let lines = entry.data.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            var bytes: [UInt8] = []
            for line in lines {
                bytes += utf16Bytes(line)
                bytes += [0, 0]
            }
            bytes += [0, 0]
            return "\(lhs)=hex(7):" + hexList(bytes)
        case .binary:
            guard let bytes = parseHex(entry.data) else {
                throw OssoverError.invalid("registry \(entry.key)\\\(entry.name): '\(entry.data)' is not hex")
            }
            return "\(lhs)=hex:" + hexList(bytes)
        }
    }

    /// The whole file: header, then `[KEY]` blocks in first-seen order with their values.
    public static func render(_ entries: [RegistryEntry]) throws -> String {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for entry in entries {
            let key = expandRoot(entry.key)
            if grouped[key] == nil { order.append(key); grouped[key] = [] }
            grouped[key, default: []].append(try valueLine(entry))
        }
        var lines = [header, ""]
        for key in order {
            lines.append("[\(key)]")
            lines += grouped[key] ?? []
            lines.append("")
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    /// The bytes to write: UTF-16LE with BOM, what regedit reads for a "Version 5.00" file.
    public static func data(_ text: String) -> Data {
        var out = Data([0xFF, 0xFE])
        out.append(contentsOf: utf16Bytes(text))
        return out
    }

    /// Decimal or `0x` hex.
    public static func parseInteger(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return UInt64(trimmed.dropFirst(2), radix: 16) }
        return UInt64(trimmed)
    }

    static func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.filter { $0.isHexDigit }
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func hexList(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
    }

    static func utf16Bytes(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}

/// `wine reg` and `wine regedit` against a bottle's prefix.
public struct Registry: Sendable {
    public let runner: WineRunner

    public init(runner: WineRunner) { self.runner = runner }

    /// Where batch files are staged, as Wine sees it; `regedit` gets the Windows path.
    public static let tempWindowsDir = "C:\\windows\\temp"

    /// `reg add <key> /v <name> /t <type> /d <data> /f`.
    public func add(key: String, name: String, type: RegistryValueType = .string, data: String) async throws {
        try await runner.runToolChecked(["reg", "add", key, "/v", name, "/t", type.rawValue, "/d", data, "/f"])
    }

    public func add(_ entry: RegistryEntry) async throws {
        try await add(key: entry.key, name: entry.name, type: entry.type, data: entry.data)
    }

    /// `reg delete <key> /v <name> /f`; a value that is not there is not an error.
    public func delete(key: String, name: String) async throws {
        let result = try await runner.runTool(["reg", "delete", key, "/v", name, "/f"])
        if !result.succeeded, !result.combined.lowercased().contains("unable to find") {
            throw OssoverError.processFailed(command: "wine reg delete \(key) /v \(name) /f", status: result.status, output: result.combined)
        }
    }

    /// The value's data as `reg query` prints it (`y`, `0x60`), or nil when the value is absent.
    public func query(key: String, name: String) async throws -> String? {
        let result = try await runner.runTool(["reg", "query", key, "/v", name])
        guard result.succeeded else { return nil }
        return Self.parseQuery(result.stdout, name: name)?.value
    }

    /// A REG_DWORD as an integer (`reg query` prints it as `0x..`).
    public func queryInteger(key: String, name: String) async throws -> Int? {
        guard let text = try await query(key: key, name: name), let value = RegFile.parseInteger(text) else { return nil }
        return Int(value)
    }

    /// Parses one `reg query` output: the line `    <name>    REG_TYPE    <data>` (Wine separates
    /// the columns with four spaces; data may be empty). Pure.
    public static func parseQuery(_ output: String, name: String) -> (type: String, value: String)? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let fields = line.components(separatedBy: "    ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields[0].caseInsensitiveCompare(name) == .orderedSame || (fields[0] == "(Default)" && (name.isEmpty || name == "@")),
                  fields[1].hasPrefix("REG_") else { continue }
            let value = fields.dropFirst(2).joined(separator: "    ")
            return (fields[1], value)
        }
        return nil
    }

    /// Writes `entries` as a `.reg` file under `drive_c/windows/temp` and runs `regedit /S` on it.
    /// One Wine process for any number of values (a `reg add` per value costs a process each).
    public func apply(_ entries: [RegistryEntry]) async throws {
        guard !entries.isEmpty else { return }
        let text = try RegFile.render(entries)
        let fm = FileManager.default
        let dir = runner.layout.driveC.appending(path: "windows/temp", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(dir.path): \(error.localizedDescription)")
        }
        let fileName = "ossover-\(UUID().uuidString.lowercased()).reg"
        let file = dir.appending(path: fileName)
        do {
            try RegFile.data(text).write(to: file, options: .atomic)
        } catch {
            throw OssoverError.io("cannot write \(file.path): \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: file) }
        try await importFile(windowsPath: WindowsPath.join(Self.tempWindowsDir, fileName))
    }

    /// `regedit /S <windows path>`.
    public func importFile(windowsPath: String) async throws {
        try await runner.runToolChecked(["regedit", "/S", windowsPath])
    }
}
