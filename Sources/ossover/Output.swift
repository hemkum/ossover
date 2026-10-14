// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OssoverKit

/// stdout is for results (tables, JSON, streamed logs); stderr is for progress and errors, so
/// `ossover engine list --json | jq` stays clean.
enum Console {
    static func error(_ message: String) { errorRaw("error: " + message) }

    static func errorRaw(_ text: String) {
        fflush(stdout)  // keep stderr lines in order with buffered stdout when piped
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// A progress or log line.
    static func note(_ message: String) { errorRaw(message) }

    static func warn(_ message: String) { errorRaw("warning: " + message) }

    /// A `log` callback for the stores and the harness.
    static let logger: @Sendable (String) -> Void = { note($0) }

    static func json<T: Encodable>(_ value: T) throws {
        print(String(decoding: try JSONDocument.encode(value), as: UTF8.self))
    }

    static func table(_ header: [String], _ rows: [[String]]) {
        print(Table.render(header: header, rows: rows))
    }

    /// `key  value` pairs, aligned.
    static func pairs(_ rows: [(String, String)]) {
        let width = rows.map(\.0.count).max() ?? 0
        for (key, value) in rows {
            print(key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
        }
    }

    /// Asks a yes/no question on the terminal; false when stdin is not interactive.
    static func confirm(_ prompt: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print(prompt + " [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    /// Writes raw bytes (a streamed wine log) to stdout.
    static func stream(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }
}

/// Plain-text tables: a header, a dashed rule, left-aligned columns separated by two spaces.
enum Table {
    static func render(header: [String], rows: [[String]]) -> String {
        let columns = header.count
        var widths = header.map(\.count)
        for row in rows {
            for (index, cell) in row.prefix(columns).enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        func line(_ cells: [String]) -> String {
            var out = ""
            for index in 0..<columns {
                let cell = index < cells.count ? cells[index] : ""
                out += index == columns - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) + "  "
            }
            return Self.trimmingTrailingSpaces(out)
        }
        // The last column is unpadded, so its rule is capped: a long free-text cell (doctor's
        // Detail) must not draw a screen-wide dash line.
        let ruleWidths = widths.enumerated().map { index, width in
            index == columns - 1 ? min(width, max(header[index].count, 24)) : width
        }
        var lines = [line(header), line(ruleWidths.map { String(repeating: "-", count: $0) })]
        lines += rows.map(line)
        return lines.joined(separator: "\n")
    }

    static func trimmingTrailingSpaces(_ text: String) -> String {
        var out = Substring(text)
        while out.last == " " { out.removeLast() }
        return String(out)
    }

    static func yesNo(_ flag: Bool) -> String { flag ? "yes" : "no" }
}

/// One live-updating download line on stderr, at most twice a second.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var lastPrint = Date.distantPast
    private var printed = false
    private var finished = false

    init(label: String) { self.label = label }

    var handler: DownloadProgressHandler { { [self] progress in self.update(progress) } }

    func update(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let complete = progress.total.map { progress.received >= $0 } ?? false
        guard !finished, complete || now.timeIntervalSince(lastPrint) >= 0.5 else { return }
        lastPrint = now
        printed = true
        var text = "\r\(label): \(Self.megabytes(progress.received)) MB"
        if let total = progress.total {
            text += " / \(Self.megabytes(total)) MB (\(Int(((progress.fraction ?? 0) * 100).rounded()))%)"
        }
        FileHandle.standardError.write(Data(text.padding(toLength: max(text.count, 60), withPad: " ", startingAt: 0).utf8))
        if complete {
            finished = true
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    /// Ends the line when the download stopped short of `total` (a reused archive, an error).
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard printed, !finished else { return }
        finished = true
        FileHandle.standardError.write(Data("\n".utf8))
    }

    static func megabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

/// Duration formatting for tables.
enum Format {
    static func seconds(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f s", value)
    }

    static func fps(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func optional(_ value: String?) -> String { value ?? "-" }

    static func optional(_ value: Bool?) -> String { value.map(Table.yesNo) ?? "-" }

    static func list(_ values: [String]) -> String { values.isEmpty ? "-" : values.joined(separator: ",") }
}
