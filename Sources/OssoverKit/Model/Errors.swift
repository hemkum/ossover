// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one error type OssoverKit throws. Every layer maps its failures onto these cases so the
/// CLI and the app can render them without knowing which subsystem failed.
public enum OssoverError: Error, LocalizedError, Equatable, Sendable {
    /// Malformed data or argument: a manifest that does not decode, a bad name, a bad path.
    case invalid(String)
    /// Something that should be there is not: an engine, a bottle, a file, a tool.
    case missing(String)
    /// Something that must not be there already is: a bottle being created twice.
    case alreadyExists(String)
    /// A filesystem operation failed.
    case io(String)
    /// A tool exited non-zero. `output` carries its combined stdout/stderr.
    case processFailed(command: String, status: Int32, output: String)
    /// A tool was killed because it overran its deadline.
    case timeout(command: String, seconds: Double)
    /// A downloaded or installed file does not match its pinned SHA-256.
    case checksumMismatch(file: String, expected: String, actual: String)
    /// An on-disk document carries a `schema` this build does not read.
    case unsupportedSchema(found: String, expected: String)
    /// The machine, engine or renderer cannot do what was asked (no Rosetta, no msync, ...).
    case unsupported(String)
    /// A download or HTTP failure.
    case network(String)
    /// A component gated behind a licence the user has not accepted (D3DMetal).
    case licenceNotAccepted(String)
    /// The caller cancelled.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .invalid(what): return "Invalid: \(what)"
        case let .missing(what): return "Missing: \(what)"
        case let .alreadyExists(what): return "Already exists: \(what)"
        case let .io(what): return "I/O error: \(what)"
        case let .processFailed(command, status, output):
            let tail = Self.tail(of: output)
            return "Command failed (exit \(status)): \(command)" + (tail.isEmpty ? "" : "\n\(tail)")
        case let .timeout(command, seconds):
            return "Command timed out after \(Self.format(seconds)) s: \(command)"
        case let .checksumMismatch(file, expected, actual):
            return "SHA-256 mismatch for \(file): expected \(expected), got \(actual)"
        case let .unsupportedSchema(found, expected):
            return "Unsupported document schema '\(found)' (this build reads '\(expected)')"
        case let .unsupported(what): return "Unsupported: \(what)"
        case let .network(what): return "Network error: \(what)"
        case let .licenceNotAccepted(what): return "Licence not accepted: \(what)"
        case .cancelled: return "Cancelled"
        }
    }

    /// The last few lines of a tool's output, enough to say why it failed without flooding a UI.
    static func tail(of output: String, lines: Int = 12) -> String {
        let all = output.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(lines).joined(separator: "\n")
    }

    static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
