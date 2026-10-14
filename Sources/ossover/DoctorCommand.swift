// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check this Mac for what ossover needs: Rosetta 2, engines, renderers, steamcmd, cabextract, Accessibility.")

    @OptionGroup var global: GlobalOptions
    @Flag(help: "Print the checks as JSON.") var json = false

    func run() async throws {
        let checks = await Doctor.run(paths: global.paths)
        if json {
            try Console.json(checks)
        } else {
            Console.table(["Check", "Status", "Detail"], checks.map { [$0.name, $0.status.rawValue, $0.detail] })
        }
        let failed = checks.filter { $0.required && $0.status != .ok }
        guard failed.isEmpty else {
            Console.note("\(failed.count) required check(s) failed: " + failed.map(\.name).joined(separator: ", "))
            throw failure()
        }
    }
}

/// One row of `ossover doctor`.
struct DoctorCheck: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Present and usable.
        case ok
        /// Needed and absent.
        case missing
        /// Absent, but only some commands need it.
        case warn
        /// Informational.
        case info
    }

    var name: String
    var status: Status
    /// A failing required check makes `doctor` exit 1.
    var required: Bool
    var detail: String
}

enum Doctor {
    static let mingwExecutable = "x86_64-w64-mingw32-gcc"
    static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func run(paths: OssoverPaths) async -> [DoctorCheck] {
        let info = await SysInfo.current()
        var checks: [DoctorCheck] = [machine(info), rosetta(info), home(paths)]
        let engines = EngineStore(paths: paths).list(log: Console.logger)
        checks.append(enginesCheck(engines))
        checks.append(renderersCheck(engines: engines, paths: paths))
        checks.append(DoctorCheck(name: "Bottles", status: .info, required: false,
                                  detail: paths.bottleNames().isEmpty ? "none" : paths.bottleNames().joined(separator: ", ")))
        checks.append(repository())
        checks.append(steamcmd())
        checks.append(depotDownloader(paths))
        checks.append(cabextract())
        checks.append(winetricks(paths))
        checks.append(mingw())
        checks.append(accessibility())
        checks.append(screenRecording())
        return checks
    }

    static func machine(_ info: SysInfo) -> DoctorCheck {
        DoctorCheck(name: "macOS", status: .info, required: false,
                    detail: "\(info.macOSVersion) (\(info.macOSBuild)), \(info.chipBrand), \(info.cpuCount) cores, \(String(format: "%.0f", info.memoryGB)) GB")
    }

    static func rosetta(_ info: SysInfo) -> DoctorCheck {
        guard info.isAppleSilicon else {
            return DoctorCheck(name: "Rosetta 2", status: .info, required: false, detail: "Intel Mac: not needed")
        }
        let installed = info.rosettaInstalled ?? false
        return DoctorCheck(name: "Rosetta 2", status: installed ? .ok : .missing, required: true,
                           detail: installed ? "installed (x86_64 engines run)" : "softwareupdate --install-rosetta --agree-to-license")
    }

    static func home(_ paths: OssoverPaths) -> DoctorCheck {
        do {
            try paths.ensureLayout()
            return DoctorCheck(name: "Home", status: .ok, required: true, detail: paths.home.path)
        } catch {
            return DoctorCheck(name: "Home", status: .missing, required: true, detail: "\(paths.home.path): \(error.localizedDescription)")
        }
    }

    static func enginesCheck(_ engines: [Engine]) -> DoctorCheck {
        guard !engines.isEmpty else {
            return DoctorCheck(name: "Engines", status: .missing, required: true,
                               detail: "none installed: ossover engine install x64-frankea-wine11.16-cx26.3-v4.6.4b1")
        }
        let detail = engines.map { "\($0.id) (wine \($0.manifest.wineVersion), \($0.capabilities.enabled.joined(separator: " ")))" }
        return DoctorCheck(name: "Engines", status: .ok, required: true, detail: detail.joined(separator: "; "))
    }

