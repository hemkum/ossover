// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A dotted numeric version ("11.16", "26.7.1", "0.80"), compared component-wise with missing
/// components read as zero, so "11.16" == "11.16.0" and "26.7.1" > "26.7". A leading
/// non-numeric prefix ("wine-11.16", "v1.4.2") is skipped; anything after the last numeric
/// component ("-beta.1") is ignored for ordering but kept in `description`.
public struct Version: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let components: [Int]
    public let text: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: \.isNumber) else { return nil }
        var parts: [Int] = []
        var current = ""
        var index = start
        loop: while index < trimmed.endIndex {
            let ch = trimmed[index]
            if ch.isNumber {
                current.append(ch)
            } else if ch == ".", !current.isEmpty {
                guard let n = Int(current) else { return nil }
                parts.append(n)
                current = ""
            } else {
                break loop
            }
            index = trimmed.index(after: index)
        }
        if !current.isEmpty, let n = Int(current) { parts.append(n) }
        guard !parts.isEmpty else { return nil }
        self.components = parts
        self.text = trimmed
    }

    public init(_ components: [Int]) {
        self.components = components
        self.text = components.map(String.init).joined(separator: ".")
    }

    public var description: String { text }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        // Trailing zeros do not change equality, so they must not change the hash.
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = Version(raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "not a version: '\(raw)'")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    /// This Mac's macOS version as "major.minor.patch".
    public static var currentMacOS: Version {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Version([v.majorVersion, v.minorVersion, v.patchVersion])
    }
}
