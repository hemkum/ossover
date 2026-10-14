// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// SHA-256 of files and `SHA256SUMS` lists, streaming so a 500 MB engine tarball never sits in memory.
public enum SHA256Hasher {
    public static let defaultChunkSize = 1 << 20

    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex digest of a file, read in `chunkSize` pieces.
    public static func hex(ofFile url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw OssoverError.missing("\(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw OssoverError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `OssoverError.checksumMismatch` unless the file hashes to `expected`.
    public static func verify(file url: URL, expected: String) throws {
        let want = expected.lowercased()
        let have = try hex(ofFile: url)
        guard have == want else { throw OssoverError.checksumMismatch(file: url.lastPathComponent, expected: want, actual: have) }
    }

    // MARK: SHA256SUMS

    /// One line of a `SHA256SUMS` file.
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let sha256: String
        public init(path: String, sha256: String) {
            self.path = path
            self.sha256 = sha256.lowercased()
        }
    }

    /// Parses `shasum -a 256` output: `<hex>  <path>` per line (a `*` binary marker is accepted).
    /// Lines that do not fit are skipped; order is kept.
    public static func parseSums(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let space = line.firstIndex(of: " ") else { return nil }
            let hex = String(line[..<space]).lowercased()
            guard ArtifactSource.isValidSHA256(hex) else { return nil }
            var path = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("*") { path.removeFirst() }
            guard !path.isEmpty else { return nil }
            return Entry(path: path, sha256: hex)
        }
    }

    /// Renders entries in `shasum -a 256` format, sorted by path.
    public static func formatSums(_ entries: [Entry]) -> String {
        entries.sorted { $0.path < $1.path }.map { "\($0.sha256)  \($0.path)\n" }.joined()
    }

    /// Hashes every regular file below `root` (relative paths, sorted). Symlinks are skipped.
    public static func sums(ofTree root: URL, chunkSize: Int = defaultChunkSize) throws -> [Entry] {
        let fm = FileManager.default
        let base = root.standardizedFileURL
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.producesRelativePathURLs]) else {
            throw OssoverError.missing(base.path)
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            entries.append(Entry(path: url.relativePath, sha256: try hex(ofFile: url, chunkSize: chunkSize)))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Files under `root` whose hash differs from, or which are missing from, `expected`.
    public static func mismatches(under root: URL, expected: [Entry]) -> [Entry] {
        expected.filter { entry in
            let url = root.appending(path: entry.path)
            guard let have = try? hex(ofFile: url) else { return true }
            return have != entry.sha256
        }
    }
}
