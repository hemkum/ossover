// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A running `log stream --level info --style ndjson --predicate '…'` child. Only the JSON
/// lines (one per log event) go to `ndjsonURL`, so the file stays valid NDJSON; everything the
/// tool prints (its "Filtering the log data…" notice, the command header and exit footer) goes
/// to `sidecarLogURL`. Every `metal-HUD:` event is parsed on arrival into a `MetalHUDTrace`
/// that `trace` snapshots, so a caller can judge frame rates while the stream runs.
///
/// The unified log redacts the HUD's frame list (`metal-HUD: 54,6.52,174.75<private>`), so
/// these samples carry the three header fields only: enough for the frame-counter rate
/// (`MetalHUDCounterStats`), not for intervals. The harness's primary source is `HUDLogTail`
/// on the wine log; this stream is the secondary one and `attach`'s only one without a log.
public final class LogStream: @unchecked Sendable {
    public static let executable = "/usr/bin/log"
    public static let sidecarLogName = "log-stream.log"

    /// `stream --level info --style ndjson [--process <pid>] --predicate <predicate>`.
    public static func arguments(predicate: String, level: String = "info", processID: pid_t? = nil) -> [String] {
        var args = ["stream", "--level", level, "--style", "ndjson"]
        if let processID { args += ["--process", String(processID)] }
        args += ["--predicate", predicate]
        return args
    }

    public let ndjsonURL: URL
    public let sidecarLogURL: URL
    /// When set, only this process's events are kept (`--process` plus a parse-side filter).
    public let processID: pid_t?
    private let process: ShellProcess
    private let lines: LineAccumulator

    private init(ndjsonURL: URL, sidecarLogURL: URL, processID: pid_t?, process: ShellProcess, lines: LineAccumulator) {
        self.ndjsonURL = ndjsonURL
        self.sidecarLogURL = sidecarLogURL
        self.processID = processID
        self.process = process
        self.lines = lines
    }

    /// Starts the stream, truncating `ndjson`. The sidecar defaults to `log-stream.log` beside it.
    public static func start(ndjson: URL, predicate: String = MetalHUDLog.logPredicate, processID: pid_t? = nil,
                             sidecarLog: URL? = nil) throws -> LogStream {
        let sidecar = sidecarLog ?? ndjson.deletingLastPathComponent().appending(path: sidecarLogName)
        let accumulator = try LineAccumulator(ndjson: ndjson, processID: processID.map { Int($0) })
        let args = arguments(predicate: predicate, processID: processID)
        let process: ShellProcess
        do {
            process = try Shell.runStreaming(executable: executable, args: args, logFile: sidecar,
                                             onOutput: { data in accumulator.append(data) })
        } catch {
            accumulator.close()
            throw error
        }
        return LogStream(ndjsonURL: ndjson, sidecarLogURL: sidecar, processID: processID, process: process, lines: accumulator)
    }

    public var pid: pid_t { process.pid }
    public var isRunning: Bool { process.isRunning }
    public var exitStatus: Int32? { process.exitStatus }
    /// Snapshot of every HUD sample received so far.
    public var trace: MetalHUDTrace { lines.snapshot() }
    public var sampleCount: Int { lines.snapshot().samples.count }

    /// SIGTERM, up to `grace` seconds for `log` to exit, then SIGKILL; flushes and closes the
    /// NDJSON file. Returns the exit status. Safe to call more than once.
    @discardableResult
    public func stop(grace: TimeInterval = 3) async -> Int32 {
        defer { lines.close() }
        if let status = process.exitStatus { return status }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            await Self.pause(0.1)
        }
        if process.isRunning { process.forceKill() }
        return await process.wait()
    }

    /// A sleep that still waits when the task is already cancelled (`Task.sleep` would return
    /// at once and turn the grace loop into a spin), so a Ctrl-C shutdown stays orderly.
    static func pause(_ seconds: TimeInterval) async {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
        }
    }

    /// Blocking form of `stop` for non-async callers.
    @discardableResult
    public func stopBlocking(grace: TimeInterval = 3) -> Int32? {
        defer { lines.close() }
        if let status = process.exitStatus { return status }
        process.terminate()
        if let status = process.waitBlocking(timeout: grace) { return status }
        process.forceKill()
        return process.waitBlocking(timeout: 2)
    }
}

