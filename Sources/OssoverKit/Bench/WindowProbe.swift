// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Scripts/winlist.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette

import CoreGraphics
import Foundation

/// One window from `CGWindowListCopyWindowInfo`.
public struct WindowInfo: Sendable, Equatable, Codable {
    /// `kCGWindowNumber`, what `screencapture -l` takes.
    public var id: UInt32
    public var ownerPID: Int32
    public var ownerName: String
    /// `kCGWindowName`; empty or absent without Screen Recording access.
    public var name: String?
    /// Screen coordinates (origin top-left), points.
    public var bounds: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(id: UInt32, ownerPID: Int32, ownerName: String, name: String?, bounds: CGRect, layer: Int,
                alpha: Double, isOnScreen: Bool) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.name = name
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }

    public var area: Double { Double(bounds.width * bounds.height) }

    /// "1234 pid=567 wine |The Witcher 3| 2560x1600@0,25 layer=0".
    public var summary: String {
        "\(id) pid=\(ownerPID) \(ownerName) |\(name ?? "")| \(Int(bounds.width))x\(Int(bounds.height))@\(Int(bounds.minX)),\(Int(bounds.minY)) layer=\(layer)"
    }

    // `bounds` is written as {x, y, width, height}, not CGRect's nested arrays.
    enum CodingKeys: String, CodingKey { case id, ownerPID, ownerName, name, bounds, layer, alpha, isOnScreen }
    enum BoundsKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        ownerPID = try c.decode(Int32.self, forKey: .ownerPID)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        let b = try c.nestedContainer(keyedBy: BoundsKeys.self, forKey: .bounds)
        bounds = CGRect(x: try b.decode(Double.self, forKey: .x), y: try b.decode(Double.self, forKey: .y),
                        width: try b.decode(Double.self, forKey: .width), height: try b.decode(Double.self, forKey: .height))
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        alpha = try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
        isOnScreen = try c.decodeIfPresent(Bool.self, forKey: .isOnScreen) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ownerPID, forKey: .ownerPID)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encodeIfPresent(name, forKey: .name)
        var b = c.nestedContainer(keyedBy: BoundsKeys.self, forKey: .bounds)
        try b.encode(Double(bounds.minX), forKey: .x)
        try b.encode(Double(bounds.minY), forKey: .y)
        try b.encode(Double(bounds.width), forKey: .width)
        try b.encode(Double(bounds.height), forKey: .height)
        try c.encode(layer, forKey: .layer)
        try c.encode(alpha, forKey: .alpha)
        try c.encode(isOnScreen, forKey: .isOnScreen)
    }
}

/// Windows of a process, as the window server sees them: the smoke test's "a window appeared".
/// A Wine program's windows are owned by the Wine process (its `wine` loader pid), which may
/// be a child of the one we launched, so callers pass every pid of the prefix.
public enum WindowProbe {
    /// Windows smaller than this are helpers (tooltips, 1×1 IME windows), not the program.
    public static let defaultMinimumSize = CGSize(width: 64, height: 64)

    /// Every window the window server lists, on-screen ones only by default.
    public static func windows(onScreenOnly: Bool = true) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(parse)
    }

    /// Windows owned by any of `pids`, at least `minimumSize`, largest first.
    public static func windows(ownedByAny pids: Set<pid_t>, onScreenOnly: Bool = true,
                               minimumSize: CGSize = defaultMinimumSize) -> [WindowInfo] {
        select(windows(onScreenOnly: onScreenOnly), pids: pids, minimumSize: minimumSize)
    }

    public static func windows(ownedBy pid: pid_t, onScreenOnly: Bool = true,
                               minimumSize: CGSize = defaultMinimumSize) -> [WindowInfo] {
        windows(ownedByAny: [pid], onScreenOnly: onScreenOnly, minimumSize: minimumSize)
    }

    /// The biggest window of the processes: the game's, not its splash or console.
    public static func largestWindow(ownedByAny pids: Set<pid_t>, minimumSize: CGSize = defaultMinimumSize) -> WindowInfo? {
        windows(ownedByAny: pids, minimumSize: minimumSize).first
    }

    public static func largestWindow(ownedBy pid: pid_t, minimumSize: CGSize = defaultMinimumSize) -> WindowInfo? {
        largestWindow(ownedByAny: [pid], minimumSize: minimumSize)
    }

    /// True when `pid` has an on-screen window of at least `minimumSize`.
    public static func isOnScreen(_ pid: pid_t, minimumSize: CGSize = defaultMinimumSize) -> Bool {
        !windows(ownedBy: pid, minimumSize: minimumSize).isEmpty
    }

    /// Pure selection: owned by `pids`, visible, big enough, sorted by area (largest first).
    public static func select(_ windows: [WindowInfo], pids: Set<pid_t>, minimumSize: CGSize = defaultMinimumSize) -> [WindowInfo] {
        windows.filter { window in
            pids.contains(window.ownerPID) && window.alpha > 0
                && window.bounds.width >= minimumSize.width && window.bounds.height >= minimumSize.height
        }.sorted { $0.area > $1.area }
    }

    /// Polls until a window of the processes `pids()` returns shows up, or `timeout` passes.
    /// `pids` is asked again on every poll so a child process that appears later is covered.
    public static func waitForWindow(pids: @Sendable () async -> Set<pid_t>, timeout: TimeInterval, poll: TimeInterval = 0.5,
                                     minimumSize: CGSize = defaultMinimumSize) async throws -> WindowInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = largestWindow(ownedByAny: await pids(), minimumSize: minimumSize) { return window }
            do {
                try await Task.sleep(for: .seconds(poll))
            } catch {
                throw OssoverError.cancelled
            }
        } while Date() < deadline
        return nil
    }

    /// One `CGWindowListCopyWindowInfo` dictionary. Keys are the `kCGWindow*` constants' values.
    static func parse(_ dict: [String: Any]) -> WindowInfo? {
        guard let number = dict["kCGWindowNumber"] as? Int, number >= 0,
              let pid = dict["kCGWindowOwnerPID"] as? Int else { return nil }
        let boundsDict = dict["kCGWindowBounds"] as? [String: Any] ?? [:]
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
        let name = dict["kCGWindowName"] as? String
        return WindowInfo(
            id: UInt32(truncatingIfNeeded: number),
            ownerPID: Int32(truncatingIfNeeded: pid),
            ownerName: dict["kCGWindowOwnerName"] as? String ?? "",
            name: (name?.isEmpty ?? true) ? nil : name,
            bounds: bounds,
            layer: dict["kCGWindowLayer"] as? Int ?? 0,
            alpha: dict["kCGWindowAlpha"] as? Double ?? 1,
            isOnScreen: dict["kCGWindowIsOnscreen"] as? Bool ?? false)
    }
}
