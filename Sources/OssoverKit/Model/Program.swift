// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a program is started.
public enum LaunchMode: String, Codable, CaseIterable, Sendable {
    /// `wine <unix exe path> args` with the parent attached: exit code, logs, pid (the default).
    case direct
    /// `wine start /unix <exe> args`: detached, for launchers that re-exec themselves.
    case start
}

/// A runnable entry of a bottle. `exe` is a Windows path (`C:\Games\X\x.exe`), possibly with
/// `${gameDir}`, `%USERPROFILE%` or `${engine}` to expand (see `WindowsPath.expand`).
public struct Program: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var exe: String
    public var args: [String]
    /// Windows path; defaults to the exe's directory when nil.
    public var workingDir: String?
    /// Merged on top of the bottle's env for this program only.
    public var env: [String: String]
    public var launchMode: LaunchMode

    public init(id: String? = nil, name: String, exe: String, args: [String] = [], workingDir: String? = nil,
                env: [String: String] = [:], launchMode: LaunchMode = .direct) {
        self.id = id ?? Program.slug(name)
        self.name = name
        self.exe = exe
        self.args = args
        self.workingDir = workingDir
        self.env = env
        self.launchMode = launchMode
    }

    enum CodingKeys: String, CodingKey { case id, name, exe, args, workingDir, env, launchMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        exe = try c.decode(String.self, forKey: .exe)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Program.slug(name)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        launchMode = try c.decodeIfPresent(LaunchMode.self, forKey: .launchMode) ?? .direct
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(exe, forKey: .exe)
        try c.encode(args, forKey: .args)
        try c.encodeIfPresent(workingDir, forKey: .workingDir)
        try c.encode(env, forKey: .env)
        try c.encode(launchMode, forKey: .launchMode)
    }

    /// "The Witcher 3" → "the-witcher-3": lowercase ASCII letters, digits and dashes.
    public static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "program" : out
    }

    public func validate() throws {
        guard !id.isEmpty, EngineManifest.isValidID(id) else { throw OssoverError.invalid("program id '\(id)' is not valid") }
        guard !name.isEmpty else { throw OssoverError.invalid("program \(id): name is empty") }
        guard !exe.isEmpty else { throw OssoverError.invalid("program \(id): exe is empty") }
        for key in env.keys where key.isEmpty || key.contains("=") {
            throw OssoverError.invalid("program \(id): env has an invalid variable name '\(key)'")
        }
    }
}
