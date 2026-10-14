// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// `HUDLogTail` follows a wine log as the launcher writes it: the HUD's full lines are parsed
/// on arrival, a partial line waits for its newline, and `--hud-visible` halves the pairs.
@Suite struct HUDLogTailTests {
    static let ist = MetalHUDLogTests.ist

    /// The fixture's lines, one per element, each with its own line ending (the probe's stdout
    /// lines are CRLF, NSLog's LF, as in a real wine log).
    static func lines(_ fixture: String) throws -> [String] {
        var lines: [String] = []
        var pending: [UInt8] = []
        for byte in try Fixtures.data("hudlogs/\(fixture)") {
            pending.append(byte)
            if byte == 0x0A {
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
        if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
        return lines
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test("lines are parsed as they are appended; a partial line waits for its newline")
    func followsAppends() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "wine.log")
        let tail = HUDLogTail(file: log, timeZone: Self.ist)
        tail.poll()
        #expect(tail.trace.isEmpty, "no file yet is not an error")

        let lines = try Self.lines("wine-stderr-hidden.log")
        let hud = lines.filter { $0.contains("metal-HUD:") }
        #expect(hud.count == 3)
        try "# header\n".write(to: log, atomically: true, encoding: .utf8)
        try Self.append(lines.filter { !$0.contains("metal-HUD:") }.joined(), to: log)
        tail.poll()
        #expect(tail.trace.isEmpty && tail.lineCountSoFar == 4, "chatter is read and skipped")

        try Self.append(hud[0] + hud[1], to: log)
        tail.poll()
        #expect(tail.sampleCount == 2)
        #expect(tail.trace.samples.map(\.firstFrame) == [103, 201])
        #expect(tail.trace.samples.allSatisfy { $0.processID == 46721 && $0.frameCount == 98 })
        let expected = try #require(MetalHUDLogTests.utc(2026, 10, 13, 20, 20, 56)).addingTimeInterval(0.707)
        #expect(abs(try #require(tail.trace.samples[0].timestamp).timeIntervalSince(expected)) < 0.001, "the NSLog time, read in the capture's zone")

        let third = hud[2]
        let cut = third.index(third.startIndex, offsetBy: 200)
        try Self.append(String(third[..<cut]), to: log)
        tail.poll()
        #expect(tail.sampleCount == 2, "a line without its newline is still being written")
        try Self.append(String(third[cut...]), to: log)
        tail.poll()
        #expect(tail.sampleCount == 3)
        #expect(tail.trace.counterStats()?.frames == 196)
        #expect(tail.unpairedLineCount == 0)

        // A trailing line without a newline is flushed by `stop`; polling after it is a no-op.
        try Self.append(String(hud[0].dropLast()), to: log)
        tail.poll()
        #expect(tail.sampleCount == 3)
        tail.stop()
        #expect(tail.sampleCount == 4)
        try Self.append(hud[1], to: log)
        tail.poll()
        #expect(tail.sampleCount == 4)
        tail.stop()
    }

    @Test("--hud-visible halves the duplicated pairs and counts lines that were not duplicated")
    func halvesPairs() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "wine.log")
        try Fixtures.text("hudlogs/wine-stderr-visible.log").write(to: log, atomically: true, encoding: .utf8)
        let tail = HUDLogTail(file: log, halvesPairs: true, timeZone: Self.ist)
        tail.poll()
        #expect(tail.sampleCount == 4)
        #expect(tail.trace.samples.allSatisfy { $0.frameCount == 49 })
        #expect(tail.unpairedLineCount == 0)
        let reading = tail.trace.reading()
        #expect(reading.counter?.pairsPerFrame == 1 && reading.stats?.frames == 196)
        #expect(BenchHarness.crossCheckNotes(reading, hudVisible: true).isEmpty)

        // Hidden-overlay lines under --hud-visible: halved anyway, but every one is counted as unpaired.
        try Self.append(try Fixtures.text("hudlogs/wine-stderr-hidden.log") + "\n", to: log)
        tail.poll()
        #expect(tail.sampleCount == 7 && tail.unpairedLineCount == 3)
        #expect(tail.trace.samples.suffix(3).allSatisfy { $0.frameCount == 49 })
        tail.stop()

        // Without the flag, nothing is halved.
        let plain = HUDLogTail(file: log, timeZone: Self.ist)
        plain.poll()
        #expect(plain.sampleCount == 7 && plain.trace.samples.allSatisfy { $0.frameCount == 98 } && plain.unpairedLineCount == 0)
        plain.stop()
    }

    @Test("fromEnd skips what the file already holds; a replaced file is read from its start")
    func fromEndAndReplacement() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "game.log")
        let hud = try Self.lines("wine-stderr-hidden.log").filter { $0.contains("metal-HUD:") }
        try (hud[0] + hud[1]).write(to: log, atomically: true, encoding: .utf8)
        let tail = HUDLogTail(file: log, fromEnd: true, timeZone: Self.ist)
        tail.poll()
        #expect(tail.trace.isEmpty, "hours of earlier play are not re-read")
        try Self.append(hud[2], to: log)
        tail.poll()
        #expect(tail.trace.samples.map(\.firstFrame) == [299])

        try hud[0].write(to: log, atomically: true, encoding: .utf8)   // shorter than what was read: a new file
        tail.poll()
        #expect(tail.trace.samples.map(\.firstFrame) == [299, 103])
        tail.stop()
    }

    @Test("the timer polls on its own until stopped")
    func timerPolls() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "wine.log")
        try "".write(to: log, atomically: true, encoding: .utf8)
        let tail = HUDLogTail.start(file: log, interval: 0.02, timeZone: Self.ist)
        let hud = try Self.lines("wine-stderr-hidden.log").filter { $0.contains("metal-HUD:") }
        try Self.append(hud[0], to: log)
        for _ in 0..<50 where tail.sampleCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tail.sampleCount == 1)
        tail.stop()
        try Self.append(hud[1], to: log)
        try await Task.sleep(for: .milliseconds(80))
        #expect(tail.sampleCount == 1, "stopped: nothing more is read")
        tail.stop()
    }
}
