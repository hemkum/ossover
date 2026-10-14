// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/HighballKit/EngineStore.swift and DownloadResume.swift (GPL-3.0),
//   Copyright © 2026 Gauthier Piarrette

import Foundation

/// Bytes received so far and the total when the server (or the manifest) says what it is.
public struct DownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let total: Int64?

    public init(received: Int64, total: Int64?) {
        self.received = received
        self.total = total
    }

    /// 0...1 when the total is known, nil otherwise.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

public typealias DownloadProgressHandler = @Sendable (DownloadProgress) -> Void

/// Resumable HTTP downloads into `downloads/`, verified against the manifest's SHA-256.
///
/// Bytes land in `<name>.partial`; a second attempt (same run or a later one) asks for the rest
/// with a `Range` header. The checksum at the end is the integrity backstop, so a bad resume can
/// never install: a mismatch removes the file so the next attempt starts clean. This is the only
/// place in OssoverKit that touches the network.
public enum Download {
    public static let partialExtension = "partial"
    public static let defaultAttempts = 3
    /// A connection that sends nothing for this long is dropped and retried.
    public static let noDataTimeout: TimeInterval = 60
    public static let resourceTimeout: TimeInterval = 6 * 3600
    /// Progress is reported every this many bytes (and at the end).
    public static let progressInterval: Int64 = 1 << 21

    // MARK: Pure helpers