    static func renderersCheck(engines: [Engine], paths: OssoverPaths) -> DoctorCheck {
        let store = RendererStore(paths: paths)
        let bundled = engines.flatMap { engine in
            RendererResolver.bundledPacks(engine: engine).map { "\($0.kind.rawValue) \($0.manifest.version) (bundled in \(engine.id))" }
        }
        let installed = store.list(log: Console.logger).map { pack in
            pack.id + (store.isUsable(pack) ? "" : " (unusable: \(store.unusableReason(pack) ?? "?"))")
        }
        let all = bundled + installed
        return DoctorCheck(name: "Renderers", status: all.isEmpty ? .warn : .ok, required: false,
                           detail: all.isEmpty ? "none: ossover renderer install dxmt-0.80 (wined3d always works)" : all.joined(separator: "; "))
    }

    static func repository() -> DoctorCheck {
        if let repo = RepoRoot.locate() {
            return DoctorCheck(name: "Repository", status: .ok, required: false, detail: repo.path)
        }
        return DoctorCheck(name: "Repository", status: .warn, required: false,
                           detail: "not found: engines/renderers/recipes resolve by id only from the checkout (set \(RepoRoot.environmentKey))")
    }

    static func steamcmd() -> DoctorCheck {
        if let url = SteamCMD.locate() {
            return DoctorCheck(name: "steamcmd", status: .ok, required: false, detail: url.path)
        }
        return DoctorCheck(name: "steamcmd", status: .warn, required: false, detail: "not found (steam branches/fetch): \(SteamCMD.installHint)")
    }

    static func depotDownloader(_ paths: OssoverPaths) -> DoctorCheck {
        if DepotDownloader.isInstalled(paths: paths) {
            return DoctorCheck(name: "DepotDownloader", status: .ok, required: false, detail: DepotDownloader.toolURL(paths: paths).path)
        }
        return DoctorCheck(name: "DepotDownloader", status: .info, required: false,
                           detail: "not installed (fallback for steam fetch --tool depotdownloader): \(DepotDownloader.installHint(paths: paths))")
    }

    static func cabextract() -> DoctorCheck {
        if let url = Winetricks.locateCabextract() {
            return DoctorCheck(name: "cabextract", status: .ok, required: false, detail: url.path)
        }
        return DoctorCheck(name: "cabextract", status: .warn, required: false, detail: "not found (winetricks needs it): brew install cabextract")
    }

    static func winetricks(_ paths: OssoverPaths) -> DoctorCheck {
        if let url = Winetricks.locate(paths: paths, repoRoot: RepoRoot.locate()) {
            return DoctorCheck(name: "winetricks", status: .ok, required: false, detail: url.path)
        }
        return DoctorCheck(name: "winetricks", status: .warn, required: false,
                           detail: Winetricks.missingScriptError(paths: paths).errorDescription ?? "script not found")
    }

    static func mingw() -> DoctorCheck {
        let found = toolDirectories.map { URL(fileURLWithPath: $0).appending(path: mingwExecutable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        let detail = found.map { "\($0.path) (only engine/build.sh uses it)" } ?? "not found; not required (only engine/build.sh needs mingw-w64)"
        return DoctorCheck(name: "mingw-w64", status: .info, required: false, detail: detail)
    }

    static func accessibility() -> DoctorCheck {
        if InputInjector.isTrusted() {
            return DoctorCheck(name: "Accessibility", status: .ok, required: false, detail: "trusted (bench run can press keys)")
        }
        return DoctorCheck(name: "Accessibility", status: .warn, required: false,
                           detail: "not granted (bench run needs it to load the save, or use --manual-load): " + InputInjector.accessibilityHint)
    }

    static func screenRecording() -> DoctorCheck {
        if Screenshot.hasScreenRecordingAccess() {
            return DoctorCheck(name: "Screen Recording", status: .ok, required: false, detail: "granted (smoke/bench screenshots)")
        }
        return DoctorCheck(name: "Screen Recording", status: .warn, required: false,
                           detail: "not granted: smoke/bench screenshots come back black (System Settings > Privacy & Security > Screen Recording), or pass smoke --no-screenshot")
    }
}
