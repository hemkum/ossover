// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Whisky WhiskyKit/Sources/WhiskyKit/Utils/Rosetta2.swift (GPL-3.0),
//   Copyright © 2023–2025 Isaac Marovitz and Whisky contributors

import Darwin
import Foundation

/// What `ossover doctor` and the benchmark report record about this Mac.
public struct SysInfo: Sendable, Equatable, Codable {
    public var macOSVersion: String
    public var macOSBuild: String
    public var chipBrand: String
    public var isAppleSilicon: Bool
    public var cpuCount: Int
    public var memoryGB: Double
    /// Nil when not probed (`current(probeRosetta: false)`).
    public var rosettaInstalled: Bool?

    public init(macOSVersion: String, macOSBuild: String, chipBrand: String, isAppleSilicon: Bool, cpuCount: Int,
                memoryGB: Double, rosettaInstalled: Bool?) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.chipBrand = chipBrand
        self.isAppleSilicon = isAppleSilicon
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.rosettaInstalled = rosettaInstalled
    }

    /// Reads everything; the Rosetta probe runs a process and takes a few ms.
    public static func current(probeRosetta: Bool = true) async -> SysInfo {
        SysInfo(macOSVersion: macOSVersionString(), macOSBuild: macOSBuild(), chipBrand: chipBrand(),
                isAppleSilicon: isAppleSilicon(), cpuCount: cpuCount(), memoryGB: memoryGB(),
                rosettaInstalled: probeRosetta ? await rosettaInstalled() : nil)
    }

    /// "macOS 26.7.1 (25G241), Apple M5 Pro, 16 cores, 24 GB, Rosetta: yes".
    public var summary: String {
        let rosetta = rosettaInstalled.map { $0 ? "yes" : "no" } ?? "not probed"
        return "macOS \(macOSVersion) (\(macOSBuild)), \(chipBrand), \(cpuCount) cores, \(Self.formatGB(memoryGB)) GB, Rosetta: \(rosetta)"
    }

    static func formatGB(_ gb: Double) -> String {
        gb == gb.rounded() ? String(Int(gb)) : String(format: "%.1f", gb)
    }

    // MARK: Probes

    /// "26.7.1".
    public static func macOSVersionString() -> String { Version.currentMacOS.description }

    /// "25G241" (`kern.osversion`).
    public static func macOSBuild() -> String { sysctlString("kern.osversion") ?? "" }

    /// `machdep.cpu.brand_string`: "Apple M5 Pro".
    public static func chipBrand() -> String { sysctlString("machdep.cpu.brand_string") ?? "unknown" }

    /// `hw.optional.arm64`, falling back to the architecture this binary was built for.
    public static func isAppleSilicon() -> Bool {
        if let flag = sysctlInt("hw.optional.arm64") { return flag != 0 }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static func cpuCount() -> Int { ProcessInfo.processInfo.processorCount }

    /// Physical memory in GB (base 1024), one decimal.
    public static func memoryGB() -> Double {
        (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10
    }

    public static let rosettaRuntimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    /// Whether the Rosetta runtime file is on disk. Cheap; `rosettaInstalled()` is the real test.
    public static func rosettaRuntimePresent() -> Bool {
        FileManager.default.fileExists(atPath: rosettaRuntimePath)
    }

    /// Runs `/usr/bin/arch -x86_64 /usr/bin/true`: exit 0 means x86-64 code can run here. On an
    /// Intel Mac that is trivially true; on Apple silicon it is true only with Rosetta installed
    /// ("Bad CPU type in executable" otherwise).
    public static func rosettaInstalled() async -> Bool {
        guard let result = try? await Shell.run(executable: "/usr/bin/arch", args: ["-x86_64", "/usr/bin/true"], timeout: 15) else {
            return false
        }
        return result.succeeded
    }

    // MARK: sysctl

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sysctlInt(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= MemoryLayout<Int64>.size else { return nil }
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }
}
