// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One frame as Apple's Metal Performance HUD logs it (`MTL_HUD_LOG_ENABLED=1`): the present
/// interval since the previous frame and the GPU time, both in milliseconds.
public struct MetalHUDFrame: Sendable, Equatable, Codable {
    public var intervalMs: Double
    public var gpuTimeMs: Double

    public init(intervalMs: Double, gpuTimeMs: Double) {
        self.intervalMs = intervalMs
        self.gpuTimeMs = gpuTimeMs
    }
}

/// One `metal-HUD:` line:
/// `metal-HUD: <firstFrame>,<gfxMB>,<procMB>,<interval0>,<gpuTime0>,<interval1>,<gpuTime1>,…`
///
/// The HUD writes a line every 98 pairs, not every second (≈0.82 s at 120 fps with the overlay
/// hidden, ≈0.41 s with it drawn, when every frame is logged as two identical pairs and the
/// frame counter advances by half the pair count). Frame rates over time therefore come from
/// the timestamps and the frame counter (`MetalHUDCounterStats`), never from line counts.
public struct MetalHUDSample: Sendable, Equatable, Codable {
    /// When the line was logged (the NSLog prefix on stderr, the `log stream` timestamp, or the
    /// time it was received). Nil for a bare text line read back from a file.
    public var timestamp: Date?
    /// The logging process, from the NSLog prefix or `log stream`; nil for bare text.
    public var processID: Int?
    /// Index of the first frame this line covers.
    public var firstFrame: Int
    /// Graphics memory in use, MB.
    public var gfxMemoryMB: Double
    /// Process memory in use, MB.
    public var processMemoryMB: Double
    public var frames: [MetalHUDFrame]

    public init(timestamp: Date? = nil, processID: Int? = nil, firstFrame: Int, gfxMemoryMB: Double,
                processMemoryMB: Double, frames: [MetalHUDFrame]) {
        self.timestamp = timestamp
        self.processID = processID
        self.firstFrame = firstFrame
        self.gfxMemoryMB = gfxMemoryMB
        self.processMemoryMB = processMemoryMB
        self.frames = frames
    }

    public var frameCount: Int { frames.count }
    /// Wall time the frames cover, ms.
    public var intervalSumMs: Double { frames.reduce(0) { $0 + $1.intervalMs } }
    /// Frames per second over this line; nil when it holds no frames or no time.
    public var fps: Double? {
        let ms = intervalSumMs
        guard !frames.isEmpty, ms > 0 else { return nil }
        return Double(frames.count) / (ms / 1000)
    }

    /// True when every pair at an even index equals the one after it: the shape of a line logged
    /// while the HUD overlay is drawn (each frame recorded twice). A hidden-HUD line fails this
    /// as soon as two neighbouring frames differ, which real traces do within a few frames.
    public var hasDuplicatedPairs: Bool {
        guard !frames.isEmpty, frames.count % 2 == 0 else { return false }
        return stride(from: 0, to: frames.count, by: 2).allSatisfy { frames[$0] == frames[$0 + 1] }
    }

    /// Every second pair dropped: the line as the hidden HUD would have logged it. Applied to
    /// every line of an overlay-visible run (`--hud-visible`), whether or not the pairs matched.
    public func halvingDuplicatePairs() -> MetalHUDSample {
        var copy = self
        copy.frames = stride(from: 0, to: frames.count, by: 2).map { frames[$0] }
        return copy
    }
}

