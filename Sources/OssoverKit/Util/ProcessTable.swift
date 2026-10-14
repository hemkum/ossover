// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/ProcessTable.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Darwin
import Foundation

/// One line of `ps -axwwE -o pid=,command=`: the pid, then the command line with the process's
/// environment appended as `KEY=VALUE` words (only for processes we own; others show no env).
public struct ProcessEntry: Sendable, Equatable, Hashable {
    public let pid: pid_t
    /// argv joined by spaces, followed by the environment words.
    public let command: String

    public init(pid: pid_t, command: String) {
        self.pid = pid
        self.command = command
    }

    /// The command line up to the first `KEY=VALUE` word: a best-effort split, since an argument
    /// may itself contain `=`. Good enough for display.
    public var commandWithoutEnvironment: String {
        guard let range = command.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) else { return command }
        return String(command[..<range.lowerBound])
    }
}

/// The processes of a Wine prefix as seen from outside, and how to end them. Wine hands its whole
/// Unix environment to every process it starts, so `WINEPREFIX=<path>` in the environment is the
/// mark of a prefix's process whatever its working directory. The environment alone is not
/// enough, though: a shell in which someone exported `WINEPREFIX` to poke at the prefix by hand
/// carries the same mark, so a prefix member must also look like a Wine process (its executable
/// under the engine, or a Wine loader/server/`.exe` name).
public enum ProcessTable {
    public static let psExecutable = "/bin/ps"
    public static let psArguments = ["-axww", "-E", "-o", "pid=,command="]
    /// Executable name suffixes of Wine's own processes (the loader in its CrossOver and
    /// upstream spellings, the server, the GStreamer scanner Wine spawns) and Windows programs.
    public static let wineExecutableSuffixes = [
        "/wine", "/wine64", "/wineloader", "/wineloader64", "/wine-preloader", "/wine64-preloader", "/wineserver",
        "/gst-plugin-scanner", ".exe",
    ]

    // MARK: Pure parsing

