// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import OssoverKit

struct RecipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipe",
        abstract: "Apply a recipe (settings, registry, files, programs) to a bottle.",
        subcommands: [List.self, Apply.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Recipes in the repository's recipes/ directory.")

        @OptionGroup var global: GlobalOptions
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let recipes = try Catalog.recipes(in: try RepoRoot.require())
            if json { return try Console.json(recipes.map(\.recipe)) }
            Console.table(["ID", "Title", "Requires", "Steps", "File"], recipes.map { entry in
                let requires = entry.recipe.requires.capabilities + entry.recipe.requires.renderers.map(\.rawValue)
                return [entry.recipe.id, entry.recipe.title, Format.list(requires), String(entry.recipe.steps.count), entry.url.lastPathComponent]
            })
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Plan and apply a recipe to a bottle (--dry-run prints the plan only).")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "Recipe id (witcher3-4.04-dx11), file stem (witcher3) or a path to a recipe JSON.") var recipe: String
        @Option(help: "Bottle to apply to.") var bottle: String
        @Flag(name: .customLong("dry-run"), help: "Print the resolved actions without changing anything.") var dryRun = false
        @Flag(help: "Do not echo winetricks output.") var quiet = false

        func run() async throws {
            let paths = global.paths
            let recipe = try Catalog.recipe(self.recipe)
            let session = try BottleSession.open(bottle, paths: paths)
            let installed = Set(session.availablePacks().map(\.kind)).union([.wined3d])
            // Paths under %USERPROFILE% depend on the Windows user wineboot created (`crossover`
            // on CrossOver-derived engines, the login name elsewhere), so the prefix is booted
            // before planning; a dry run on an unbooted prefix plans with the engine's expected name.
            if recipe.usesUserProfile, !dryRun { try await session.ensurePrefix() }
            let userName = Prefix.userName(layout: session.layout, engine: session.engine)
            if recipe.usesUserProfile, !session.layout.prefixInitialised {
                Console.note("prefix not booted; %USERPROFILE% is planned for user \(userName)")
            }
            let actions = try RecipeEngine.plan(recipe, bottle: session.bottle, engine: session.engine, paths: paths,
                                                installedRenderers: installed, userName: userName)
            print("recipe \(recipe.id): \(recipe.title)")
            print("plan for bottle \(session.bottle.name) (engine \(session.engine.id)): \(actions.count) action(s)")
            for (index, action) in actions.enumerated() {
                print(String(format: "%3d. ", index + 1) + action.summary)
            }
            if dryRun { return }

            var wine: (any RecipeWineOperations)?
            if actions.contains(where: \.needsWine) {
                try await session.ensurePrefix()
                wine = WineRecipeOperations(runner: session.runner, paths: paths, streamWinetricks: !quiet)
            }
            let report = try await RecipeEngine.apply(actions, recipe: recipe, bottle: session.bottle, engine: session.engine,
                                                      paths: paths, wine: wine, log: Console.logger)
            // Decision 19 (REA L-30, L-31): a wineserver started under the old sync mode must go
            // too, even when the plan ran no Wine process (`.setSync` is not `needsWine`), or the
            // next launch is refused for the WINEMSYNC mismatch. `session.runner` still carries the
            // pre-recipe bottle, i.e. the mode the live server was started with.
            if wine != nil || report.changedSync(from: session.bottle) {
                let shutdown = try await session.runner.shutdown()
                Console.note(shutdown.summary)
            }
            print("applied \(report.applied.id) (\(report.applied.version)) to \(report.bottle.name): "
                  + "\(report.performed.count) performed, \(report.skipped.count) skipped")
            for line in report.skipped { print("skipped: \(line)") }
            for note in report.notes { print("note: \(note)") }
            if !report.bottle.programs.isEmpty {
                print("programs: " + report.bottle.programs.map(\.id).joined(separator: ", ") + " (ossover run \(report.bottle.name) <id>)")
            }
        }
    }
}