/// The frame rate from the HUD's frame counter over wall time: `(lastLine.firstFrame -
/// firstLine.firstFrame) / (lastLine.timestamp - firstLine.timestamp)`. It needs only the three
/// header fields and a timestamp, so it survives the unified log's redaction, and it is immune to
/// duplicated pairs; `MetalHUDStats.avgFPS` (from the intervals) is cross-checked against it.
public struct MetalHUDCounterStats: Sendable, Equatable, Codable {
    /// The counter on the first and the last line of the window.
    public var firstFrame: Int
    public var lastFrame: Int
    /// `lastFrame - firstFrame`: the frames presented between the two lines.
    public var frames: Int
    /// Seconds between the first and the last line.
    public var wallS: Double
    /// `frames / wallS`.
    public var fps: Double
    /// Lines the window covered, after collapsing repeats of one line (the unified log carries
    /// every line twice).
    public var samples: Int
    /// `(interval, gpu)` pairs the lines carried over the counted span (every line but the last),
    /// so `pairsPerFrame` tells whether the intervals are one per frame.
    public var pairs: Int
    /// The slowest line-to-line stretch, fps.
    public var minSegmentFPS: Double
    /// The longest line-to-line stretch, seconds.
    public var maxSegmentS: Double
    /// The process whose lines were counted.
    public var processID: Int?

    public init(firstFrame: Int, lastFrame: Int, wallS: Double, samples: Int, pairs: Int, minSegmentFPS: Double,
                maxSegmentS: Double, processID: Int?) {
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.frames = lastFrame - firstFrame
        self.wallS = wallS
        self.fps = wallS > 0 ? Double(lastFrame - firstFrame) / wallS : 0
        self.samples = samples
        self.pairs = pairs
        self.minSegmentFPS = minSegmentFPS
        self.maxSegmentS = maxSegmentS
        self.processID = processID
    }

    /// Pairs the lines carried per counted frame: ≈1 for a hidden overlay or a halved visible
    /// one, ≈2 for a visible overlay that was not halved, ≈0.5 for a hidden one that was. Nil for
    /// header-only lines (no pairs at all).
    public var pairsPerFrame: Double? {
        guard pairs > 0, frames > 0 else { return nil }
        return Double(pairs) / Double(frames)
    }

    /// "counter 120.0 fps over 59.98 s (7203 frames, 73 lines)".
    public var summary: String {
        String(format: "counter %.1f fps over %.2f s (%d frames, %d lines)", fps, wallS, frames, samples)
    }

    /// Component-wise median across runs. Nil for no runs.
    public static func median(of runs: [MetalHUDCounterStats]) -> MetalHUDCounterStats? {
        guard !runs.isEmpty else { return nil }
        func med(_ f: (MetalHUDCounterStats) -> Double) -> Double { MetalHUDTrace.median(runs.map(f)) ?? 0 }
        var out = MetalHUDCounterStats(
            firstFrame: 0, lastFrame: Int(med { Double($0.frames) }.rounded()), wallS: med(\.wallS),
            samples: Int(med { Double($0.samples) }.rounded()), pairs: Int(med { Double($0.pairs) }.rounded()),
            minSegmentFPS: med(\.minSegmentFPS), maxSegmentS: med(\.maxSegmentS), processID: nil)
        out.fps = med(\.fps)
        return out
    }
}

/// Both readings of one window: the interval statistics (nil without `(interval, gpu)` pairs,
/// as from the unified log) and the frame-counter rate (nil with fewer than two timestamped
/// lines). The two frame rates should agree; `fpsDisagreement` says by how much they do not.
public struct MetalHUDReading: Sendable, Equatable, Codable {
    public var stats: MetalHUDStats?
    public var counter: MetalHUDCounterStats?

    public init(stats: MetalHUDStats? = nil, counter: MetalHUDCounterStats? = nil) {
        self.stats = stats
        self.counter = counter
    }

    public var isEmpty: Bool { stats == nil && counter == nil }

    /// `|avgFPS - counter.fps| / counter.fps`; nil when either side is missing.
    public var fpsDisagreement: Double? {
        guard let avg = stats?.avgFPS, let counter, counter.fps > 0 else { return nil }
        return abs(avg - counter.fps) / counter.fps
    }

    /// The frame rate to report: the counter's when it exists (robust to duplicated pairs), else
    /// the intervals'.
    public var fps: Double? { counter?.fps ?? stats?.avgFPS }

