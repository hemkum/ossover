// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A code signature as `codesign -d --verbose=2` reports it for one file of an imported pack.
public struct SignedFile: Codable, Equatable, Sendable {
    /// Path relative to the pack directory.
    public var path: String
    /// `Identifier=` line (`com.apple.D3DMetal`).
    public var identifier: String?
    /// `Authority=` lines, leaf first (`Software Signing`, `Apple Code Signing Certification Authority`, `Apple Root CA`).
    public var authorities: [String]
    /// Whether `codesign --verify --strict` accepted the file.
    public var verified: Bool
    /// Whether the signature satisfies the `anchor apple` requirement (Apple's own software-signing
    /// chain, what the GPTK's `libd3dshared`/`D3DMetal` carry: REA L-75); nil when not tested.
    public var anchorApple: Bool?

    public init(path: String, identifier: String? = nil, authorities: [String] = [], verified: Bool, anchorApple: Bool? = nil) {
        self.path = path
        self.identifier = identifier
        self.authorities = authorities
        self.verified = verified
        self.anchorApple = anchorApple
    }

    enum CodingKeys: String, CodingKey { case path, identifier, authorities, verified, anchorApple }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        authorities = try c.decodeIfPresent([String].self, forKey: .authorities) ?? []
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        anchorApple = try c.decodeIfPresent(Bool.self, forKey: .anchorApple)
    }
}

/// The file an import came from.
public struct ImportedArtifact: Codable, Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var size: Int64?

    public init(fileName: String, sha256: String, size: Int64? = nil) {
        self.fileName = fileName
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

/// `licenses/apple-gptk-<pack id>.json`: that a user imported Apple's Game Porting Toolkit and,
/// once `renderer accept` ran, that they accepted Apple's licence for it. A d3dmetal pack is
/// usable only with `acceptedAt` set (plan §4). ossover never downloads or redistributes the
/// toolkit; this record is the whole of its licence handling.
public struct LicenceRecord: Codable, Equatable, Sendable, SchemaDocument {
    public static let currentSchema = "ossover.licence/1"
    /// The licence id every GPTK import carries.
    public static let appleGPTK = "apple-gptk"

    public var schema: String
    /// `apple-gptk-<pack id>`, also the file name without `.json`.
    public var id: String
    /// Which licence this records (`apple-gptk`).
    public var licence: String
    /// The renderer pack the acceptance gates.
    public var packID: String
    public var source: ImportedArtifact
    public var importedAt: Date
    /// Nil until the user accepts; always written (as `null`) so the field is visible on disk.
    public var acceptedAt: Date?
    public var signatures: [SignedFile]
    public var notes: [String]

    public init(packID: String, licence: String = LicenceRecord.appleGPTK, source: ImportedArtifact,
                importedAt: Date = Date(), acceptedAt: Date? = nil, signatures: [SignedFile] = [], notes: [String] = []) {
        self.schema = Self.currentSchema
        self.id = Self.recordID(forPack: packID, licence: licence)
        self.licence = licence
        self.packID = packID
        self.source = source
        self.importedAt = importedAt.secondPrecision
        self.acceptedAt = acceptedAt?.secondPrecision
        self.signatures = signatures
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, licence
        case packID = "packId"
        case source, importedAt, acceptedAt, signatures, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        id = try c.decode(String.self, forKey: .id)
        licence = try c.decodeIfPresent(String.self, forKey: .licence) ?? Self.appleGPTK
        packID = try c.decode(String.self, forKey: .packID)
        source = try c.decode(ImportedArtifact.self, forKey: .source)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        acceptedAt = try c.decodeIfPresent(Date.self, forKey: .acceptedAt)
        signatures = try c.decodeIfPresent([SignedFile].self, forKey: .signatures) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(licence, forKey: .licence)
        try c.encode(packID, forKey: .packID)
        try c.encode(source, forKey: .source)
        try c.encode(importedAt, forKey: .importedAt)
        try c.encode(acceptedAt, forKey: .acceptedAt)   // null until accepted, on purpose
        try c.encode(signatures, forKey: .signatures)
        try c.encode(notes, forKey: .notes)
    }

    public var isAccepted: Bool { acceptedAt != nil }

    public mutating func accept(at date: Date = Date()) { acceptedAt = date.secondPrecision }

    /// `<licence>-<pack id>`.
    public static func recordID(forPack packID: String, licence: String = LicenceRecord.appleGPTK) -> String {
        "\(licence)-\(packID)"
    }

    /// `<licence>-<pack id>.json`.
    public static func fileName(forPack packID: String, licence: String = LicenceRecord.appleGPTK) -> String {
        recordID(forPack: packID, licence: licence) + ".json"
    }

    public func validate() throws {
        try validateSchema()
        guard EngineManifest.isValidID(packID) else { throw OssoverError.invalid("licence record: packId '\(packID)' is not valid") }
        guard ArtifactSource.isValidSHA256(source.sha256) else { throw OssoverError.invalid("licence record \(id): source.sha256 is not a SHA-256") }
    }

    public static func load(from url: URL) throws -> LicenceRecord {
        let record = try JSONDocument.load(LicenceRecord.self, from: url)
        try record.validate()
        return record
    }

    public func save(to url: URL) throws { try JSONDocument.save(self, to: url) }
}