    /// `<destination>.partial`.
    public static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension(partialExtension)
    }

    /// `Range: bytes=<have>-` when a partial exists, nothing otherwise.
    public static func rangeHeaders(partialBytes: Int64) -> [String: String] {
        partialBytes > 0 ? ["Range": "bytes=\(partialBytes)-"] : [:]
    }

    public enum ResumeDecision: Equatable, Sendable {
        /// 206 with a partial on disk: keep appending.
        case append
        /// 200: the server sent the whole thing (or ignored the range); start from zero.
        case restart
        /// 416 with a partial on disk: the partial already holds every byte; the checksum decides.
        case complete
        case failed(status: Int)
    }

    /// What to do with the response to a (possibly ranged) request.
    public static func decide(status: Int, partialBytes: Int64) -> ResumeDecision {
        switch status {
        case 206: return partialBytes > 0 ? .append : .restart
        case 200: return .restart
        case 416: return partialBytes > 0 ? .complete : .failed(status: status)
        default: return .failed(status: status)
        }
    }

    /// Size of a file, nil when it does not exist.
    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    // MARK: Sources

    /// The verified local archive of `source`: for a `file://` URL the file itself (hashed in place,
    /// never copied), otherwise `downloads/<file name>`, downloaded unless a verified copy is
    /// already there. Throws `checksumMismatch` when the bytes do not match the pin.
    public static func fetch(_ source: ArtifactSource, into downloads: URL, attempts: Int = defaultAttempts,
                             progress: DownloadProgressHandler? = nil) async throws -> URL {
        try source.validate()
        guard source.isPinned else {
            throw OssoverError.invalid("\(source.fileName): source.sha256 is not pinned (TBD); pin the hash before installing")
        }
        if source.url.isFileURL {
            try verify(file: source.url, against: source)
            return source.url
        }
        let destination = downloads.appending(path: source.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? verify(file: destination, against: source)) != nil {
                progress?(DownloadProgress(received: source.size ?? 0, total: source.size))
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }
        try await download(from: source.url, to: destination, expectedSize: source.size, attempts: attempts, progress: progress)
        do {
            try verify(file: destination, against: source)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Size (when the source states one) and SHA-256 of a file against its pin.
    public static func verify(file: URL, against source: ArtifactSource) throws {
        guard let actualSize = fileSize(file) else { throw OssoverError.missing(file.path) }
        if let expected = source.size, expected != actualSize {
            throw OssoverError.checksumMismatch(file: file.lastPathComponent,
                                                expected: "\(source.sha256) (\(expected) bytes)",
                                                actual: "\(actualSize) bytes")
        }
        try SHA256Hasher.verify(file: file, expected: source.sha256)
    }

    // MARK: Transfer

    /// Downloads `url` to `destination`, resuming a `.partial` beside it, with up to `attempts`
    /// tries and a short backoff between them. Does not verify anything; `fetch` does.
    public static func download(from url: URL, to destination: URL, expectedSize: Int64? = nil,
                                attempts: Int = defaultAttempts, progress: DownloadProgressHandler? = nil) async throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw OssoverError.io("cannot create \(destination.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        if url.isFileURL {
            try? fm.removeItem(at: destination)
            do {
                try fm.copyItem(at: url, to: destination)
            } catch {
                throw OssoverError.io("cannot copy \(url.path): \(error.localizedDescription)")
            }
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw OssoverError.invalid("unsupported URL scheme for download: \(url.absoluteString)")
        }

        let partial = partialURL(for: destination)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = noDataTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            do {
                try await attemptOnce(url: url, partial: partial, expectedSize: expectedSize, session: session, progress: progress)
                lastError = nil
                break
            } catch let error as OssoverError where error == .cancelled {
                throw error
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(for: .seconds(2 * attempt))
                }
            }
        }
        if let lastError { throw lastError }

        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: partial, to: destination)
        } catch {
            throw OssoverError.io("cannot move \(partial.lastPathComponent) into place: \(error.localizedDescription)")
        }
    }

    /// One attempt: append to the partial when the server honours the range, restart from zero
    /// when it does not.
    static func attemptOnce(url: URL, partial: URL, expectedSize: Int64?, session: URLSession,
                            progress: DownloadProgressHandler?) async throws {
        let have = fileSize(partial) ?? 0
        var request = URLRequest(url: url)
        for (name, value) in rangeHeaders(partialBytes: have) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let sink = try DownloadSink(url: url, partial: partial, partialBytes: have, expectedSize: expectedSize, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = sink
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Writes one data task's bytes to a partial file as they arrive and settles a continuation when
/// the task ends. Delegate callbacks come on the session's queue; the lock keeps the file handle
/// and the counters consistent with them.
final class DownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let partial: URL
    private let expectedSize: Int64?
    private let progress: DownloadProgressHandler?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64
    private var total: Int64?
    private var lastReported: Int64
    private var failure: Error?
    private var completeByRange = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL, partial: URL, partialBytes: Int64, expectedSize: Int64?, progress: DownloadProgressHandler?) throws {
        self.url = url
        self.partial = partial
        self.expectedSize = expectedSize
        self.progress = progress
        self.written = partialBytes
        self.lastReported = partialBytes
        self.total = expectedSize
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw OssoverError.io("cannot create \(partial.path)") }
        }
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            throw OssoverError.io("cannot open \(partial.path) for writing: \(error.localizedDescription)")
        }
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func report(force: Bool = false) {
        lock.lock()
        let shouldReport = force || written - lastReported >= Download.progressInterval
        if shouldReport { lastReported = written }
        let snapshot = DownloadProgress(received: written, total: total)
        lock.unlock()
        if shouldReport { progress?(snapshot) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.lock()
            failure = OssoverError.network("no HTTP response for \(url.absoluteString)")
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let decision = Download.decide(status: http.statusCode, partialBytes: written)
        let length = http.expectedContentLength
        var disposition: URLSession.ResponseDisposition = .allow
        switch decision {
        case let .failed(status):
            failure = OssoverError.network("HTTP \(status) for \(url.absoluteString)")
            disposition = .cancel
        case .complete:
            completeByRange = true
            disposition = .cancel
        case .restart:
            do {
                try handle?.truncate(atOffset: 0)
                written = 0
                lastReported = 0
                total = length >= 0 ? length : expectedSize
            } catch {
                failure = OssoverError.io("cannot truncate \(partial.path): \(error.localizedDescription)")
                disposition = .cancel
            }
        case .append:
            do {
                try handle?.seekToEnd()
                total = length >= 0 ? written + length : expectedSize
            } catch {
                failure = OssoverError.io("cannot seek in \(partial.path): \(error.localizedDescription)")
                disposition = .cancel
            }
        }
        lock.unlock()
        completionHandler(disposition)
        if disposition == .allow { report(force: true) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
        } catch {
            failure = OssoverError.io("cannot write \(partial.path): \(error.localizedDescription)")
            lock.unlock()
            dataTask.cancel()
            return
        }
        lock.unlock()
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error>
        if let failure {
            result = .failure(failure)
        } else if completeByRange {
            result = .success(())
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                result = .failure(OssoverError.cancelled)
            } else {
                result = .failure(OssoverError.network("\(url.absoluteString): \(error.localizedDescription)"))
            }
        } else {
            result = .success(())
        }
        let pending = continuation
        continuation = nil
        lock.unlock()
        if case .success = result { report(force: true) }
        pending?.resume(with: result)
    }
}