    public var summary: String {
        switch (stats, counter) {
        case let (.some(stats), .some(counter)): return stats.summary + "; " + counter.summary
        case let (.some(stats), .none): return stats.summary
        case let (.none, .some(counter)): return counter.summary
        case (.none, .none): return "no frames"
        }
    }
}

/// What a measurement window yielded. `p1LowFPS` is the frame rate at the 99th-percentile
/// interval (the "1% low" of benchmark reports); `p50FPS` the median-interval frame rate.
public struct MetalHUDStats: Sendable, Equatable, Codable {
    public var frames: Int
    /// `frames / Σinterval`.
    public var avgFPS: Double
    /// `1000 / p99(interval)`.
    public var p1LowFPS: Double
    /// `1000 / p50(interval)`.
    public var p50FPS: Double
    public var gpuTimeMeanMs: Double
    /// `Σinterval`, seconds.
    public var durationS: Double
    /// HUD lines the window covered.
    public var samples: Int
    public var p99IntervalMs: Double
    public var maxIntervalMs: Double

    public init(frames: Int, avgFPS: Double, p1LowFPS: Double, p50FPS: Double, gpuTimeMeanMs: Double, durationS: Double,
                samples: Int, p99IntervalMs: Double, maxIntervalMs: Double) {
        self.frames = frames
        self.avgFPS = avgFPS
        self.p1LowFPS = p1LowFPS
        self.p50FPS = p50FPS
        self.gpuTimeMeanMs = gpuTimeMeanMs
        self.durationS = durationS
        self.samples = samples
        self.p99IntervalMs = p99IntervalMs
        self.maxIntervalMs = maxIntervalMs
    }

    /// "avg 72.3 fps, 1% low 41.0, p50 73.1, gpu 9.8 ms, 60.0 s (4338 frames)".
    public var summary: String {
        String(format: "avg %.1f fps, 1%% low %.1f, p50 %.1f, gpu %.1f ms, %.1f s (%d frames)",
               avgFPS, p1LowFPS, p50FPS, gpuTimeMeanMs, durationS, frames)
    }

    /// Component-wise median across runs (the benchmark's 3-run median). Nil for no runs.
    public static func median(of runs: [MetalHUDStats]) -> MetalHUDStats? {
        guard !runs.isEmpty else { return nil }
        func med(_ f: (MetalHUDStats) -> Double) -> Double { MetalHUDTrace.median(runs.map(f)) ?? 0 }
        return MetalHUDStats(
            frames: Int(med { Double($0.frames) }.rounded()),
            avgFPS: med(\.avgFPS), p1LowFPS: med(\.p1LowFPS), p50FPS: med(\.p50FPS),
            gpuTimeMeanMs: med(\.gpuTimeMeanMs), durationS: med(\.durationS),
            samples: Int(med { Double($0.samples) }.rounded()),
            p99IntervalMs: med(\.p99IntervalMs), maxIntervalMs: med(\.maxIntervalMs))
    }
}

/// Samples accumulated in arrival order, with the statistics over any time window.
public struct MetalHUDTrace: Sendable, Equatable {
    public private(set) var samples: [MetalHUDSample]

    public init(samples: [MetalHUDSample] = []) { self.samples = samples }

    public mutating func append(_ sample: MetalHUDSample) { samples.append(sample) }
    public mutating func append(contentsOf more: [MetalHUDSample]) { samples.append(contentsOf: more) }

    public var isEmpty: Bool { samples.isEmpty }
    public var frameCount: Int { samples.reduce(0) { $0 + $1.frameCount } }
    public var frames: [MetalHUDFrame] { samples.flatMap(\.frames) }
    public var first: Date? { samples.compactMap(\.timestamp).min() }
    public var last: Date? { samples.compactMap(\.timestamp).max() }

    /// Samples whose timestamp lies in `window`; samples without a timestamp are left out.
    public func samples(in window: ClosedRange<Date>) -> [MetalHUDSample] {
        samples.filter { sample in sample.timestamp.map { window.contains($0) } ?? false }
    }

