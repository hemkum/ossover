// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Manifest.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// How an archive is unpacked into its destination.
public struct ExtractSpec: Codable, Equatable, Sendable {
    /// Leading path components to drop (`tar --strip-components`). `Libraries/Wine/bin/wine`
    /// with `strip: 1` lands at `Wine/bin/wine`.
    public var strip: Int
    /// Destination relative to the owning directory (engine or renderer root). "." is the root.
    public var into: String

    public init(strip: Int = 0, into: String = ".") {
        self.strip = strip
        self.into = into
    }

    enum CodingKeys: String, CodingKey { case strip, into }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strip = try c.decodeIfPresent(Int.self, forKey: .strip) ?? 0
        into = try c.decodeIfPresent(String.self, forKey: .into) ?? "."
    }

    /// The directory the archive lands in, below `root`.
    public func destination(under root: URL) -> URL {
        let cleaned = into.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.isEmpty || cleaned == "." { return root }
        return root.appending(path: cleaned, directoryHint: .isDirectory)
    }

    public func validate() throws {
        guard strip >= 0 else { throw OssoverError.invalid("extract.strip must be >= 0") }
        guard !into.hasPrefix("/"), !into.split(separator: "/").contains("..") else {
            throw OssoverError.invalid("extract.into must be a relative path without '..': '\(into)'")
        }
    }
}

/// A pinned download: where it comes from, what it must hash to, and how it unpacks. Manifests
/// in the repo carry these; nothing binary is ever vendored.
public struct ArtifactSource: Codable, Equatable, Sendable {
    public var url: URL
    /// Lowercase hex SHA-256 of the archive as downloaded.
    public var sha256: String
    /// Size in bytes, when known (lets a download pre-check free space and show progress).
    public var size: Int64?
    /// SPDX-ish licence of the artifact ("LGPL-2.1-or-later", "MIT", "proprietary").
    public var license: String?
    public var extract: ExtractSpec?

    public init(url: URL, sha256: String, size: Int64? = nil, license: String? = nil, extract: ExtractSpec? = nil) {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.size = size
        self.license = license
        self.extract = extract
    }

    enum CodingKeys: String, CodingKey { case url, sha256, size, license, extract }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        extract = try c.decodeIfPresent(ExtractSpec.self, forKey: .extract)
    }

    /// Placeholder hash of a catalog entry that is not pinned yet (`"TBD"` in `engines/*.json`,
    /// lowercased on decode): the manifest lists and validates, and the stores refuse to install
    /// it until the real hash replaces the placeholder.
    public static let unpinnedSHA256 = "tbd"

    /// False while `sha256` is the `TBD` placeholder.
    public var isPinned: Bool { sha256 != Self.unpinnedSHA256 }

    /// 64 lowercase hex digits.
    public static func isValidSHA256(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The archive's file name as it lands in `downloads/`.
    public var fileName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? sha256 : name
    }

    public func validate() throws {
        guard !isPinned || Self.isValidSHA256(sha256) else { throw OssoverError.invalid("source.sha256 is not 64 lowercase hex digits (or TBD): '\(sha256)'") }
        if let size, size < 0 { throw OssoverError.invalid("source.size must be >= 0") }
        try extract?.validate()
    }
}
