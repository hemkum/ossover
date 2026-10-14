// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from highball Sources/highball/main.swift (GPL-3.0), Copyright © 2026 Gauthier Piarrette
//   (command tree: engine/bottle/run/recipe subcommands; failure reporting on stderr)

import ArgumentParser
import Foundation
import OssoverKit

/// `ossover` — the Phase 1 command-line front end over `OssoverKit` (plan §3 Phase 2 step 4).
///
/// Exit status: 0 when the command did what was asked, 1 when it failed (an `OssoverError`, a
/// failed smoke/bench verdict, a tool that exited non-zero), 2 for a usage problem.
@main
struct Ossover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ossover",
        abstract: "Run Windows games on macOS with Wine, DXMT and msync. Free software, no stores.",
        discussion: """
            Everything lives under $OSSOVER_HOME (default ~/Library/Application Support/ossover): engines, \
            renderer packs, bottles, downloads and logs. Manifests and recipes come from the repository \
            checkout (engines/*.json, renderers/*.json, recipes/*.json), found from the working directory \
            or $OSSOVER_REPO.
            """,
        version: "0.1.0",
        subcommands: [DoctorCommand.self, EngineCommand.self, RendererCommand.self, BottleCommand.self,
                      RunCommand.self, RecipeCommand.self, SteamCommand.self, SmokeCommand.self, BenchCommand.self])

    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            Foundation.exit(ExitStatus.ok)
        } catch {
            Foundation.exit(terminate(with: error))
        }
    }

    /// Prints `error` the way the user should see it and returns the process status: 0 for a
    /// help or version request, 2 for a usage problem, 1 for anything that failed.
    static func terminate(with error: Error) -> Int32 {
        let code = exitCode(for: error)
        if code.isSuccess {
            print(fullMessage(for: error))
            return ExitStatus.ok
        }
        if let exit = error as? ExitCode {
            return exit.rawValue == 0 ? ExitStatus.ok : exit.rawValue
        }
        if let ossoverError = error as? OssoverError {
            Console.error(ossoverError.errorDescription ?? String(describing: ossoverError))
            return ExitStatus.failure
        }
        if let validation = error as? ValidationError {
            // Thrown after parsing (a bad --set key): the message says it all, the root usage would mislead.
            Console.error(validation.message)
            return ExitStatus.usage
        }
        if code == .validationFailure {
            Console.errorRaw(fullMessage(for: error))
            return ExitStatus.usage
        }
        Console.error(fullMessage(for: error))
        return ExitStatus.failure
    }
}

enum ExitStatus {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

/// Options every leaf command takes.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("ossover home directory.", discussion: "Default: $OSSOVER_HOME, else ~/Library/Application Support/ossover."))
    var home: String?

    var paths: OssoverPaths {
        OssoverPaths(home: home.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) })
    }
}

/// A failed verdict or tool: the message is already printed, only the status is left.
func failure() -> ExitCode { ExitCode(ExitStatus.failure) }