    /// Only the samples of one process (the `log stream` `processID`).
    public func filtered(processID: Int) -> MetalHUDTrace {
        filtered(processIDs: [processID])
    }

    /// Only the samples logged by one of `processIDs`. The `metal-HUD:` predicate is
    /// system-wide, so a harness judging a run must narrow the trace to the pids of its own
    /// prefix; a sample without a process id (a bare text line) is left out.
    public func filtered(processIDs: Set<Int>) -> MetalHUDTrace {
        MetalHUDTrace(samples: samples.filter { sample in sample.processID.map { processIDs.contains($0) } ?? false })
    }

    /// Statistics over every sample (nil window) or the samples timestamped inside `window`.
    /// Nil when the window holds no frames.
    public func stats(window: ClosedRange<Date>? = nil) -> MetalHUDStats? {
        let selected = window.map { samples(in: $0) } ?? samples
        return Self.stats(of: selected)
    }

    /// Statistics over the trailing `seconds` ending at `end`.
    public func stats(last seconds: TimeInterval, endingAt end: Date = Date()) -> MetalHUDStats? {
        stats(window: end.addingTimeInterval(-seconds)...end)
    }

    /// Both readings over every sample (nil window) or the samples timestamped inside `window`.
    public func reading(window: ClosedRange<Date>? = nil) -> MetalHUDReading {
        Self.reading(of: window.map { samples(in: $0) } ?? samples)
    }

    /// The frame-counter rate over every sample (nil window) or the window; nil with fewer than
    /// two timestamped lines of one process.
    public func counterStats(window: ClosedRange<Date>? = nil) -> MetalHUDCounterStats? {
        Self.counterStats(of: window.map { samples(in: $0) } ?? samples)
    }

    /// The trailing lines spanning at least `seconds` of wall time when every line-to-line
    /// stretch in them ran at `minFPS` or better by the frame counter, and the newest line is no
    /// older than `staleAfter` before `end`; nil otherwise (too little history yet, a slow or
    /// stalled stretch, a counter that went backwards). The smoke test's "≥5 s at ≥20 fps".
    /// Lines are judged by their timestamps and counters, never by how many there are: the HUD
    /// logs a line every 98 pairs, so at 20 fps one line can cover five seconds.
    public func sustained(minFPS: Double, seconds: Double, endingAt end: Date = Date(),
                          staleAfter: TimeInterval = 3) -> MetalHUDReading? {
        guard seconds > 0 else { return nil }
        let lines = Self.collapsingRepeats(Self.dominantProcess(of: samples.filter { $0.timestamp != nil }))
        guard let newest = lines.last, let newestAt = newest.timestamp, end.timeIntervalSince(newestAt) <= staleAfter else { return nil }
        var window = [newest]
        var index = lines.count - 2
        while index >= 0 {
            let older = lines[index]
            guard let olderAt = older.timestamp, let newerAt = window[0].timestamp else { return nil }
            let stretch = newerAt.timeIntervalSince(olderAt)
            let frames = window[0].firstFrame - older.firstFrame
            guard stretch > 0, frames > 0, Double(frames) / stretch >= minFPS else { return nil }
            window.insert(older, at: 0)
            if newestAt.timeIntervalSince(olderAt) >= seconds { return Self.reading(of: window) }
            index -= 1
        }
        return nil
    }

    /// Both readings of a list of samples.
    public static func reading(of samples: [MetalHUDSample]) -> MetalHUDReading {
        MetalHUDReading(stats: stats(of: samples), counter: counterStats(of: samples))
    }

