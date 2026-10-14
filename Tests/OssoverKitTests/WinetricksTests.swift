// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// The vendored winetricks: pinned hash, first-use copy into `<home>/tools/`, and refusal of
/// anything that is not the pinned script.
@Suite struct WinetricksTests {
    static let vendored = Fixtures.repoRoot.appending(path: Winetricks.vendorRelativePath)

    /// A fake checkout under `home/repo` with `scripts/vendor/winetricks` holding `contents`.
    static func fakeRepo(in home: URL, contents: String?) throws -> URL {
        let repo = home.appending(path: "repo", directoryHint: .isDirectory)
        let script = repo.appending(path: Winetricks.vendorRelativePath)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents { try Data(contents.utf8).write(to: script) }
        return repo
    }

    @Test("the pinned hash, scripts/vendor/winetricks.sha256 and the vendored file agree")
    func pinnedHashMatchesTheVendoredScript() throws {
        let sums = try SHA256Hasher.parseSums(String(contentsOf: Fixtures.repoRoot.appending(path: Winetricks.vendorSHA256RelativePath), encoding: .utf8))
        #expect(sums.count == 1)
        #expect(sums.first?.path.hasSuffix(Winetricks.scriptName) == true)
        #expect(sums.first?.sha256 == Winetricks.pinnedSHA256)
        #expect(try SHA256Hasher.hex(ofFile: Self.vendored) == Winetricks.pinnedSHA256)
        #expect(Winetricks.pinnedSHA256.count == 64 && Winetricks.pinnedCommit.count == 40)
        #expect(Winetricks.vendoredScript(repoRoot: Fixtures.repoRoot) == Self.vendored)
    }

    @Test("prepare copies the vendored script into tools/ once, verified, and reuses it")
    func prepareInstallsIntoTools() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let installed = Winetricks.installedScript(paths: paths)
        #expect(!FileManager.default.fileExists(atPath: installed.path))

        let first = try Winetricks.prepare(paths: paths, repoRoot: Fixtures.repoRoot, environment: [:])
        #expect(first == installed)
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try SHA256Hasher.hex(ofFile: installed) == Winetricks.pinnedSHA256)
        let mtime = try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date

        // Second use: the tools copy is taken as is, even with no checkout in sight.
        let empty = try Self.fakeRepo(in: home, contents: nil)
        #expect(try Winetricks.prepare(paths: paths, repoRoot: empty, environment: [:]) == installed)
        #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date == mtime)
        #expect(Winetricks.locate(paths: paths, repoRoot: empty, environment: [:]) == installed)
        #expect(Winetricks.candidates(paths: paths, repoRoot: Fixtures.repoRoot, environment: [Winetricks.environmentKey: "/x/wt"])
                == [URL(fileURLWithPath: "/x/wt"), installed, Self.vendored])
    }

    @Test("a tools/ copy that is not the pinned script is replaced from the checkout, or refused without one")
    func staleToolsCopy() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let installed = Winetricks.installedScript(paths: paths)
        try FileManager.default.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho stale\n".utf8).write(to: installed)
        let staleHash = try SHA256Hasher.hex(ofFile: installed)

        let empty = try Self.fakeRepo(in: home, contents: nil)
        #expect(throws: OssoverError.checksumMismatch(file: installed.path, expected: Winetricks.pinnedSHA256, actual: staleHash)) {
            try Winetricks.prepare(paths: paths, repoRoot: empty, environment: [:])
        }
        #expect(try SHA256Hasher.hex(ofFile: installed) == staleHash, "nothing to replace it with: left alone")

        #expect(try Winetricks.prepare(paths: paths, repoRoot: Fixtures.repoRoot, environment: [:]) == installed)
        #expect(try SHA256Hasher.hex(ofFile: installed) == Winetricks.pinnedSHA256)
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    @Test("a vendored script with another hash is refused and never copied")
    func wrongVendoredHash() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let repo = try Self.fakeRepo(in: home, contents: "#!/bin/sh\necho not winetricks\n")
        #expect(throws: OssoverError.self) { try Winetricks.prepare(paths: paths, repoRoot: repo, environment: [:]) }
        #expect(!FileManager.default.fileExists(atPath: Winetricks.installedScript(paths: paths).path))
        // With the matching hash the same fake installs: the pin is the only gate.
        let fakeHash = try SHA256Hasher.hex(ofFile: repo.appending(path: Winetricks.vendorRelativePath))
        let installed = try Winetricks.prepare(paths: paths, repoRoot: repo, environment: [:], expectedSHA256: fakeHash.uppercased())
        #expect(try SHA256Hasher.hex(ofFile: installed) == fakeHash)
    }

    @Test("OSSOVER_WINETRICKS wins verbatim; without any script the error says what to do")
    func explicitOverrideAndMissing() throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let own = home.appending(path: "my-winetricks")
        try Data("#!/bin/sh\n".utf8).write(to: own)
        #expect(try Winetricks.prepare(paths: paths, repoRoot: nil, environment: [Winetricks.environmentKey: own.path]) == own)
        #expect(!FileManager.default.fileExists(atPath: Winetricks.installedScript(paths: paths).path), "an explicit script is not copied")
        #expect(throws: OssoverError.missing("\(Winetricks.environmentKey)=\(home.path)/absent is not a readable file")) {
            try Winetricks.prepare(paths: paths, repoRoot: nil, environment: [Winetricks.environmentKey: home.path + "/absent"])
        }

        let empty = try Self.fakeRepo(in: home, contents: nil)
        do {
            _ = try Winetricks.prepare(paths: paths, repoRoot: empty, environment: [:])
            Issue.record("no script anywhere must throw")
        } catch let error as OssoverError {
            guard case let .missing(what) = error else {
                Issue.record("expected .missing, got \(error)")
                return
            }
            #expect(what.contains(Winetricks.pinnedCommit) && what.contains(Winetricks.environmentKey) && what.contains(paths.tools.path))
        }
        #expect(Winetricks.vendoredScript(repoRoot: empty) == nil)
        #expect(Winetricks.ancestors(of: URL(fileURLWithPath: "/a/b/c")).map(\.path) == ["/a/b/c", "/a/b", "/a", "/"])
    }
}
