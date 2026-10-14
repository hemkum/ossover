// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Tar.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors

import Foundation

/// `/usr/bin/tar` (bsdtar) for the archives ossover installs: gzip, xz, bzip2 or plain by extension.
public enum Tar {
    public static let executable = "/usr/bin/tar"

    public enum Compression: String, Sendable, Equatable {
        case gzip, xz, bzip2, none

        /// By file name: `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.bz2`/`.tbz2`, else plain.
        public static func detect(fileName: String) -> Compression {
            let lower = fileName.lowercased()
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .gzip }
            if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .xz }
            if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return .bzip2 }
            return .none
        }

        public static func detect(_ url: URL) -> Compression { detect(fileName: url.lastPathComponent) }

        /// The explicit tar flag; bsdtar also sniffs, but saying it keeps a mislabeled file honest.
        var flag: String? {
            switch self {
            case .gzip: return "-z"
            case .xz: return "-J"
            case .bzip2: return "-j"
            case .none: return nil
            }
        }
    }

    /// Arguments for `tar -t`. Pure, so the call is testable.
    public static func listArguments(archive: URL) -> [String] {
        var args = ["-t"]
        if let flag = Compression.detect(archive).flag { args.append(flag) }
        args += ["-f", archive.path]
        return args
    }

    /// Arguments for `tar -x`. Pure.
    public static func extractArguments(archive: URL, into destination: URL, stripComponents: Int) -> [String] {
        var args = ["-x"]
        if let flag = Compression.detect(archive).flag { args.append(flag) }
        args += ["-f", archive.path, "-C", destination.path]
        if stripComponents > 0 { args.append("--strip-components=\(stripComponents)") }
        return args
    }

    /// Entry paths inside the archive, in archive order.
    public static func list(_ archive: URL) async throws -> [String] {
        guard FileManager.default.fileExists(atPath: archive.path) else { throw OssoverError.missing(archive.path) }
        let args = listArguments(archive: archive)
        let result = try await Shell.run(executable: executable, args: args)
        try result.check(command: Shell.commandLine(executable, args))
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Unpacks `archive` into `destination` (created when missing), dropping `stripComponents`
    /// leading path components.
    public static func extract(_ archive: URL, into destination: URL, stripComponents: Int = 0) async throws {
        guard FileManager.default.fileExists(atPath: archive.path) else { throw OssoverError.missing(archive.path) }
        guard stripComponents >= 0 else { throw OssoverError.invalid("stripComponents must be >= 0") }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(destination.path): \(error.localizedDescription)")
        }
        let args = extractArguments(archive: archive, into: destination, stripComponents: stripComponents)
        let result = try await Shell.run(executable: executable, args: args)
        try result.check(command: Shell.commandLine(executable, args))
    }

    /// The single top-level directory every entry sits under, or nil when entries differ
    /// (what `stripComponents: 1` would remove).
    public static func commonTopLevel(of entries: [String]) -> String? {
        var top: String?
        for entry in entries {
            let trimmed = entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
            guard let first = trimmed.split(separator: "/", omittingEmptySubsequences: true).first else { continue }
            let name = String(first)
            if top == nil { top = name } else if top != name { return nil }
        }
        return top
    }
}