    /// The frame-counter rate over a list of samples (arrival order): the lines of the process
    /// that logged most of them, repeats collapsed. Nil with fewer than two timestamped lines,
    /// no wall time between them, or a counter that did not advance from one line to the next.
    public static func counterStats(of samples: [MetalHUDSample]) -> MetalHUDCounterStats? {
        let lines = collapsingRepeats(dominantProcess(of: samples.filter { $0.timestamp != nil }))
        guard lines.count >= 2, let first = lines.first, let last = lines.last,
              let start = first.timestamp, let end = last.timestamp else { return nil }
        let wall = end.timeIntervalSince(start)
        guard wall > 0, last.firstFrame > first.firstFrame else { return nil }
        var minSegmentFPS = Double.infinity
        var maxSegmentS = 0.0
        for (older, newer) in zip(lines, lines.dropFirst()) {
            guard let olderAt = older.timestamp, let newerAt = newer.timestamp else { continue }
            let stretch = newerAt.timeIntervalSince(olderAt)
            let frames = newer.firstFrame - older.firstFrame
            guard frames > 0 else { return nil }
            maxSegmentS = max(maxSegmentS, stretch)
            if stretch > 0 { minSegmentFPS = min(minSegmentFPS, Double(frames) / stretch) }
        }
        return MetalHUDCounterStats(firstFrame: first.firstFrame, lastFrame: last.firstFrame, wallS: wall, samples: lines.count,
                                    pairs: lines.dropLast().reduce(0) { $0 + $1.frameCount },
                                    minSegmentFPS: minSegmentFPS.isFinite ? minSegmentFPS : 0, maxSegmentS: maxSegmentS,
                                    processID: first.processID)
    }

    /// The samples of the process that logged the most lines (ties: the larger counter advance),
    /// in arrival order. A launcher and its game both write to one stderr; the counter of one
    /// process means nothing against the other's.
    public static func dominantProcess(of samples: [MetalHUDSample]) -> [MetalHUDSample] {
        var groups: [Int?: [MetalHUDSample]] = [:]
        for sample in samples { groups[sample.processID, default: []].append(sample) }
        guard groups.count > 1 else { return samples }
        func advance(_ group: [MetalHUDSample]) -> Int { (group.last?.firstFrame ?? 0) - (group.first?.firstFrame ?? 0) }
        return groups.values.max { a, b in a.count == b.count ? advance(a) < advance(b) : a.count < b.count } ?? samples
    }