    /// Parses `ps` output; lines without a leading pid are skipped.
    public static func parse(_ output: String) -> [ProcessEntry] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.drop(while: { $0 == " " })
            guard let space = line.firstIndex(of: " "), let pid = pid_t(line[..<space]) else { return nil }
            let command = line[line.index(after: space)...].drop(while: { $0 == " " })
            return ProcessEntry(pid: pid, command: String(command))
        }
    }

    /// True when the entry's environment has `key=value` exactly: the word `KEY=value` followed
    /// by a space or the end of the line, so `.../bottles/a` does not match `.../bottles/ab`.
    /// A value with spaces (`Application Support`) still matches because the whole value is compared.
    public static func hasEnvironment(_ entry: ProcessEntry, key: String, value: String) -> Bool {
        let needle = " \(key)=\(value)"
        let text = " " + entry.command
        var search = text.startIndex
        while let range = text.range(of: needle, range: search..<text.endIndex) {
            if range.upperBound == text.endIndex || text[range.upperBound] == " " { return true }
            search = range.upperBound
        }
        return false
    }

    /// True when the command starts with `prefix` as a path: exactly it, or it followed by `/` or a space.
    public static func hasExecutablePrefix(_ entry: ProcessEntry, _ prefix: String) -> Bool {
        let path = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard entry.command.hasPrefix(path) else { return false }
        let rest = entry.command.dropFirst(path.count)
        return rest.isEmpty || rest.first == "/" || rest.first == " "
    }

    /// Entries whose environment names `prefix` as `WINEPREFIX`, in either spelling of the path
    /// (as given, and with symlinks such as `/tmp` → `/private/tmp` resolved), and that are Wine
    /// processes: executable under `engineRoot` when given, or a Wine-looking argv[0]
    /// (`isWineProcess`). A shell with `WINEPREFIX` exported is never a match.
    public static func filter(_ entries: [ProcessEntry], winePrefix prefix: URL, engineRoot: URL? = nil) -> [ProcessEntry] {
        let forms = pathForms(prefix)
        let engineForms = engineRoot.map(pathForms) ?? []
        return entries.filter { entry in
            guard forms.contains(where: { hasEnvironment(entry, key: "WINEPREFIX", value: $0) }) else { return false }
            return isWineProcess(entry) || engineForms.contains { hasExecutablePrefix(entry, $0) }
        }
    }

    /// True when argv[0] names a Wine loader, `wineserver` or the GStreamer scanner (a bare
    /// `wine`/`wineserver` counts too), or when the command line names a Windows program: a
    /// word ending in `.exe` — Wine rewrites argv[0] to the exe, and a loader's first argument
    /// is one, possibly with spaces in its path. Case-insensitive, pure.
    public static func isWineProcess(_ entry: ProcessEntry) -> Bool {
        let command = entry.commandWithoutEnvironment.lowercased()
        guard let first = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else { return false }
        let executable = String(first)
        if executable == "wine" || executable == "wine64" || executable == "wineserver" { return true }
        if wineExecutableSuffixes.contains(where: { executable.hasSuffix($0) }) { return true }
        return command.hasSuffix(".exe") || command.contains(".exe ")
    }

    /// Entries whose executable sits under `directory` (an engine's `bin/` or the engine root).
    public static func filter(_ entries: [ProcessEntry], executablePrefix directory: URL) -> [ProcessEntry] {
        let forms = pathForms(directory)
        return entries.filter { entry in forms.contains { hasExecutablePrefix(entry, $0) } }
    }

    static func pathForms(_ url: URL) -> [String] {
        let given = url.standardizedFileURL.path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return given == resolved ? [given] : [given, resolved]
    }

    // MARK: Live table

    /// Every process `ps` shows, minus ourselves.
    public static func list() async throws -> [ProcessEntry] {
        let result = try await Shell.run(executable: psExecutable, args: psArguments, timeout: 30)
        try result.check(command: Shell.commandLine(psExecutable, psArguments))
        let me = getpid()
        return parse(result.stdout).filter { $0.pid != me }
    }

    /// Pids of the Wine processes running in a prefix (see `filter(_:winePrefix:engineRoot:)`).
    public static func processes(ofPrefix prefix: URL, engineRoot: URL? = nil) async throws -> [pid_t] {
        filter(try await list(), winePrefix: prefix, engineRoot: engineRoot).map(\.pid)
    }

    /// Pids of the processes whose `WINEDLLPATH` or `WINEDLLPATH_PREPEND` lists `directory`
    /// (a renderer pack's `wine/` directory or its root): what `renderer install --replace`
    /// must not pull out from under a running game.
    public static func processes(usingDLLPath directory: URL) async throws -> [pid_t] {
        filter(try await list(), dllPath: directory).map(\.pid)
    }

    /// Entries whose `WINEDLLPATH`/`WINEDLLPATH_PREPEND` has `directory` (or something under it)
    /// as one `:`-separated component. Pure.
    public static func filter(_ entries: [ProcessEntry], dllPath directory: URL) -> [ProcessEntry] {
        let forms = pathForms(directory)
        return entries.filter { entry in
            for key in ["WINEDLLPATH", "WINEDLLPATH_PREPEND"] {
                for value in environmentValues(of: entry, key: key) {
                    for component in value.split(separator: ":").map(String.init) where forms.contains(where: {
                        component == $0 || component.hasPrefix($0 + "/")
                    }) { return true }
                }
            }
            return false
        }
    }

    /// Every ` KEY=<value>` word of the entry's text, the value running to the next ` NAME=`
    /// word or the end of the line (best effort, like `commandWithoutEnvironment`). Pure.
    public static func environmentValues(of entry: ProcessEntry, key: String) -> [String] {
        let text = " " + entry.command
        let needle = " \(key)="
        var values: [String] = []
        var search = text.startIndex
        while let range = text.range(of: needle, range: search..<text.endIndex) {
            let rest = text[range.upperBound...]
            let end = rest.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression)?.lowerBound ?? rest.endIndex
            values.append(String(rest[..<end]))
            search = range.upperBound
        }
        return values
    }

    /// Pids of the processes whose executable lives under `directory`.
    public static func processes(underExecutable directory: URL) async throws -> [pid_t] {
        filter(try await list(), executablePrefix: directory).map(\.pid)
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
    }

    /// SIGTERM, a grace period, then SIGKILL for whatever is left. Returns the pids that needed
    /// the hard way.
    @discardableResult
    public static func terminate(_ pids: [pid_t], grace: TimeInterval = 2) -> [pid_t] {
        let targets = pids.filter { $0 > 0 && $0 != getpid() }
        guard !targets.isEmpty else { return [] }
        for pid in targets { Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        var alive = targets
        while !alive.isEmpty && Date() < deadline {
            usleep(100_000)
            alive = alive.filter { Darwin.kill($0, 0) == 0 }
        }
        for pid in alive { Darwin.kill(pid, SIGKILL) }
        return alive
    }

    /// Command line and environment of a process we own, from `KERN_PROCARGS2` (exact, unlike the
    /// `ps` text). Nil when the kernel refuses (not ours) or the process is gone. Apple platform
    /// binaries report an empty environment; Wine's are not platform binaries.
    public static func commandLineAndEnvironment(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[MemoryLayout<Int32>.size...].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard argc >= 0, strings.count >= 1 + argc else { return nil }
        // Layout: executable path, argv[0..<argc], then the environment.
        let arguments = Array(strings[1..<(1 + argc)])
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(1 + argc) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (arguments, environment)
    }
}
