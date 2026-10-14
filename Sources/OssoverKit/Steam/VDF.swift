// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/SteamLibrary.swift (parseManifest) (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette

import Foundation

/// A value in Valve's KeyValues text format ("VDF"): what `appmanifest_<app>.acf` and
/// steamcmd's `app_info_print` are written in.
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object(VDFObject)

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var object: VDFObject? { if case let .object(o) = self { return o } else { return nil } }
}

public struct VDFEntry: Equatable, Sendable {
    public var key: String
    public var value: VDFValue

    public init(key: String, value: VDFValue) {
        self.key = key
        self.value = value
    }
}

/// An ordered list of `"key" value` pairs. Keys compare case-insensitively (Steam writes
/// `StateFlags` and `betakey` side by side and reads both ways).
public struct VDFObject: Equatable, Sendable {
    public var entries: [VDFEntry]

    public init(entries: [VDFEntry] = []) { self.entries = entries }

    public var keys: [String] { entries.map(\.key) }

    /// First value under `key`, case-insensitive.
    public subscript(key: String) -> VDFValue? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public func string(_ key: String) -> String? { self[key]?.string }
    public func object(_ key: String) -> VDFObject? { self[key]?.object }

    /// Depth-first search for the first object stored under `key` anywhere below this one.
    public func firstObject(named key: String) -> VDFObject? {
        for entry in entries {
            guard case let .object(child) = entry.value else { continue }
            if entry.key.caseInsensitiveCompare(key) == .orderedSame { return child }
            if let found = child.firstObject(named: key) { return found }
        }
        return nil
    }

    /// Depth-first search for the first string stored under `key` anywhere below this one.
    public func firstString(named key: String) -> String? {
        for entry in entries {
            switch entry.value {
            case let .string(s) where entry.key.caseInsensitiveCompare(key) == .orderedSame: return s
            case let .object(child):
                if let found = child.firstString(named: key) { return found }
            default: continue
            }
        }
        return nil
    }
}

/// Tokenizer and parser for KeyValues text. Tolerant of `//` comments and unquoted tokens.
public enum VDF {
    public enum Token: Equatable, Sendable {
        case open, close
        case text(String)
    }

    /// Splits `text` into tokens: `{`, `}`, quoted strings (with `\"`, `\\`, `\n`, `\t`
    /// escapes) and bare words. `//` starts a comment to the end of the line.
    public static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if ch == "{" { tokens.append(.open); i += 1; continue }
            if ch == "}" { tokens.append(.close); i += 1; continue }
            if ch == "\"" {
                var out = ""
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        switch chars[i + 1] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "\"": out.append("\"")
                        case "\\": out.append("\\")
                        default:
                            out.append("\\")
                            out.append(chars[i + 1])
                        }
                        i += 2
                    } else {
                        out.append(chars[i])
                        i += 1
                    }
                }
                i += 1 // closing quote (or end of text)
                tokens.append(.text(out))
                continue
            }
            var word = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "{", chars[i] != "}", chars[i] != "\"" {
                word.append(chars[i])
                i += 1
            }
            tokens.append(.text(word))
        }
        return tokens
    }

    /// Parses a whole document as a sequence of entries (`"AppState" { ... }`).
    public static func parse(_ text: String) throws -> VDFObject {
        let tokens = tokenize(text)
        var index = 0
        let root = try parseEntries(tokens, &index, topLevel: true)
        return root
    }

    /// Every object stored under `key` in `text`, in order, found by scanning the token stream
    /// for `"key" {`. Works on steamcmd's `app_info_print` output, whose console chatter before
    /// the KeyValues block would derail a whole-document parse.
    public static func objects(named key: String, in text: String) -> [VDFObject] {
        let tokens = tokenize(text)
        var found: [VDFObject] = []
        var i = 0
        while i + 1 < tokens.count {
            if case let .text(k) = tokens[i], k.caseInsensitiveCompare(key) == .orderedSame, tokens[i + 1] == .open {
                var index = i + 2
                if let object = try? parseEntries(tokens, &index, topLevel: false) {
                    found.append(object)
                    i = index
                    continue
                }
            }
            i += 1
        }
        return found
    }

    /// Parses entries until `}` (or the end at top level). `index` is left after the `}`.
    static func parseEntries(_ tokens: [Token], _ index: inout Int, topLevel: Bool) throws -> VDFObject {
        var entries: [VDFEntry] = []
        while index < tokens.count {
            switch tokens[index] {
            case .close:
                index += 1
                if topLevel { continue }   // stray close at top level: ignore
                return VDFObject(entries: entries)
            case .open:
                throw OssoverError.invalid("VDF: unexpected '{' at token \(index)")
            case let .text(key):
                index += 1
                guard index < tokens.count else {
                    throw OssoverError.invalid("VDF: key '\(key)' without a value")
                }
                switch tokens[index] {
                case .open:
                    index += 1
                    let child = try parseEntries(tokens, &index, topLevel: false)
                    entries.append(VDFEntry(key: key, value: .object(child)))
                case let .text(value):
                    index += 1
                    entries.append(VDFEntry(key: key, value: .string(value)))
                case .close:
                    throw OssoverError.invalid("VDF: key '\(key)' without a value")
                }
            }
        }
        guard topLevel else { throw OssoverError.invalid("VDF: unterminated object") }
        return VDFObject(entries: entries)
    }
}
