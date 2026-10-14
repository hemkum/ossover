// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/Shell.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import Foundation

/// What a finished tool left behind.
public struct ShellResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    /// stdout then stderr, for error messages.
    public var combined: String { stdout + (stdout.isEmpty || stdout.hasSuffix("\n") ? "" : "\n") + stderr }

    /// Returns self when the status is 0, else throws `OssoverError.processFailed`.
    @discardableResult
    public func check(command: String) throws -> ShellResult {
        guard succeeded else { throw OssoverError.processFailed(command: command, status: status, output: combined) }
        return self
    }
}

/// Every shell-out in OssoverKit goes through here. The child never inherits our environment:
/// it gets a minimal PATH plus HOME/USER/TMPDIR, then whatever the caller passes, so a launch
/// is the same on every Mac and in every test (plan §4: deterministic env table).
public enum Shell {
    public static let minimalPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Parent variables that are carried over, because tools break without them.
    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"]

    /// The environment a child starts with: minimal PATH, the inherited few, then `extra` on top.
    public static func baseEnvironment(merging extra: [String: String] = [:]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = ["PATH": minimalPATH]
        for key in inheritedKeys {
            if let value = parent[key] { env[key] = value }
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// `"/usr/bin/tar -xf a.tar"` for messages and log headers.
    public static func commandLine(_ executable: String, _ args: [String]) -> String {
        ([executable] + args).map { arg in
            arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
        }.joined(separator: " ")
    }

    struct Spec: Sendable {
        let executable: String
        let args: [String]
        let env: [String: String]
        let cwd: URL?
        let timeout: TimeInterval?
        var commandLine: String { Shell.commandLine(executable, args) }
    }

    // MARK: Capture

    /// Runs a tool to completion and returns what it printed. Throws only when the tool cannot
    /// start or overruns `timeout`; a non-zero exit comes back in `ShellResult.status` (use
    /// `check(command:)` to turn it into an error).
    public static func run(executable: String, args: [String] = [], env: [String: String] = [:], cwd: URL? = nil,
                           timeout: TimeInterval? = nil) async throws -> ShellResult {
        let spec = Spec(executable: executable, args: args, env: env, cwd: cwd, timeout: timeout)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runSync(spec))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func run(executable: URL, args: [String] = [], env: [String: String] = [:], cwd: URL? = nil,
                           timeout: TimeInterval? = nil) async throws -> ShellResult {
        try await run(executable: executable.path, args: args, env: env, cwd: cwd, timeout: timeout)
    }

    /// `run` + `check`: stdout of a tool that must succeed.
    public static func capture(executable: String, args: [String] = [], env: [String: String] = [:], cwd: URL? = nil,
                               timeout: TimeInterval? = nil) async throws -> String {
        try await run(executable: executable, args: args, env: env, cwd: cwd, timeout: timeout)
            .check(command: commandLine(executable, args)).stdout
    }

    /// Blocking form of `run`, for callers that are not async (short tools only).
    public static func runSync(executable: String, args: [String] = [], env: [String: String] = [:], cwd: URL? = nil,
                               timeout: TimeInterval? = nil) throws -> ShellResult {
        try runSync(Spec(executable: executable, args: args, env: env, cwd: cwd, timeout: timeout))
    }

    static func runSync(_ spec: Spec) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.args
        process.environment = baseEnvironment(merging: spec.env)
        if let cwd = spec.cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw OssoverError.io("cannot start \(spec.commandLine): \(error.localizedDescription)")
        }

        // Both pipes are drained concurrently so neither can fill and stall the child.
        let out = OutputBuffer()
        let err = OutputBuffer()
        let drained = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async(group: drained) { out.append(outHandle.readDataToEndOfFile()) }
        DispatchQueue.global(qos: .utility).async(group: drained) { err.append(errHandle.readDataToEndOfFile()) }

        let pid = process.processIdentifier
        var timedOut = false
        if let timeout = spec.timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                Darwin.kill(pid, SIGTERM)
                if finished.wait(timeout: .now() + 2) == .timedOut {
                    Darwin.kill(pid, SIGKILL)
                    finished.wait()
                }
            }
        } else {
            finished.wait()
        }
        // A grandchild that kept the pipe (a daemon) must not hang us after a kill.
        if timedOut {
            _ = drained.wait(timeout: .now() + 2)
            throw OssoverError.timeout(command: spec.commandLine, seconds: spec.timeout ?? 0)
        }
        drained.wait()
        return ShellResult(status: process.terminationStatus, stdout: out.string, stderr: err.string)
    }

    // MARK: Streaming

    /// Starts a tool whose combined stdout+stderr is appended to `logFile` as it arrives (and
    /// handed to `onOutput` when given), and returns at once. The log gets a header naming the
    /// command and a footer with the exit status; `header` lines (an allowlisted-env dump) go
    /// between. Callers wait or kill through the returned handle.
    public static func runStreaming(executable: String, args: [String] = [], env: [String: String] = [:],
                                    cwd: URL? = nil, logFile: URL, header: String? = nil,
                                    onOutput: (@Sendable (Data) -> Void)? = nil) throws -> ShellProcess {
        let sink = try LogSink(file: logFile, onOutput: onOutput)
        let command = commandLine(executable, args)
        let started = Date()
        var head = "# \(Self.timestamp(started)) \(command)\n"
        if let cwd { head += "# cwd=\(cwd.path)\n" }
        if let header, !header.isEmpty { head += header.hasSuffix("\n") ? header : header + "\n" }
        sink.write(Data(head.utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = baseEnvironment(merging: env)
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = ShellProcess(process: process, logFile: logFile, startedAt: started)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                sink.endOfOutput()
            } else {
                sink.write(chunk)
            }
        }
        process.terminationHandler = { p in
            let seconds = Int(Date().timeIntervalSince(started).rounded())
            let reason = p.terminationReason == .uncaughtSignal ? " (signal)" : ""
            sink.write(Data("# exit=\(p.terminationStatus)\(reason) after \(seconds)s\n".utf8))
            sink.processEnded()
            handle.finish(status: p.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            sink.write(Data("# failed to start: \(error.localizedDescription)\n".utf8))
            sink.endOfOutput()
            sink.processEnded()
            throw OssoverError.io("cannot start \(command): \(error.localizedDescription)")
        }
        return handle
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// A started `runStreaming` tool. Thread-safe; `wait()` can be called from several tasks.
public final class ShellProcess: @unchecked Sendable {
    public let process: Process
    public let logFile: URL
    public let startedAt: Date

    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let exited = DispatchSemaphore(value: 0)

    init(process: Process, logFile: URL, startedAt: Date) {
        self.process = process
        self.logFile = logFile
        self.startedAt = startedAt
    }

    public var pid: pid_t { process.processIdentifier }
    public var isRunning: Bool { exitStatus == nil }
    /// Nil while the tool runs.
    public var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// SIGTERM.
    public func terminate() { Darwin.kill(pid, SIGTERM) }
    /// SIGKILL.
    public func forceKill() { Darwin.kill(pid, SIGKILL) }

    /// Suspends until the tool exits; returns its status.
    public func wait() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Blocks until the tool exits or `timeout` passes; nil on timeout.
    public func waitBlocking(timeout: TimeInterval? = nil) -> Int32? {
        if let status = exitStatus { return status }
        if let timeout {
            guard exited.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            exited.wait()
        }
        exited.signal()   // let any other blocked waiter through
        return exitStatus
    }

    func finish(status: Int32) {
        lock.lock()
        self.status = status
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        exited.signal()
        for w in pending { w.resume(returning: status) }
    }
}

/// Serialises writes to a log file from the pipe's queue and the termination handler, and
/// closes the file once the pipe hit EOF and the process ended (in either order).
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let onOutput: (@Sendable (Data) -> Void)?
    private var eof = false
    private var ended = false
    private var closed = false

    init(file: URL, onOutput: (@Sendable (Data) -> Void)?) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(file.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil) else { throw OssoverError.io("cannot create \(file.path)") }
        }
        do {
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
        } catch {
            throw OssoverError.io("cannot open \(file.path) for writing: \(error.localizedDescription)")
        }
        self.onOutput = onOutput
    }

    func write(_ data: Data) {
        lock.lock()
        if !closed { try? handle.write(contentsOf: data) }
        lock.unlock()
        onOutput?(data)
    }

    func endOfOutput() {
        lock.lock()
        eof = true
        closeIfDone()
        lock.unlock()
    }

    func processEnded() {
        lock.lock()
        ended = true
        closeIfDone()
        lock.unlock()
    }

    private func closeIfDone() {
        guard eof, ended, !closed else { return }
        closed = true
        try? handle.close()
    }
}

