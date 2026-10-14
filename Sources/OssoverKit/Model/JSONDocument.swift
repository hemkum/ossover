// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A JSON document ossover writes to disk. Every one carries a `schema` string so a later build
/// can tell what it is reading before it tries.
public protocol SchemaDocument {
    /// The schema this build writes, e.g. `ossover.bottle/1`.
    static var currentSchema: String { get }
    /// The schema the document on disk declares.
    var schema: String { get }
}

extension SchemaDocument {
    /// Throws `OssoverError.unsupportedSchema` when the document was written by another schema.
    public func validateSchema() throws {
        guard schema == Self.currentSchema else {
            throw OssoverError.unsupportedSchema(found: schema, expected: Self.currentSchema)
        }
    }
}

extension Date {
    /// This date with fractional seconds dropped: what an ISO-8601 field on disk holds, so a
    /// document compares equal after a save/load round trip.
    public var secondPrecision: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// One JSON coder configuration for every on-disk document: ISO-8601 dates (whole seconds, UTC),
/// sorted keys, pretty output, slashes unescaped (URLs stay readable in a diff).
public enum JSONDocument {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decodes `data`, turning a `DecodingError` into a readable `OssoverError.invalid` that
    /// names the source and the offending key path.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, source: String = "JSON") throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw OssoverError.invalid("\(source): \(describe(error))")
        } catch let error as OssoverError {
            throw error
        } catch {
            throw OssoverError.invalid("\(source): \(error.localizedDescription)")
        }
    }

    /// Reads and decodes a file.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OssoverError.missing("\(url.path): \(error.localizedDescription)")
        }
        return try decode(type, from: data, source: url.lastPathComponent)
    }

    /// Reads, decodes and schema-checks a document.
    public static func loadDocument<T: Decodable & SchemaDocument>(_ type: T.Type, from url: URL) throws -> T {
        let document = try load(type, from: url)
        try document.validateSchema()
        return document
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try makeEncoder().encode(value)
        } catch {
            throw OssoverError.invalid("cannot encode \(T.self): \(error.localizedDescription)")
        }
    }

    /// Encodes and writes atomically, creating the parent directory when needed.
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encode(value)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw OssoverError.io("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// "missing key 'exe' at steps[3]" rather than Foundation's paragraph.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { key -> String in
                if let index = key.intValue { return "[\(index)]" }
                return key.stringValue
            }
            let joined = parts.reduce(into: "") { acc, part in
                if part.hasPrefix("[") || acc.isEmpty { acc += part } else { acc += "." + part }
            }
            return joined.isEmpty ? "top level" : joined
        }
        switch error {
        case let .keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case let .typeMismatch(type, context):
            return "expected \(type) at \(path(context)): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "null where \(type) expected at \(path(context))"
        case let .dataCorrupted(context):
            return "corrupt data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
