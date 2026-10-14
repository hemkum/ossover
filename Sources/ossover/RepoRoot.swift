// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OssoverKit

/// Where the repository checkout is: it holds the pinned manifests (`engines/*.json`,
/// `renderers/*.json`) and the recipes (`recipes/*.json`) that the CLI installs and applies by
/// id. Found from `$OSSOVER_REPO`, the working directory and its parents, or the directory the
/// `ossover` binary was built in (`.build-*/debug/ossover` sits inside the checkout).
enum RepoRoot {
    static let environmentKey = "OSSOVER_REPO"
    static let enginesDirectory = "engines"
    static let renderersDirectory = "renderers"
    static let recipesDirectory = "recipes"

    /// Whether `url` looks like the ossover checkout.
    static func isRepo(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.appending(path: "Package.swift").path) else { return false }
        guard fm.fileExists(atPath: url.appending(path: recipesDirectory).path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: url.appending(path: enginesDirectory).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Directories to try, in order (pure): the environment override, `cwd` and its parents,
    /// `executable`'s directory and its parents.
    static func candidates(environment: [String: String], cwd: URL, executable: URL?) -> [URL] {
        var out: [URL] = []
        if let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            out.append(URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true))
        }
        out += ancestors(of: cwd)
        if let executable { out += ancestors(of: executable.deletingLastPathComponent()) }
        return out
    }

    /// `url`, its parent, ... up to and including `/` (walked on path strings: URL's
    /// `deletingLastPathComponent()` turns `/` into `/..` and never stops).
    static func ancestors(of url: URL) -> [URL] {
        var out: [URL] = []
        var path = url.standardizedFileURL.path
        if path.isEmpty { path = "/" }
        while true {
            out.append(URL(fileURLWithPath: path, isDirectory: true))
            if path == "/" { break }
            let parent = (path as NSString).deletingLastPathComponent
            path = parent.isEmpty ? "/" : parent
        }
        return out
    }

    static func locate() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return candidates(environment: ProcessInfo.processInfo.environment, cwd: cwd, executable: executable).first(where: isRepo)
    }

    static func require() throws -> URL {
        guard let repo = locate() else {
            throw OssoverError.missing("the ossover repository (engines/, renderers/, recipes/): run from the checkout or set \(environmentKey)")
        }
        return repo
    }

    static func engines(in repo: URL) -> URL { repo.appending(path: enginesDirectory, directoryHint: .isDirectory) }
    static func renderers(in repo: URL) -> URL { repo.appending(path: renderersDirectory, directoryHint: .isDirectory) }
    static func recipes(in repo: URL) -> URL { repo.appending(path: recipesDirectory, directoryHint: .isDirectory) }
}

/// Resolves "a path or an id" arguments against the repository catalogs.
enum Catalog {
    static func isFile(_ reference: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL(reference).path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func fileURL(_ reference: String) -> URL {
        URL(fileURLWithPath: NSString(string: reference).expandingTildeInPath)
    }

    /// `engines/<id>.json` by file path or by manifest id / file stem.
    static func engineManifest(_ reference: String) throws -> EngineManifest {
        if isFile(reference) { return try EngineManifest.load(from: fileURL(reference)) }
        let repo = try RepoRoot.require()
        let catalog = try EngineStore.catalog(in: RepoRoot.engines(in: repo))
        if let manifest = catalog.first(where: { $0.id == reference }) { return manifest }
        let stem = RepoRoot.engines(in: repo).appending(path: reference + ".json")
        if FileManager.default.fileExists(atPath: stem.path) { return try EngineManifest.load(from: stem) }
        throw OssoverError.missing("engine '\(reference)': not a manifest file and not in \(RepoRoot.engines(in: repo).path) (ids: \(catalog.map(\.id).joined(separator: ", ")))")
    }

    static func rendererManifest(_ reference: String) throws -> RendererPackManifest {
        if isFile(reference) { return try RendererPackManifest.load(from: fileURL(reference)) }
        let repo = try RepoRoot.require()
        let catalog = try RendererStore.catalog(in: RepoRoot.renderers(in: repo))
        if let manifest = catalog.first(where: { $0.id == reference }) { return manifest }
        if let manifest = catalog.first(where: { $0.kind.rawValue == reference }) { return manifest }
        let stem = RepoRoot.renderers(in: repo).appending(path: reference + ".json")
        if FileManager.default.fileExists(atPath: stem.path) { return try RendererPackManifest.load(from: stem) }
        throw OssoverError.missing("renderer '\(reference)': not a manifest file and not in \(RepoRoot.renderers(in: repo).path) (ids: \(catalog.map(\.id).joined(separator: ", ")))")
    }

    /// Every recipe in `recipes/` (the `_schema.json` is skipped), with its file.
    static func recipes(in repo: URL) throws -> [(url: URL, recipe: Recipe)] {
        let directory = RepoRoot.recipes(in: repo)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw OssoverError.missing("\(directory.path): \(error.localizedDescription)")
        }
        return try entries
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, try Recipe.load(from: $0)) }
    }

    /// A recipe by file path, by id (`witcher3-4.04-dx11`) or by file stem (`witcher3`).
    static func recipe(_ reference: String) throws -> Recipe {
        if isFile(reference) { return try Recipe.load(from: fileURL(reference)) }
        let repo = try RepoRoot.require()
        let all = try recipes(in: repo)
        if let match = all.first(where: { $0.recipe.id == reference }) { return match.recipe }
        if let match = all.first(where: { $0.url.deletingPathExtension().lastPathComponent == reference }) { return match.recipe }
        throw OssoverError.missing("recipe '\(reference)': not a file and not in \(RepoRoot.recipes(in: repo).path) (ids: \(all.map(\.recipe.id).joined(separator: ", ")))")
    }
}