    /// Consecutive samples repeating one line (same process and first frame: the unified log's
    /// NSLog mirror and os_log copy) collapsed to the first of them.
    public static func collapsingRepeats(_ samples: [MetalHUDSample]) -> [MetalHUDSample] {
        var out: [MetalHUDSample] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            if let last = out.last, last.processID == sample.processID, last.firstFrame == sample.firstFrame { continue }
            out.append(sample)
        }
        return out
    }

    /// Statistics over a list of samples; nil without frames.
    public static func stats(of samples: [MetalHUDSample]) -> MetalHUDStats? {
        let frames = samples.flatMap(\.frames)
        guard !frames.isEmpty else { return nil }
        let intervals = frames.map(\.intervalMs)
        let sumMs = intervals.reduce(0, +)
        let p99 = percentile(intervals, 99) ?? 0
        let p50 = percentile(intervals, 50) ?? 0
        let gpuMean = frames.reduce(0) { $0 + $1.gpuTimeMs } / Double(frames.count)
        return MetalHUDStats(
            frames: frames.count,
            avgFPS: sumMs > 0 ? Double(frames.count) / (sumMs / 1000) : 0,
            p1LowFPS: p99 > 0 ? 1000 / p99 : 0,
            p50FPS: p50 > 0 ? 1000 / p50 : 0,
            gpuTimeMeanMs: gpuMean,
            durationS: sumMs / 1000,
            samples: samples.count,
            p99IntervalMs: p99,
            maxIntervalMs: intervals.max() ?? 0)
    }

    /// Nearest-rank percentile (`p` in 0...100) of `values`; nil for an empty list.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(p, 0), 100)
        let rank = Int((clamped / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    /// Median (mean of the two middle values for an even count); nil for an empty list.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

/// Parser for the Metal HUD's log lines in their three forms: the NSLog text on the process's
/// stderr (a bottle's wine log: `2026-10-14 01:50:56.707 wine[46721:2494548] metal-HUD: …`,
/// the only place the full per-frame list reaches), `log stream --style ndjson` objects (field
/// `eventMessage`, header fields only: the frame list is `<private>`), and bare `metal-HUD:`
/// text.
public enum MetalHUDLog {
    public static let linePrefix = "metal-HUD:"
    /// The `log stream` predicate that selects HUD lines.
    public static let logPredicate = "eventMessage BEGINSWITH \"metal-HUD:\""

    /// The prefix NSLog puts on every stderr line: `<yyyy-MM-dd HH:mm:ss.SSS> <process>[<pid>:<tid>] `.
    /// The time is local, without a zone.
    public struct NSLogPrefix: Sendable, Equatable {
        public var timestamp: Date
        public var processName: String
        public var processID: Int
        public var threadID: Int

        public init(timestamp: Date, processName: String, processID: Int, threadID: Int) {
            self.timestamp = timestamp
            self.processName = processName
            self.processID = processID
            self.threadID = threadID
        }
    }

    /// Splits an NSLog stderr line into its prefix and the message after it; nil when the line
    /// does not start with `date time name[pid:tid] `. The zone-less time is read in `timeZone`.
    public static func parseNSLogPrefix(_ line: String, timeZone: TimeZone = .current) -> (prefix: NSLogPrefix, message: Substring)? {
        let text = Substring(line)
        guard let dateEnd = text.firstIndex(of: " ") else { return nil }
        let afterDate = text[text.index(after: dateEnd)...]
        guard let timeEnd = afterDate.firstIndex(of: " ") else { return nil }
        let date = text[..<dateEnd]
        let time = afterDate[..<timeEnd]
        guard date.count == 10, date.filter({ $0 == "-" }).count == 2, time.count >= 8,
              let timestamp = parseLogTimestamp(date + " " + time, assuming: timeZone) else { return nil }
        let rest = afterDate[afterDate.index(after: timeEnd)...]
        guard let close = rest.range(of: "] ") else { return nil }
        let bracket = rest[..<close.lowerBound]
        guard let open = bracket.lastIndex(of: "[") else { return nil }
        let ids = bracket[bracket.index(after: open)...].split(separator: ":", omittingEmptySubsequences: false)
        guard ids.count == 2, let pid = Int(ids[0]), let tid = Int(ids[1]) else { return nil }
        let name = String(bracket[..<open])
        guard !name.isEmpty else { return nil }
        return (NSLogPrefix(timestamp: timestamp, processName: name, processID: pid, threadID: tid), rest[close.upperBound...])
    }

    /// Parses one NSLog-prefixed stderr line into a sample stamped with the prefix's time and
    /// pid. Nil when the line has no NSLog prefix or no `metal-HUD:` message.
    public static func parseNSLogLine(_ line: String, timeZone: TimeZone = .current) -> MetalHUDSample? {
        guard let (prefix, message) = parseNSLogPrefix(line, timeZone: timeZone) else { return nil }
        return parseMessage(String(message), timestamp: prefix.timestamp, processID: prefix.processID)
    }

    /// One `log stream --style ndjson` object, the fields we read.
    struct LogStreamEvent: Decodable {
        var eventMessage: String?
        var timestamp: String?
        var processID: Int?
    }

    /// What the unified log shows in place of the frame list: the HUD logs the frames as private
    /// data, so `log stream`/`log show` carry only the three header fields
    /// (`metal-HUD: 54,6.52,174.75<private>`). The full line reaches the process's stderr.
    public static let redactedSuffix = "<private>"

    /// Parses a `metal-HUD: …` message (the prefix may sit after other text on the line). Nil
    /// when the line is not one or its header fields are malformed. An unpaired trailing value
    /// is dropped; a redacted line (`redactedSuffix`) yields a sample without frames.
    public static func parseMessage(_ text: String, timestamp: Date? = nil, processID: Int? = nil) -> MetalHUDSample? {
        guard let range = text.range(of: linePrefix) else { return nil }
        var body = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(redactedSuffix) { body = String(body.dropLast(redactedSuffix.count)) }
        let fields = body.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count >= 3,
              let firstFrame = Int(fields[0]),
              let gfx = Double(fields[1]),
              let proc = Double(fields[2]) else { return nil }
        var frames: [MetalHUDFrame] = []
        var i = 3
        while i + 1 < fields.count {
            guard let interval = Double(fields[i]), let gpu = Double(fields[i + 1]) else { return nil }
            frames.append(MetalHUDFrame(intervalMs: interval, gpuTimeMs: gpu))
            i += 2
        }
        return MetalHUDSample(timestamp: timestamp, processID: processID, firstFrame: firstFrame,
                              gfxMemoryMB: gfx, processMemoryMB: proc, frames: frames)
    }

    /// Parses one `log stream --style ndjson` line. Nil when it is not JSON or not a HUD event.
    public static func parseNDJSON(_ line: String) -> MetalHUDSample? {
        guard let event = try? JSONDecoder().decode(LogStreamEvent.self, from: Data(line.utf8)),
              let message = event.eventMessage else { return nil }
        return parseMessage(message, timestamp: event.timestamp.flatMap { parseLogTimestamp($0) }, processID: event.processID)
    }

    /// Parses any line: a JSON object goes through `parseNDJSON`, an NSLog-prefixed line through
    /// `parseNSLogLine` (its time read in `timeZone`), anything else is searched for the
    /// `metal-HUD:` prefix. `receivedAt` fills in a missing timestamp.
    public static func parseLine(_ line: String, receivedAt: Date? = nil, timeZone: TimeZone = .current) -> MetalHUDSample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sample = trimmed.hasPrefix("{") ? parseNDJSON(trimmed) : (parseNSLogLine(trimmed, timeZone: timeZone) ?? parseMessage(trimmed))
        if sample?.timestamp == nil { sample?.timestamp = receivedAt }
        return sample
    }

    /// Every HUD sample in `text`, in order; other lines are skipped. NSLog times are read in
    /// `timeZone` (the zone the machine that wrote the log was in). A wine log mixes CRLF (the
    /// Windows program's stdout) with LF (NSLog), and Swift reads `\r\n` as one character, so
    /// lines end at any newline, not at `\n` alone.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [MetalHUDSample] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { parseLine(String($0), timeZone: timeZone) }
    }

    /// `parse` of a file (an `hud.ndjson` or a wine log).
    public static func parse(file: URL, timeZone: TimeZone = .current) throws -> [MetalHUDSample] {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw OssoverError.missing("\(file.path): \(error.localizedDescription)")
        }
        return parse(text, timeZone: timeZone)
    }

    /// `log`'s timestamp text, `2026-10-13 22:26:33.417324+0530` (fraction optional). A text
    /// without a zone suffix (NSLog's) is read in `zone`, UTC by default.
    public static func parseLogTimestamp(_ text: String, assuming zone: TimeZone? = nil) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        guard dateParts.count == 3, let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]) else {
            return nil
        }
        var time = parts[1]
        var zoneSeconds = 0
        var explicitZone = true
        if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = time[time.index(after: sign)...]
            guard zone.count == 4, let hh = Int(zone.prefix(2)), let mm = Int(zone.suffix(2)) else { return nil }
            zoneSeconds = (hh * 3600 + mm * 60) * (time[sign] == "-" ? -1 : 1)
            time = time[..<sign]
        } else if time.hasSuffix("Z") {
            time = time.dropLast()
        } else {
            explicitZone = false
        }
        let timeParts = time.split(separator: ":")
        guard timeParts.count == 3, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        let secondParts = timeParts[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let second = Int(secondParts[0]) else { return nil }
        var fraction = 0.0
        if secondParts.count == 2 {
            guard let f = Double("0." + secondParts[1]) else { return nil }
            fraction = f
        }
        var calendar = Calendar(identifier: .gregorian)
        let assumed = explicitZone ? nil : zone
        guard let zone = assumed ?? TimeZone(secondsFromGMT: zoneSeconds) else { return nil }
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