/// Splits the child's output into lines, writes the JSON ones to the NDJSON file and parses
/// HUD samples out of them. Called from the pipe's reader thread; read from any other.
final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let processID: Int?
    private var pending: [UInt8] = []
    private var trace = MetalHUDTrace()
    private var closed = false

    init(ndjson: URL, processID: Int?) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: ndjson.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(ndjson.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        guard fm.createFile(atPath: ndjson.path, contents: nil) else { throw OssoverError.io("cannot create \(ndjson.path)") }
        do {
            handle = try FileHandle(forWritingTo: ndjson)
        } catch {
            throw OssoverError.io("cannot open \(ndjson.path) for writing: \(error.localizedDescription)")
        }
        self.processID = processID
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        pending.append(contentsOf: data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Array(pending[..<newline])
            pending.removeSubrange(...newline)
            handle(line: line)
        }
    }

    func snapshot() -> MetalHUDTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    /// Flushes a trailing partial line and closes the file.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if !pending.isEmpty {
            handle(line: pending)
            pending.removeAll()
        }
        closed = true
        try? handle.close()
    }

    /// Only JSON objects are kept; `log`'s notices and any `#` header lines are dropped here
    /// (they are still in the sidecar log).
    private func handle(line: [UInt8]) {
        guard line.first == UInt8(ascii: "{") else { return }
        try? handle.write(contentsOf: Data(line) + Data([0x0A]))
        guard var sample = MetalHUDLog.parseNDJSON(String(decoding: line, as: UTF8.self)) else { return }
        if sample.timestamp == nil { sample.timestamp = Date() }
        if let processID, let samplePID = sample.processID, samplePID != processID { return }
        trace.append(sample)
    }
}

// MARK: - Wine log tail

/// Follows a program's stderr log while it is written: the bottle's wine log, where the Metal
/// HUD's full per-frame lines land as NSLog text (`2026-10-14 01:50:56.707 wine[46721:2494548]
/// metal-HUD: …`). The unified log redacts the frame list as `<private>`, so this file is the
/// primary data source of `smoke` and `bench`; `LogStream`'s NDJSON stays the secondary,
/// header-only one. New bytes are read every `interval` (and on `poll`/`stop`), split into
/// lines and parsed into a `MetalHUDTrace` that `trace` snapshots. The file may not exist when
/// the tail starts (the launcher creates it); the tail keeps trying.
public final class HUDLogTail: @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 0.25

    public let fileURL: URL
    /// Every line's pairs halved on arrival: the overlay was drawn (`--hud-visible`), so the HUD
    /// logged each frame as two identical pairs.
    public let halvesPairs: Bool
    /// The zone the NSLog times are in (the machine's).
    public let timeZone: TimeZone

    private let lock = NSLock()
    private var offset: UInt64
    private var pending: [UInt8] = []
    private var accumulated = MetalHUDTrace()
    private var lineCount = 0
    private var unpairedCount = 0
    private var timer: DispatchSourceTimer?
    private var stopped = false

    /// A tail that reads from the start of `file` (or from its current end with `fromEnd`, for
    /// a log that already holds hours of play). Call `poll` yourself, or `resume` for a timer.
    public init(file: URL, halvesPairs: Bool = false, fromEnd: Bool = false, timeZone: TimeZone = .current) {
        self.fileURL = file
        self.halvesPairs = halvesPairs
        self.timeZone = timeZone
        self.offset = fromEnd ? Self.size(of: file) : 0
    }

    /// Starts following `file` on a background timer.
    public static func start(file: URL, halvesPairs: Bool = false, fromEnd: Bool = false,
                             interval: TimeInterval = defaultInterval, timeZone: TimeZone = .current) -> HUDLogTail {
        let tail = HUDLogTail(file: file, halvesPairs: halvesPairs, fromEnd: fromEnd, timeZone: timeZone)
        tail.resume(interval: interval)
        return tail
    }

    static func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    /// Polls every `interval` seconds until `stop`.
    public func resume(interval: TimeInterval = defaultInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    /// Snapshot of every HUD sample read so far.
    public var trace: MetalHUDTrace {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }

    public var sampleCount: Int { trace.samples.count }

    /// Lines read so far (HUD or not).
    public var lineCountSoFar: Int {
        lock.lock()
        defer { lock.unlock() }
        return lineCount
    }

    /// With `halvesPairs`: HUD lines whose pairs were not the expected identical couples (the
    /// overlay was not drawn after all?). They were halved regardless.
    public var unpairedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unpairedCount
    }

    /// Reads whatever was appended since the last poll. Safe to call from any thread, and after
    /// `stop` (a no-op then).
    public func poll() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        read()
    }

    /// A last read, then the timer ends. Safe to call more than once.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        read()
        if !pending.isEmpty {
            handle(line: pending)
            pending.removeAll()
        }
        stopped = true
        timer?.cancel()
        timer = nil
    }

    private func read() {
        guard let file = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            if size < offset {   // the file was replaced: start over
                offset = 0
                pending.removeAll()
            }
            try file.seek(toOffset: offset)
            guard let data = try file.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            pending.append(contentsOf: data)
        } catch {
            return
        }
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Array(pending[..<newline])
            pending.removeSubrange(...newline)
            handle(line: line)
        }
    }

    private func handle(line: [UInt8]) {
        lineCount += 1
        guard var sample = MetalHUDLog.parseLine(String(decoding: line, as: UTF8.self), receivedAt: Date(), timeZone: timeZone) else { return }
        if halvesPairs, !sample.frames.isEmpty {
            if !sample.hasDuplicatedPairs { unpairedCount += 1 }
            sample = sample.halvingDuplicatePairs()
        }
        accumulated.append(sample)
    }
}
