// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors
//   (changeWinVersion, changeBuildVersion, winVersion)

import Foundation

/// The prefix's Windows version: `winecfg -v <win7|win8|win81|win10|win11>` plus an optional
/// build override. On the CrossOver 26.3.0 tree `winecfg -v win10` itself writes
/// `CurrentBuild(Number)=19045`, `CurrentVersion=6.3`, `CurrentMajor/MinorVersionNumber=10/0`,
/// `ProductName="Windows 10 Pro"`, `UBR=5796` and `ProductOptions\ProductType="WinNT"` under
/// `HKLM\Software\Microsoft\Windows NT\CurrentVersion` (`programs/winecfg/appdefaults.c:54`,
/// `454-466`), so none of `crossover.inf`'s `[VersionInfo10]` values are copied by the init
/// batch (REA L-38; decision 24).
public enum WinVersion {
    public static let currentVersionKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#

    /// The build each version reports, for the override and for the integration test's
    /// `CurrentBuild=19045` check (what the CX tree's winecfg writes for win10, REA L-38; the
    /// other rows are upstream winecfg's table).
    public static let defaultBuilds: [WindowsVersion: Int] = [
        .win7: 7601, .win8: 9200, .win81: 9600, .win10: 19045, .win11: 22631,
    ]

    public static func defaultBuild(for version: WindowsVersion) -> Int? { defaultBuilds[version] }

    /// The two REG_SZ values a build override writes (pure).
    public static func buildEntries(_ build: Int) -> [RegistryEntry] {
        [.string(currentVersionKey, "CurrentBuild", String(build)),
         .string(currentVersionKey, "CurrentBuildNumber", String(build))]
    }

    /// `winecfg -v <version>`, then `CurrentBuild`/`CurrentBuildNumber` when `currentBuild` is given.
    public static func set(_ version: WindowsVersion, runner: WineRunner, currentBuild: Int? = nil) async throws {
        try await runner.runToolChecked(["winecfg", "-v", version.rawValue])
        if let currentBuild {
            try await Registry(runner: runner).apply(buildEntries(currentBuild))
        }
    }

    /// `winecfg -v` with no argument prints the current version name; nil when it is not one we know.
    public static func current(runner: WineRunner) async throws -> WindowsVersion? {
        let result = try await runner.runToolChecked(["winecfg", "-v"])
        return parse(result.stdout)
    }

    /// The last non-empty line of `winecfg -v` output as a `WindowsVersion` (pure).
    public static func parse(_ output: String) -> WindowsVersion? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return WindowsVersion(rawValue: last.lowercased())
    }

    /// `CurrentBuild` as stored in the prefix, or nil.
    public static func currentBuild(runner: WineRunner) async throws -> String? {
        try await Registry(runner: runner).query(key: currentVersionKey, name: "CurrentBuild")
    }
}
