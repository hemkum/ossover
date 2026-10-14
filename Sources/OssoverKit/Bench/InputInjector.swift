// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation

/// Brings a program's windows to the front and types a key into them (Return on the main
/// menu's "Continue" loads the benchmark save). Posting keyboard events needs Accessibility
/// access for the process running ossover; `requireAccessibility()` says so when it is missing.
public enum InputInjector {
    /// Keys the harness can press, by their macOS virtual key code.
    public enum Key: String, Codable, CaseIterable, Sendable {
        case `return`, enter, space, escape, tab

        public var keyCode: CGKeyCode {
            switch self {
            case .return: return 36
            case .enter: return 76
            case .space: return 49
            case .escape: return 53
            case .tab: return 48
            }
        }
    }

    public static let accessibilityHint =
        "Grant Accessibility access to the process running ossover (System Settings > Privacy & Security > "
        + "Accessibility; for a terminal session that is the terminal app), then run again, or pass --manual-load."

    /// `AXIsProcessTrusted`: whether this process may post keyboard events.
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Throws `OssoverError.unsupported` with the fix when Accessibility is not granted.
    public static func requireAccessibility() throws {
        guard isTrusted() else {
            throw OssoverError.unsupported("Accessibility access is not granted, so no key can be sent to the game. \(accessibilityHint)")
        }
    }

    /// Activates the application that owns `pid` (all its windows to the front). Returns
    /// whether macOS accepted the request; throws when no such process is running.
    @discardableResult
    public static func activate(pid: pid_t) async throws -> Bool {
        try await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw OssoverError.missing("process \(pid) is not running")
            }
            return app.activate(options: [.activateAllWindows])
        }
    }

    /// Posts a key-down then key-up to the HID event tap (what a real keyboard does, so Wine's
    /// Mac driver sees it in whichever window is frontmost). `hold` is the time between the two.
    public static func pressKey(_ key: Key, modifiers: CGEventFlags = [], hold: TimeInterval = 0.06) async throws {
        try requireAccessibility()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: false) else {
            throw OssoverError.io("cannot create a keyboard event for \(key.rawValue)")
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        try await sleep(hold)
        up.post(tap: .cghidEventTap)
    }

    /// The pid of the application that currently owns the keyboard, nil when none is frontmost.
    public static func frontmostPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    /// Activates `pid`, waits `settle` for the window server to switch focus, checks that
    /// `pid` really is frontmost, then presses `key`. Throws `.unsupported` when macOS declined
    /// the activation or something else holds the front (on macOS 14+ a command-line process
    /// may not be allowed to raise another app): a blind key press would land in whatever is
    /// frontmost — the terminal running ossover — so no key is sent in that case.
    public static func press(_ key: Key, inApplication pid: pid_t, settle: TimeInterval = 1.0,
                             modifiers: CGEventFlags = []) async throws {
        try requireAccessibility()
        guard try await activate(pid: pid) else {
            throw OssoverError.unsupported("macOS did not activate process \(pid), so the \(key.rawValue) key was not sent (run from a terminal that may activate other apps, or pass --manual-load)")
        }
        try await sleep(settle)
        let front = await frontmostPID()
        guard front == pid else {
            throw OssoverError.unsupported("process \(pid) is not frontmost after activation (pid \(front.map(String.init) ?? "none") is), so the \(key.rawValue) key was not sent; pass --manual-load")
        }
        try await pressKey(key, modifiers: modifiers)
    }

    static func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            throw OssoverError.cancelled
        }
    }
}
