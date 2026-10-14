// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What an engine's binaries say about its capabilities, read at install time (plan §3 Phase 2,
/// §5 gates). A manifest states what the packager believes; the probe records what is there and
/// `EngineStore.install` keeps the probe's word, with a warning, when the two disagree.
///
/// Each field is nil when it could not be probed (a tool missing, a binary absent).
public struct EngineProbe: Sendable, Equatable {
    /// `strings ntdll.so | grep WINEMSYNC`.
    public var msync: Bool?
    /// `strings ntdll.so | grep WINEESYNC`.
    public var esync: Bool?
    /// `lib/wine/i386-windows` exists and `lib/wine/i386-unix` does not.
    public var wow64: Bool?
    /// `nm -gU winemac.so | grep macdrv_functions`.
    public var macdrvExports: Bool?
    /// `strings ntdll.so | grep -c WINEDLLPATH_PREPEND`.
    public var dllPathPrepend: Bool?
    /// `strings ntdll.so | grep CX_APPLEGPTK_LIBD3DSHARED_PATH` (the CrossOver D3DMetal loader hook).
    public var d3dmetalHost: Bool?
    /// `strings ntdll.so | grep -m1 -E 'wine-[0-9]+\.[0-9]+'`: the fork string the binary carries
    /// (`wine-11.16` on the bootstrap engine, `wine-11.0-8726-g2e2f5fca349` on a CrossOver 26.3
    /// build, REA L-45), read without executing Wine.
    public var wineVersionString: String?

    public init(msync: Bool? = nil, esync: Bool? = nil, wow64: Bool? = nil, macdrvExports: Bool? = nil,
                dllPathPrepend: Bool? = nil, d3dmetalHost: Bool? = nil, wineVersionString: String? = nil) {
        self.msync = msync
        self.esync = esync
        self.wow64 = wow64
        self.macdrvExports = macdrvExports
        self.dllPathPrepend = dllPathPrepend
        self.d3dmetalHost = d3dmetalHost
        self.wineVersionString = wineVersionString
    }

    public static let nmExecutable = "/usr/bin/nm"
    public static let stringsExecutable = "/usr/bin/strings"
    public static let macdrvFunctionsSymbol = "macdrv_functions"
    public static let dllPathPrependMarker = "WINEDLLPATH_PREPEND"
    public static let msyncMarker = "WINEMSYNC"
    public static let esyncMarker = "WINEESYNC"
    public static let d3dmetalHostMarker = "CX_APPLEGPTK_LIBD3DSHARED_PATH"
    /// The version token `ntdll.so` embeds: `wine-<major>.<minor>[.<patch>][-<n>-g<hash>…]`.
    /// `strings` glues adjacent printable runs together (`0123456789abcdefwine-11.16`), so the
    /// token is cut out of its line rather than taken whole.
    public static let wineVersionPattern = #"wine-[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)*"#
    public static let toolTimeout: TimeInterval = 120

    // MARK: Pure

    /// True when `nm -gU` output lists `symbol` (with or without the Mach-O underscore prefix).
    public static func exportsSymbol(_ symbol: String, nmOutput: String) -> Bool {
        nmOutput.split(separator: "\n").contains { line in
            guard let name = line.split(separator: " ", omittingEmptySubsequences: true).last else { return false }
            return name == Substring(symbol) || name == Substring("_" + symbol)
        }
    }

    /// Number of `strings` lines containing `marker`, what `grep -c` reports.
    public static func countOccurrences(of marker: String, in stringsOutput: String) -> Int {
        stringsOutput.split(separator: "\n").reduce(0) { $0 + ($1.contains(marker) ? 1 : 0) }
    }

    /// The first `wine-<version>` token in `strings` output (`grep -m1 -E 'wine-[0-9]+\.[0-9]+'`),
    /// nil when there is none. Pure.
    public static func wineVersionString(in stringsOutput: String) -> String? {
        for line in stringsOutput.split(separator: "\n") {
            if let range = line.range(of: wineVersionPattern, options: .regularExpression) { return String(line[range]) }
        }
        return nil
    }

    /// The first `wine-<version>` token in raw bytes: every `wine-` occurrence is extended over
    /// the printable ASCII run around it and matched like a `strings` line. Pure.
    public static func scanWineVersion(in data: Data) -> String? {
        let needle = Data("wine-".utf8)
        var searchStart = data.startIndex
        while searchStart < data.endIndex, let hit = data.range(of: needle, in: searchStart..<data.endIndex) {
            var end = hit.upperBound
            while end < data.endIndex, (0x21...0x7e).contains(data[end]) { end += 1 }
            let run = String(decoding: data[hit.lowerBound..<end], as: UTF8.self)
            if let found = wineVersionString(in: run) { return found }
            searchStart = hit.upperBound
        }
        return nil
    }

    /// One line when `probed` (the binary's fork string) and `declared` (the manifest's
    /// `wineVersion`) name different Wine releases on their first two components; nil when they
    /// agree or either cannot be parsed. The manifest keeps its value either way: the release
    /// number is a catalog fact, the fork string is what gets recorded beside it.
    public static func wineVersionDisagreement(probed: String?, declared: String) -> String? {
        guard let probed, let have = Version(probed), let want = Version(declared) else { return nil }
        let a = Array(have.components.prefix(2)), b = Array(want.components.prefix(2))
        guard a != b else { return nil }
        return "wineVersion: manifest says \(declared), ntdll.so says \(probed)"
    }