/// Bytes appended from a reader thread, read from another.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Interactive (foreground TTY)

extension Shell {
    /// Runs a tool in the foreground on this process's own stdin/stdout/stderr — `steamcmd`
    /// asking for a password and a Steam Guard code — and blocks until it exits. The parent
    /// environment is inherited whole (TERM, HOME, the user's PATH) with `env` merged on top,
    /// because the tool talks to the user, not to ossover. Returns the exit status (128 + the
    /// signal number for a signalled child); throws only `.io` when the tool cannot start.
    /// Nothing typed at the prompt passes through ossover.
    ///
    /// The child is spawned with `posix_spawn`, not Foundation's `Process`: `Process` puts a
    /// child into a new process group, and a process outside the terminal's foreground group is
    /// stopped by `SIGTTIN` the moment it reads the controlling TTY, so the tool's password
    /// prompt would hang forever. Here the child stays in ossover's (foreground) group, gets
    /// default signal dispositions and an empty signal mask, and inherits fds 0/1/2 as they
    /// are. Like `system(3)`, ossover ignores SIGINT/SIGQUIT while the child runs so Ctrl-C
    /// reaches the tool and ossover reports its status.
    public static func runInteractive(executable: String, args: [String] = [], env: [String: String] = [:],
                                      cwd: URL? = nil) throws -> Int32 {
        let command = commandLine(executable, args)
        let environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw OssoverError.io("cannot start \(command): posix_spawnattr_init failed") }
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw OssoverError.io("cannot start \(command): posix_spawn_file_actions_init failed") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let cwd {
            // A directory change only; fds 0/1/2 are inherited untouched.
            guard posix_spawn_file_actions_addchdir_np(&actions, cwd.path) == 0 else {
                throw OssoverError.io("cannot start \(command): cannot set the working directory \(cwd.path)")
            }
        }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.keys.sorted().map { strdup("\($0)=\(environment[$0] ?? "")") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard spawned == 0 else {
            throw OssoverError.io("cannot start \(command): \(String(cString: strerror(spawned)))")
        }
        return try waitForExit(of: pid, command: command)
    }

    /// `waitpid` looped on `EINTR`; the status as a shell would report it.
    static func waitForExit(of pid: pid_t, command: String) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw OssoverError.io("waitpid for \(command) failed: \(String(cString: strerror(errno)))") }
        }
        return exitStatus(fromWaitStatus: status)
    }

    /// `WEXITSTATUS` for a normal exit, `128 + WTERMSIG` for a signal (pure).
    public static func exitStatus(fromWaitStatus status: Int32) -> Int32 {
        let signalNumber = status & 0x7f
        if signalNumber == 0 { return (status >> 8) & 0xff }
        return 128 + signalNumber
    }
}
