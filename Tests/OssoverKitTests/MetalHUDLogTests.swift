// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct MetalHUDLogTests {
    static func samples() throws -> [MetalHUDSample] {
        try MetalHUDLog.parse(file: Fixtures.url("hudlogs/sample.ndjson"))
    }

    /// The zone the real stderr captures were logged in (NSLog writes local time, no zone).
    static let ist = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!

    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    static func hiddenSamples() throws -> [MetalHUDSample] {
        try MetalHUDLog.parse(file: Fixtures.url("hudlogs/wine-stderr-hidden.log"), timeZone: ist)
    }

    static func visibleSamples() throws -> [MetalHUDSample] {
        try MetalHUDLog.parse(file: Fixtures.url("hudlogs/wine-stderr-visible.log"), timeZone: ist)
    }

    @Test func parsesEveryLineOfTheFixture() throws {
        let samples = try Self.samples()
        #expect(samples.count == 10)
        #expect(samples.allSatisfy { $0.processID == 48213 })
        #expect(samples.map(\.frameCount) == [61, 61, 61, 61, 61, 52, 61, 61, 48, 61])
        let first = try #require(samples.first)
        #expect(first.firstFrame == 1842)
        #expect(first.gfxMemoryMB == 3412.30)
        #expect(first.processMemoryMB == 5218.00)
        #expect(first.frames.first == MetalHUDFrame(intervalMs: 16.61, gpuTimeMs: 11.50))
        #expect(abs((first.fps ?? 0) - 61 / 1.00957) < 0.01)
        // 2026-10-13 21:05:10.211540+0530 is 15:35:10.211540 UTC.
        let expected = try #require(Self.utc(2026, 10, 13, 15, 35, 10)).addingTimeInterval(0.21154)
        let stamp = try #require(first.timestamp)
        #expect(abs(stamp.timeIntervalSince(expected)) < 0.001)
        let last = try #require(samples.last?.timestamp)
        #expect(abs(last.timeIntervalSince(stamp) - 9.001233) < 0.001)
    }

    @Test func statsMatchTheReferenceNumbers() throws {
        let stats = try #require(MetalHUDTrace(samples: try Self.samples()).stats())
        #expect(stats.frames == 588)
        #expect(stats.samples == 10)
        #expect(abs(stats.avgFPS - 58.98687) < 0.001)
        #expect(abs(stats.p99IntervalMs - 22.38) < 0.0001)
        #expect(abs(stats.p1LowFPS - 44.68275) < 0.001)
        #expect(abs(stats.p50FPS - 60.79027) < 0.001)
        #expect(abs(stats.maxIntervalMs - 128.4) < 0.0001)
        #expect(abs(stats.gpuTimeMeanMs - 11.33095) < 0.001)
        #expect(abs(stats.durationS - 9.96832) < 0.0001)
        #expect(stats.summary == "avg 59.0 fps, 1% low 44.7, p50 60.8, gpu 11.3 ms, 10.0 s (588 frames)")
        #expect(!BenchTarget.witcher3.met(by: stats))
        #expect(BenchTarget(avgFPS: 55, p1LowFPS: 40).met(by: stats))
    }

    @Test func windowsAndSustainedRuns() throws {
        let trace = MetalHUDTrace(samples: try Self.samples())
        let first = try #require(trace.first)
        let last = try #require(trace.last)
        let middle = try #require(trace.stats(window: first.addingTimeInterval(2)...first.addingTimeInterval(4.5)))
        #expect(middle.samples == 3)
        #expect(middle.frames == 183)
        let tail = try #require(trace.stats(last: 2.5, endingAt: last))
        #expect(tail.samples == 3)
        #expect(tail.frames == 170)

        let end = last.addingTimeInterval(1)
        let sustained = try #require(trace.sustained(minFPS: 40, seconds: 5, endingAt: end))
        #expect(sustained.counter?.samples == 6, "six lines a second apart span five seconds")
        #expect(sustained.counter?.frames == 2369 - 2086)
        #expect(sustained.stats?.samples == 6)
        #expect(trace.sustained(minFPS: 50, seconds: 5, endingAt: end) == nil, "the 48-frame second breaks a 50 fps run")
        #expect(trace.sustained(minFPS: 40, seconds: 5, endingAt: end.addingTimeInterval(10)) == nil, "the newest sample is stale")
        #expect(trace.sustained(minFPS: 40, seconds: 11, endingAt: end) == nil, "not enough history")
        #expect(trace.sustained(minFPS: 40, seconds: 0, endingAt: end) == nil)
        #expect(trace.filtered(processID: 1).isEmpty)
        #expect(trace.filtered(processID: 48213).frameCount == 588)

        // The frame counter over wall time agrees with the intervals, and the pairs are one per frame.
        let counter = try #require(trace.counterStats())
        #expect(counter.firstFrame == 1842 && counter.lastFrame == 2369 && counter.frames == 527 && counter.samples == 10)
        #expect(abs(counter.wallS - 9.001233) < 0.001)
        #expect(abs(counter.fps - 527 / 9.001233) < 0.01)
        #expect(counter.pairs == 588 - 61 && counter.pairsPerFrame == 1)
        #expect(abs(counter.minSegmentFPS - 48 / 1.000137) < 0.01)
        #expect(abs(counter.maxSegmentS - 1.000137) < 0.001)
        #expect(counter.processID == 48213)
        let reading = trace.reading()
        #expect(reading.stats == trace.stats() && reading.counter == counter && !reading.isEmpty)
        #expect(try #require(reading.fpsDisagreement) < 0.01)
        #expect(reading.fps == counter.fps)
        #expect(trace.reading(window: first.addingTimeInterval(2)...first.addingTimeInterval(4.5)).counter?.frames == 2025 - 1903)
        #expect(MetalHUDTrace(samples: [trace.samples[0]]).counterStats() == nil, "one line has no span")
        #expect(MetalHUDTrace(samples: [trace.samples[0], trace.samples[0]]).counterStats() == nil, "a repeat collapses to one line")
        #expect(MetalHUDTrace(samples: [trace.samples[1], trace.samples[0]]).counterStats() == nil, "a counter going backwards is no reading")
        #expect(MetalHUDTrace().reading().isEmpty && MetalHUDTrace().reading().summary == "no frames")
    }

    @Test func parsesRawLinesAndRejectsOthers() throws {
        let now = Date()
        let raw = try #require(MetalHUDLog.parseLine("metal-HUD: 10,100.5,200.25,16.0,8.0,17.0,9.0", receivedAt: now))
        #expect(raw.firstFrame == 10)
        #expect(raw.frames.count == 2)
        #expect(raw.timestamp == now)
        #expect(raw.processID == nil)
        #expect(abs((raw.fps ?? 0) - 2000 / 33) < 0.001)
        #expect(MetalHUDLog.parseLine("some other log line") == nil)
        #expect(MetalHUDLog.parseLine("   ") == nil)
        #expect(MetalHUDLog.parseMessage("metal-HUD: 1,2") == nil, "the header needs three fields")
        #expect(MetalHUDLog.parseMessage("metal-HUD: 1,2,3,16.0")?.frames.isEmpty == true, "an unpaired trailing value is dropped")
        #expect(MetalHUDLog.parseMessage("metal-HUD: 1,2,3,x,y") == nil)
        let mixed = MetalHUDLog.parse("junk\nmetal-HUD: 1,2,3,16,8\n{\"eventMessage\":\"metal-HUD: 2,2,3,16,8\",\"processID\":7}\n{\"eventMessage\":\"other\"}\n")
        #expect(mixed.count == 2)
        #expect(mixed.last?.processID == 7)
        let stamped = try #require(MetalHUDLog.parseNDJSON(#"{"eventMessage":"metal-HUD: 3,1,1,10,5","timestamp":"2026-10-13 15:35:10Z","processID":9}"#))
        #expect(stamped.timestamp == Self.utc(2026, 10, 13, 15, 35, 10))
        #expect(MetalHUDLog.parseLogTimestamp("2026-10-13 22:26:33.417324+0530") != nil)
        #expect(MetalHUDLog.parseLogTimestamp("2026-10-13 10:00:00-0200") == Self.utc(2026, 10, 13, 12, 0, 0))
        #expect(MetalHUDLog.parseLogTimestamp("garbage") == nil)
        #expect(MetalHUDLog.parseLogTimestamp("2026-10-13 10:00:00") == Self.utc(2026, 10, 13, 10, 0, 0), "no zone: UTC by default")
        #expect(MetalHUDLog.parseLogTimestamp("2026-10-13 10:00:00", assuming: Self.ist) == Self.utc(2026, 10, 13, 4, 30, 0))
        #expect(MetalHUDLog.parseLogTimestamp("2026-10-13 10:00:00Z", assuming: Self.ist) == Self.utc(2026, 10, 13, 10, 0, 0), "an explicit zone wins")
    }

    /// NSLog's stderr prefix: `date time name[pid:tid] message`, local time without a zone.
    @Test func parsesTheNSLogPrefix() throws {
        let line = "2026-10-14 01:50:56.707 wine[46721:2494548] metal-HUD: 103,6.28,174.84,16.67,0.00,8.33,0.00"
        let (prefix, message) = try #require(MetalHUDLog.parseNSLogPrefix(line, timeZone: Self.ist))
        #expect(prefix.processName == "wine" && prefix.processID == 46721 && prefix.threadID == 2494548)
        let expected = try #require(Self.utc(2026, 10, 13, 20, 20, 56)).addingTimeInterval(0.707)
        #expect(abs(prefix.timestamp.timeIntervalSince(expected)) < 0.001)
        #expect(message == "metal-HUD: 103,6.28,174.84,16.67,0.00,8.33,0.00")

        let sample = try #require(MetalHUDLog.parseNSLogLine(line, timeZone: Self.ist))
        #expect(sample.processID == 46721 && sample.firstFrame == 103 && sample.frameCount == 2)
        #expect(abs(try #require(sample.timestamp).timeIntervalSince(expected)) < 0.001)
        // `parseLine` prefers the prefix's time over `receivedAt`, and still stamps bare text with it.
        let now = Date()
        let viaLine = try #require(MetalHUDLog.parseLine(line, receivedAt: now, timeZone: Self.ist))
        #expect(viaLine.timestamp != now && viaLine.processID == 46721)
        #expect(MetalHUDLog.parseLine("metal-HUD: 1,2,3,16,8", receivedAt: now)?.timestamp == now)

        // A name with spaces, another process name, a zone-less time read in the zone given.
        let spaced = try #require(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56.707 My Game[12:34] hello world", timeZone: Self.ist))
        #expect(spaced.prefix.processName == "My Game" && spaced.prefix.processID == 12 && spaced.prefix.threadID == 34 && spaced.message == "hello world")
        #expect(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56 wine64-preloader[1:2] x")?.prefix.processName == "wine64-preloader")
        let utc = try #require(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56.707 wine[1:2] x", timeZone: TimeZone(secondsFromGMT: 0)!))
        #expect(utc.prefix.timestamp.timeIntervalSince(prefix.timestamp) == 5.5 * 3600)

        // Not NSLog lines: no date, a bad pid, a `log` line with a zone, an NSLog line without a HUD message.
        #expect(MetalHUDLog.parseNSLogPrefix("wine[46721:2494548] metal-HUD: 1,2,3") == nil)
        #expect(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56.707 wine[x:2494548] metal-HUD: 1,2,3") == nil)
        #expect(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56.707 wine[46721] metal-HUD: 1,2,3") == nil)
        #expect(MetalHUDLog.parseNSLogPrefix("2026-10-14 01:50:56.707 [46721:1] metal-HUD: 1,2,3") == nil)
        #expect(MetalHUDLog.parseNSLogPrefix("info:  Using feature level D3D_FEATURE_LEVEL_11_0") == nil)
        #expect(MetalHUDLog.parseNSLogLine("2026-10-14 01:42:45.872 wine[41884:2471409] [libMTLHud] Metric com.apple.hud-stat.fps already exist") == nil)
        #expect(MetalHUDLog.parseLine("2026-10-14 01:42:45.872 wine[41884:2471409] [libMTLHud] Metric already exist") == nil)
    }

    /// With the overlay drawn, every frame is logged as two identical pairs (even offsets); the
    /// hidden overlay logs one pair per frame.
    @Test func halvesDuplicatedPairs() throws {
        let a = MetalHUDFrame(intervalMs: 8.33, gpuTimeMs: 0.05)
        let b = MetalHUDFrame(intervalMs: 16.67, gpuTimeMs: 0.06)
        let c = MetalHUDFrame(intervalMs: 8.33, gpuTimeMs: 0.07)
        func sample(_ frames: [MetalHUDFrame]) -> MetalHUDSample {
            MetalHUDSample(firstFrame: 1, gfxMemoryMB: 1, processMemoryMB: 1, frames: frames)
        }
        #expect(sample([a, a, b, b]).hasDuplicatedPairs)
        #expect(sample([a, a, b, b]).halvingDuplicatePairs().frames == [a, b])
        #expect(!sample([a, b, b, a]).hasDuplicatedPairs, "pairs at odd offsets do not count")
        #expect(!sample([a, a, b]).hasDuplicatedPairs, "an odd count cannot be all couples")
        #expect(!sample([]).hasDuplicatedPairs)
        #expect(sample([a, b, c]).halvingDuplicatePairs().frames == [a, c], "halving drops every second pair regardless")
        #expect(sample([]).halvingDuplicatePairs().frames.isEmpty)
        #expect(try Self.hiddenSamples().allSatisfy { !$0.hasDuplicatedPairs })
        #expect(try Self.visibleSamples().allSatisfy(\.hasDuplicatedPairs))
    }

    /// Lines from several processes, and the unified log's two copies of each line.
    @Test func dominantProcessAndRepeats() throws {
        let frame = MetalHUDFrame(intervalMs: 8.33, gpuTimeMs: 0.05)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ pid: Int?, _ first: Int, _ offset: Double) -> MetalHUDSample {
            MetalHUDSample(timestamp: t0.addingTimeInterval(offset), processID: pid, firstFrame: first, gfxMemoryMB: 1, processMemoryMB: 1, frames: [frame, frame])
        }
        let launcher = [line(10, 1, 0), line(10, 3, 1)]
        let game = [line(20, 100, 2), line(20, 200, 3), line(20, 300, 4)]
        let mixed = [launcher[0], game[0], launcher[1], game[1], game[2]]
        #expect(MetalHUDTrace.dominantProcess(of: mixed) == game)
        #expect(MetalHUDTrace.dominantProcess(of: launcher) == launcher)
        // Equal line counts: the larger counter advance (the one rendering) wins.
        #expect(MetalHUDTrace.dominantProcess(of: [launcher[0], launcher[1], game[0], game[1]]) == [game[0], game[1]])
        #expect(MetalHUDTrace.counterStats(of: mixed)?.processID == 20)
        #expect(MetalHUDTrace.counterStats(of: mixed)?.frames == 200)

        let repeats = [line(20, 100, 2), line(20, 100, 2.0001), line(20, 200, 3), line(20, 200, 3.0001)]
        #expect(MetalHUDTrace.collapsingRepeats(repeats) == [repeats[0], repeats[2]])
        let counter = try #require(MetalHUDTrace.counterStats(of: repeats))
        #expect(counter.samples == 2 && counter.frames == 100 && abs(counter.wallS - 1) < 0.001)
        #expect(MetalHUDTrace.collapsingRepeats([line(20, 100, 2), line(21, 100, 2)]).count == 2, "another process is not a repeat")
    }

    @Test func counterStatsMedian() {
        func counter(_ frames: Int, _ wall: Double, _ pairs: Int) -> MetalHUDCounterStats {
            MetalHUDCounterStats(firstFrame: 100, lastFrame: 100 + frames, wallS: wall, samples: 5, pairs: pairs,
                                 minSegmentFPS: Double(frames) / wall * 0.9, maxSegmentS: 1, processID: 7)
        }
        let one = counter(600, 10, 600)
        #expect(one.frames == 600 && one.fps == 60 && one.pairsPerFrame == 1)
        #expect(counter(600, 10, 1200).pairsPerFrame == 2)
        #expect(counter(0, 10, 0).pairsPerFrame == nil && counter(0, 10, 0).fps == 0)
        #expect(one.summary == "counter 60.0 fps over 10.00 s (600 frames, 5 lines)")
        let median = MetalHUDCounterStats.median(of: [counter(500, 10, 500), counter(700, 10, 700), one])
        #expect(median?.fps == 60 && median?.frames == 600 && median?.pairs == 600 && median?.samples == 5)
        #expect(MetalHUDCounterStats.median(of: []) == nil)
        let reading = MetalHUDReading(stats: nil, counter: one)
        #expect(reading.fps == 60 && reading.fpsDisagreement == nil && reading.summary == one.summary && !reading.isEmpty)
    }

    /// Real `log stream --style ndjson` events (macOS 26.7.1, DXMT bottle, pid 41884): the frame
    /// list is private data, so only the header survives, and every interval arrives twice (the
    /// NSLog mirror with an empty subsystem, then the `com.apple.metal.hud` os_log copy).
    @Test func acceptsRedactedUnifiedLogLines() throws {
        let samples = try MetalHUDLog.parse(file: Fixtures.url("hudlogs/logstream-redacted.ndjson"))
        #expect(samples.count == 4)
        #expect(samples.map(\.firstFrame) == [54, 54, 103, 103])
        #expect(samples.allSatisfy { $0.frames.isEmpty && $0.processID == 41884 && $0.timestamp != nil })
        #expect(samples.first?.gfxMemoryMB == 6.52)
        #expect(samples.first?.processMemoryMB == 174.75)
        #expect(samples.first?.fps == nil)
        let trace = MetalHUDTrace(samples: samples)
        #expect(trace.stats() == nil, "a redacted line carries no frames")
        #expect(MetalHUDLog.parseMessage("metal-HUD: 54,6.52,174.75<private>")?.frameCount == 0)
        #expect(MetalHUDLog.parseMessage("metal-HUD: 54,6.52<private>") == nil, "the header still needs three fields")

        // The header fields still give the frame-counter rate: 49 frames between the two
        // distinct lines (0.408 s apart; the overlay was drawn), the repeats collapsed.
        let counter = try #require(trace.counterStats())
        #expect(counter.samples == 2 && counter.firstFrame == 54 && counter.lastFrame == 103 && counter.frames == 49)
        #expect(abs(counter.wallS - 0.408279) < 0.0001)
        #expect(abs(counter.fps - 120.016) < 0.01)
        #expect(counter.pairs == 0 && counter.pairsPerFrame == nil)
        let reading = trace.reading()
        #expect(reading.stats == nil && reading.counter == counter && reading.fps == counter.fps && reading.fpsDisagreement == nil)
        #expect(reading.summary.hasPrefix("counter 120.0 fps over 0.41 s (49 frames, 2 lines)"))
        let end = try #require(trace.last).addingTimeInterval(1)
        #expect(trace.sustained(minFPS: 100, seconds: 0.4, endingAt: end)?.counter?.frames == 49, "a header-only trace can still be judged by its counter")
        #expect(trace.sustained(minFPS: 100, seconds: 0.5, endingAt: end) == nil)
        #expect(trace.sustained(minFPS: 130, seconds: 0.4, endingAt: end) == nil)
    }

    /// Real lines from a bottle's wine log (the process's stderr, `MTL_HUD_HIDDEN=1` so one pair
    /// per frame): NSLog's `date time wine[pid:tid]` prefix gives every line its time (local,
    /// read in the capture's zone) and pid; the frame counter over those times agrees with the
    /// intervals. The probe's own stdout lines in the file end in CRLF, NSLog's in LF.
    @Test func parsesWineStderrLines() throws {
        #expect(try Fixtures.text("hudlogs/wine-stderr-hidden.log").contains("\r\n"), "the fixture mixes CRLF and LF, as wine logs do")
        let samples = try Self.hiddenSamples()
        #expect(samples.count == 3)
        #expect(samples.map(\.firstFrame) == [103, 201, 299])
        #expect(samples.map(\.frameCount) == [98, 98, 98])
        #expect(samples.map(\.processID) == [46721, 46721, 46721])
        #expect(samples.first?.frames.first == MetalHUDFrame(intervalMs: 16.67, gpuTimeMs: 0))
        // 2026-10-14 01:50:56.707 IST is 2026-10-13 20:20:56.707 UTC (the launch header says 20:20:55Z).
        let first = try #require(samples.first?.timestamp)
        #expect(abs(first.timeIntervalSince(try #require(Self.utc(2026, 10, 13, 20, 20, 56)).addingTimeInterval(0.707))) < 0.001)
        let last = try #require(samples.last?.timestamp)
        #expect(abs(last.timeIntervalSince(first) - 1.633) < 0.001)
        #expect(try MetalHUDLog.parse(file: Fixtures.url("hudlogs/wine-stderr-hidden.log"), timeZone: TimeZone(secondsFromGMT: 0)!)
                    .first?.timestamp?.timeIntervalSince(first) == 5.5 * 3600, "the zone is the caller's to give")

        let trace = MetalHUDTrace(samples: samples)
        let stats = try #require(trace.stats())
        #expect(stats.frames == 294)
        #expect(stats.samples == 3)
        #expect(abs(stats.durationS - 2.45736) < 0.0001)
        #expect(abs(stats.avgFPS - 119.64059) < 0.001)
        #expect(stats.p99IntervalMs == 8.33)
        #expect(abs(stats.p50FPS - 1000 / 8.33) < 0.001)
        #expect(stats.maxIntervalMs == 16.67)
        #expect(abs(stats.gpuTimeMeanMs - 0.06259) < 0.0001)

        // 196 frames (103 → 299) over 1.633 s: 120.0 fps, one pair per frame, 0.82 s per line.
        let counter = try #require(trace.counterStats())
        #expect(counter.firstFrame == 103 && counter.lastFrame == 299 && counter.frames == 196 && counter.samples == 3)
        #expect(abs(counter.wallS - 1.633) < 0.001)
        #expect(abs(counter.fps - 120.024) < 0.01)
        #expect(counter.pairs == 196 && counter.pairsPerFrame == 1)
        #expect(abs(counter.minSegmentFPS - 98 / 0.817) < 0.01)
        #expect(abs(counter.maxSegmentS - 0.817) < 0.001)
        #expect(counter.processID == 46721)
        let reading = trace.reading()
        #expect(try #require(reading.fpsDisagreement) < 0.01, "intervals and counter agree")
        #expect(reading.summary == stats.summary + "; " + counter.summary)
        #expect(BenchHarness.crossCheckNotes(reading, hudVisible: false).isEmpty)

        // Sustained by the counter: the three lines span 1.633 s.
        let end = last.addingTimeInterval(1)
        let sustained = try #require(trace.sustained(minFPS: 100, seconds: 1.5, endingAt: end))
        #expect(sustained.counter?.frames == 196 && sustained.stats?.frames == 294)
        let shorter = try #require(trace.sustained(minFPS: 100, seconds: 0.5, endingAt: end))
        #expect(shorter.counter?.frames == 98 && shorter.stats?.frames == 196, "two lines are enough for half a second")
        #expect(trace.sustained(minFPS: 100, seconds: 2, endingAt: end) == nil, "not enough history")
        #expect(trace.sustained(minFPS: 121, seconds: 1, endingAt: end) == nil, "119.95 fps on one stretch is below 121")
        #expect(trace.sustained(minFPS: 100, seconds: 1, endingAt: end.addingTimeInterval(5)) == nil, "stale")
        #expect(trace.sustained(minFPS: 100, seconds: 1, endingAt: end.addingTimeInterval(5), staleAfter: 10) != nil)
    }

    /// Real lines with the overlay drawn (same probe, `MTL_HUD_HIDDEN` unset): 98 pairs per
    /// line as before, but the counter advances 49 per line and every pair comes twice. Halved,
    /// the lines agree with the counter; unhalved, the cross-check says so.
    @Test func visibleOverlayLinesHalve() throws {
        let samples = try Self.visibleSamples()
        #expect(samples.count == 4)
        #expect(samples.map(\.firstFrame) == [54, 103, 152, 201])
        #expect(samples.allSatisfy { $0.frameCount == 98 && $0.processID == 41884 && $0.hasDuplicatedPairs })
        let raw = MetalHUDTrace(samples: samples)
        let rawCounter = try #require(raw.counterStats())
        #expect(rawCounter.frames == 147 && abs(rawCounter.wallS - 1.225) < 0.001 && abs(rawCounter.fps - 120) < 0.01)
        #expect(rawCounter.pairs == 294 && rawCounter.pairsPerFrame == 2)
        let rawNotes = BenchHarness.crossCheckNotes(raw.reading(), hudVisible: false)
        #expect(rawNotes.count == 1 && rawNotes[0].contains("2.00 pairs per counted frame") && rawNotes[0].contains("--hud-visible"))
        #expect(try #require(raw.reading().fpsDisagreement) < 0.05, "a rate per pair still reads 120 fps: only the pair count betrays the doubling")

        let halved = MetalHUDTrace(samples: samples.map { $0.halvingDuplicatePairs() })
        let stats = try #require(halved.stats())
        #expect(stats.frames == 196)
        #expect(abs(stats.durationS - 1.63231) < 0.0001)
        #expect(abs(stats.avgFPS - 120.0752) < 0.001)
        let counter = try #require(halved.counterStats())
        #expect(counter == MetalHUDCounterStats(firstFrame: 54, lastFrame: 201, wallS: rawCounter.wallS, samples: 4, pairs: 147,
                                                minSegmentFPS: rawCounter.minSegmentFPS, maxSegmentS: rawCounter.maxSegmentS, processID: 41884))
        #expect(counter.pairsPerFrame == 1)
        #expect(BenchHarness.crossCheckNotes(halved.reading(), hudVisible: true).isEmpty)
        // Halving a hidden-overlay trace is caught the same way.
        let wrongly = MetalHUDTrace(samples: try Self.hiddenSamples().map { $0.halvingDuplicatePairs() })
        let wrongNotes = BenchHarness.crossCheckNotes(wrongly.reading(), hudVisible: true)
        #expect(wrongNotes.count == 1 && wrongNotes[0].contains("0.50 pairs per counted frame") && wrongNotes[0].contains("hidden"))
    }

    @Test func percentilesAndMedians() {
        #expect(MetalHUDTrace.percentile([5, 1, 4, 2, 3], 50) == 3)
        #expect(MetalHUDTrace.percentile([5, 1, 4, 2, 3], 99) == 5)
        #expect(MetalHUDTrace.percentile([5, 1, 4, 2, 3], 0) == 1)
        #expect(MetalHUDTrace.percentile([], 50) == nil)
        #expect(MetalHUDTrace.median([1, 2, 3, 4]) == 2.5)
        #expect(MetalHUDTrace.median([3, 1, 2]) == 2)
        #expect(MetalHUDTrace.median([]) == nil)
        #expect(MetalHUDTrace.stats(of: []) == nil)
        func stats(_ frames: Int, _ avg: Double, _ low: Double) -> MetalHUDStats {
            MetalHUDStats(frames: frames, avgFPS: avg, p1LowFPS: low, p50FPS: avg, gpuTimeMeanMs: 5, durationS: 1, samples: 1,
                          p99IntervalMs: 1000 / low, maxIntervalMs: 60)
        }
        let median = MetalHUDStats.median(of: [stats(10, 50, 20), stats(30, 70, 40), stats(20, 60, 30)])
        #expect(median?.avgFPS == 60)
        #expect(median?.p1LowFPS == 30)
        #expect(median?.frames == 20)
        #expect(MetalHUDStats.median(of: []) == nil)
    }
}