    /// `base` with every probed field replaced by what the binaries said.
    public func capabilities(over base: EngineCapabilities) -> EngineCapabilities {
        var result = base
        if let msync { result.msync = msync }
        if let esync { result.esync = esync }
        if let wow64 { result.wow64 = wow64 }
        if let macdrvExports { result.macdrvExports = macdrvExports }
        if let dllPathPrepend { result.dllPathPrepend = dllPathPrepend }
        if let d3dmetalHost { result.d3dmetalHost = d3dmetalHost }
        return result
    }

    /// One line per capability where the manifest and the binaries disagree.
    public func disagreements(with manifest: EngineCapabilities) -> [String] {
        let pairs: [(String, Bool?, Bool)] = [
            ("msync", msync, manifest.msync),
            ("esync", esync, manifest.esync),
            ("wow64", wow64, manifest.wow64),
            ("macdrvExports", macdrvExports, manifest.macdrvExports),
            ("dllPathPrepend", dllPathPrepend, manifest.dllPathPrepend),
            ("d3dmetalHost", d3dmetalHost, manifest.d3dmetalHost),
        ]
        return pairs.compactMap { name, detected, declared in
            guard let detected, detected != declared else { return nil }
            return "capability \(name): manifest says \(declared), binaries say \(detected); recording \(detected)"
        }
    }

    // MARK: Live

    /// Probes an engine's binaries. Never throws: a tool that cannot run leaves its field nil
    /// and a line in `log`.
    public static func detect(engine: Engine, log: (@Sendable (String) -> Void)? = nil) async -> EngineProbe {
        var probe = EngineProbe()
        let fm = FileManager.default
        let ntdll = engine.unixLibDir.appending(path: "ntdll.so")
        let winemac = engine.unixLibDir.appending(path: "winemac.so")

        probe.wow64 = fm.fileExists(atPath: engine.pe32LibDir.path)
            && !fm.fileExists(atPath: engine.libWine.appending(path: "i386-unix").path)

        if fm.fileExists(atPath: ntdll.path) {
            if let strings = await strings(of: ntdll, log: log) {
                probe.msync = countOccurrences(of: msyncMarker, in: strings) > 0
                probe.esync = countOccurrences(of: esyncMarker, in: strings) > 0
                probe.dllPathPrepend = countOccurrences(of: dllPathPrependMarker, in: strings) > 0
                probe.d3dmetalHost = countOccurrences(of: d3dmetalHostMarker, in: strings) > 0
                probe.wineVersionString = wineVersionString(in: strings)
                if probe.wineVersionString == nil { log?("warning: \(ntdll.path) carries no wine-<version> string") }
            }
        } else {
            log?("warning: \(ntdll.path) not found; msync/esync/dllPathPrepend/d3dmetalHost/wineVersionString not probed")
        }

        if fm.fileExists(atPath: winemac.path) {
            if let symbols = await exportedSymbols(of: winemac, log: log) {
                probe.macdrvExports = exportsSymbol(macdrvFunctionsSymbol, nmOutput: symbols)
            }
        } else {
            log?("warning: \(winemac.path) not found; macdrvExports not probed")
        }
        return probe
    }

    /// `nm -gU <file>` output, nil when nm is unavailable or fails.
    static func exportedSymbols(of file: URL, log: (@Sendable (String) -> Void)?) async -> String? {
        let args = ["-gU", file.path]
        do {
            let result = try await Shell.run(executable: nmExecutable, args: args, timeout: toolTimeout)
            guard result.succeeded else {
                log?("warning: \(Shell.commandLine(nmExecutable, args)) exited \(result.status): \(OssoverError.tail(of: result.combined, lines: 3))")
                return nil
            }
            return result.stdout
        } catch {
            log?("warning: cannot run nm: \(error.localizedDescription)")
            return nil
        }
    }

    /// `strings <file>` output; falls back to a plain byte scan rendered one marker per line
    /// when the tool is unavailable (Xcode command line tools not installed).
    static func strings(of file: URL, log: (@Sendable (String) -> Void)?) async -> String? {
        let args = [file.path]
        do {
            let result = try await Shell.run(executable: stringsExecutable, args: args, timeout: toolTimeout)
            if result.succeeded { return result.stdout }
            log?("warning: \(Shell.commandLine(stringsExecutable, args)) exited \(result.status); scanning bytes instead")
        } catch {
            log?("warning: cannot run strings (\(error.localizedDescription)); scanning bytes instead")
        }
        return scanMarkers(in: file)
    }

    /// The markers found by scanning the file's bytes, one per line (plus the `wine-<version>`
    /// token when there is one), so `countOccurrences` and `wineVersionString(in:)` work on it
    /// like on `strings` output.
    static func scanMarkers(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        var lines = [msyncMarker, esyncMarker, dllPathPrependMarker, d3dmetalHostMarker]
            .filter { data.range(of: Data($0.utf8)) != nil }
        if let version = scanWineVersion(in: data) { lines.append(version) }
        return lines.joined(separator: "\n")
    }
}
