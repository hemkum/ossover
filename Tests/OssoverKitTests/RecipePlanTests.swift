// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct RecipePlanTests {
    static let paths = Fixtures.paths
    static let engine = Fixtures.engine(capabilities: Fixtures.crossOver)
    static let bottle = Bottle(name: "witcher3", engineID: "test-engine")
    static let prefix = "/ossover-test/bottles/witcher3/prefix"

    static func witcher() throws -> Recipe {
        try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/witcher3.json"))
    }

    @Test("recipes/witcher3.json plans to the expected action list")
    func witcherPlan() throws {
        let actions = try RecipeEngine.plan(try Self.witcher(), bottle: Self.bottle, engine: Self.engine, paths: Self.paths,
                                            installedRenderers: [.dxmt], userName: "tester", host: RecipeHost(locale: "en_US"))
        let settings = "\(Self.prefix)/drive_c/users/tester/Documents/The Witcher 3/user.settings"
        #expect(actions.map(\.summary) == [
            "set Windows version win10",
            "set sync msync",
            "set renderer dxmt",
            "set retina on, dpi 96",
            "bottle env ROSETTA_ADVERTISE_AVX=1",
            "write \(Self.prefix)/drive_c/Games/The Witcher 3/launcher-configuration.json",
            "ini \(settings) [Rendering] HairWorksLevel=0",
            "ini \(settings) [Viewport] Resolution=\"2560x1600\"",
            "ini \(settings) [Viewport] FullScreenMode=1",
            "ini \(settings) [Viewport] VSync=false",
            "program witcher3: C:\\Games\\The Witcher 3\\bin\\x64\\witcher3.exe --launcher-skip -skipStartScreen",
            "note: Saves live at <bottle>/prefix/drive_c/users/<you>/Documents/The Witcher 3/gamesaves.",
            "note: Keep HairWorks off (HairWorksLevel=0): it crashes under every Mac renderer.",
            "note: Use dxmt, not dxvk: DXVK on macOS makes sirens, rotfiends and hounds invisible (no transform feedback in MoltenVK).",
            "note: Never install the Steam client in this bottle; the depot was fetched with steamcmd and witcher3.exe runs DRM-free. A re-fetch without --allow-update is refused so Steam cannot move 4.04 to the DX12-only 5.x Remastered.",
            "note: The launcher-configuration.json fallback is rewritten every time this recipe runs; re-apply it after any fetch.",
        ])
        #expect(actions[0] == .setWindowsVersion(.win10))
        #expect(actions[1] == .setSync(.msync))
        #expect(actions[2] == .setRenderer(.dxmt))
        #expect(actions[3] == .setRetina(enabled: true, dpi: 96))
        #expect(actions[4] == .setBottleEnv(name: "ROSETTA_ADVERTISE_AVX", value: "1"))
        guard case let .writeFile(url, contents, ifMissing) = actions[5] else {
            Issue.record("action 5 is not writeFile: \(actions[5])")
            return
        }
        #expect(url.path == "\(Self.prefix)/drive_c/Games/The Witcher 3/launcher-configuration.json")
        #expect(contents == "{\n    \"fallback\": \"DirectX 11\"\n}\n")
        #expect(!ifMissing)
        guard case let .setIni(iniURL, section, key, value) = actions[7] else {
            Issue.record("action 7 is not setIni: \(actions[7])")
            return
        }
        #expect(iniURL.path == settings)
        #expect(section == "Viewport")
        #expect(key == "Resolution")
        #expect(value == "\"2560x1600\"")
        #expect(!actions.contains { if case .winetricks = $0 { return true } else { return false } },
                "vcrun lives in recipes/witcher3-vcrun.json, applied only on a missing-VCRUNTIME abort (plan §4)")
        #expect(actions[10] == .upsertProgram(Program(id: "witcher3", name: "The Witcher 3",
                                                      exe: #"C:\Games\The Witcher 3\bin\x64\witcher3.exe"#,
                                                      args: ["--launcher-skip", "-skipStartScreen"],
                                                      workingDir: #"C:\Games\The Witcher 3\bin\x64"#, env: [:], launchMode: .direct)))
        #expect(actions.filter { $0.needsWine }.count == 2, "winver and retina need Wine")
        #expect(try Self.witcher().usesUserProfile, "the ini steps live under %USERPROFILE%")
    }

    @Test("recipes/witcher3-dxvk.json is witcher3.json with renderer dxvk (decision 35, REA L-68)")
    func dxvkVariantMirrorsTheDXMTRecipe() throws {
        let dxmt = try Self.witcher()
        let dxvk = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/witcher3-dxvk.json"))
        #expect(dxvk.id == "witcher3-4.04-dx11-dxvk")
        #expect(dxvk.requires.renderers == [.dxvk])
        #expect(dxvk.requires.capabilities == dxmt.requires.capabilities)
        #expect(dxvk.gameDir == dxmt.gameDir)
        #expect(dxvk.status == .untested && dxmt.status == .untested)
        #expect(dxvk.knownIssues.contains { $0.symptom.contains("invisible") && $0.cause?.contains("stream output") == true },
                "the stream-output monsters are a known issue of this variant")
        func actions(_ recipe: Recipe) throws -> [RecipeAction] {
            try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: Self.engine, paths: Self.paths,
                                  installedRenderers: [.dxmt, .dxvk], userName: "tester", host: RecipeHost(locale: "en_US"))
                .filter { if case .note = $0 { return false } else { return true } }
        }
        let expected = try actions(dxmt).map { $0 == .setRenderer(.dxmt) ? RecipeAction.setRenderer(.dxvk) : $0 }
        #expect(try actions(dxvk) == expected, "every non-note action is the same but the renderer")
        #expect(try actions(dxvk).contains(.setRenderer(.dxvk)))
        #expect(throws: OssoverError.self, "needs a DXVK pack") {
            try RecipeEngine.plan(dxvk, bottle: Self.bottle, engine: Self.engine, paths: Self.paths, installedRenderers: [.dxmt], userName: "tester")
        }
    }

    @Test("recipes/steam.json follows the CX Steam tie: deps, msync, WINE_WAIT_CHILD_PIPE_IGNORE on CX-derived engines (decisions 21, 36)")
    func steamPlanOnACrossOverEngine() throws {
        let steam = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/steam.json"))
        #expect(steam.status == .untested)
        let actions = try RecipeEngine.plan(steam, bottle: Bottle(name: "steam", engineID: "test-engine"), engine: Self.engine,
                                            paths: Self.paths, userName: "tester", host: RecipeHost(locale: "en_US"))
        let summaries = actions.map(\.summary)
        #expect(summaries.contains("set sync msync"))
        #expect(actions.contains(.winetricks(verbs: ["corefonts", "vcrun2022", "d3dcompiler_47"], optional: false,
                                             note: "The CX Steam tie's dependencies (L-69): Core Fonts, VC++ latest x64 + x86 (vcrun2022 installs both bitnesses in one verb), d3dcompiler_47 for both bitnesses. Needs cabextract (brew install cabextract); the Asian Fonts dependency is not carried over.")))
        #expect(actions.contains(.setBottleEnv(name: "WINE_WAIT_CHILD_PIPE_IGNORE", value: "steam.exe")))
        #expect(actions.contains(.setBottleEnv(name: "CEF_DISABLE_SANDBOX", value: "1")))
        #expect(actions.contains(.setBottleEnv(name: "LC_ALL", value: "en_US.UTF-8")))
        #expect(!summaries.contains { $0.hasPrefix("skip ") })
        #expect(summaries.contains { $0.hasPrefix("note: CEF_DISABLE_SANDBOX=1 and LC_ALL=en_US.UTF-8 are ossover-specific") })
        #expect(summaries.contains { $0.hasPrefix("note: WINE_WAIT_CHILD_PIPE_IGNORE=steam.exe is set on CX-derived engines only") })
        #expect(!summaries.contains { $0.contains("set sync none") })
    }

    @Test("recipes/steam.json skips the CX-only variable on an engine without msync")
    func steamPlanSkipsTheCXOnlyEnvOnAVanillaEngine() throws {
        let steam = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/steam.json"))
        let vanilla = Fixtures.engine(capabilities: Fixtures.vanillaEsync)
        let actions = try RecipeEngine.plan(steam, bottle: Bottle(name: "steam", engineID: "test-engine"), engine: vanilla,
                                            paths: Self.paths, userName: "tester", host: RecipeHost(locale: "en_US"))
        #expect(!actions.contains(.setBottleEnv(name: "WINE_WAIT_CHILD_PIPE_IGNORE", value: "steam.exe")))
        let skipped = actions.compactMap { action -> (String, String)? in
            if case let .skipped(step, reason) = action { return (step, reason) } else { return nil }
        }
        #expect(skipped.count == 1)
        #expect(skipped.first?.0 == "env WINE_WAIT_CHILD_PIPE_IGNORE=steam.exe (bottle)")
        #expect(skipped.first?.1 == "engine lacks capability msync")
        #expect(actions.contains(.setBottleEnv(name: "CEF_DISABLE_SANDBOX", value: "1")), "the ossover-specific rows have no when clause")
        #expect(actions.contains(.setSync(.msync)), "sync stays msync in the recipe; the launcher downgrades it")
    }

    @Test("a skipped step is reported, not applied, and a program-scoped env with a false when stays off the program")
    func applyReportsSkippedSteps() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let created = try BottleStore(paths: paths).create(name: "when", engineID: "test-engine", requireEngine: false)
        let recipe = Recipe(id: "when-test", title: "W", steps: [
            .conditional(when: RecipeCondition(engineCapabilities: ["msync"]), step: .env(name: "CX_ONLY", value: "1", scope: .bottle)),
            .conditional(when: RecipeCondition(locale: "ja"), step: .env(name: "JP_ONLY", value: "1", scope: .program)),
            .conditional(when: RecipeCondition(platform: "mac"), step: .env(name: "MAC", value: "1", scope: .bottle)),
            .program(Program(name: "Game", exe: #"C:\Games\g.exe"#)),
        ])
        let vanilla = Fixtures.engine(capabilities: Fixtures.vanillaEsync)
        let actions = try RecipeEngine.plan(recipe, bottle: created, engine: vanilla, paths: paths, userName: "tester",
                                            host: RecipeHost(locale: "en_US"))
        #expect(actions.map(\.summary) == [
            "skip env CX_ONLY=1 (bottle): engine lacks capability msync",
            "skip env JP_ONLY=1 (program): locale is en_US, not ja",
            "bottle env MAC=1",
            "program game: C:\\Games\\g.exe",
        ])
        #expect(actions.contains(.upsertProgram(Program(name: "Game", exe: #"C:\Games\g.exe"#))), "JP_ONLY never reached the program")
        let report = try await RecipeEngine.apply(actions, recipe: recipe, bottle: created, engine: vanilla, paths: paths, wine: nil)
        #expect(report.skipped == ["env CX_ONLY=1 (bottle): engine lacks capability msync", "env JP_ONLY=1 (program): locale is en_US, not ja"])
        #expect(report.bottle.settings.env == ["MAC": "1"])
        #expect(report.performed.count == 2)

        // On a Japanese Mac with msync everything holds.
        let all = try RecipeEngine.plan(recipe, bottle: created, engine: Self.engine, paths: paths, userName: "tester",
                                        host: RecipeHost(locale: "ja_JP"))
        #expect(!all.contains { if case .skipped = $0 { return true } else { return false } })
        #expect(all.contains(.upsertProgram(Program(name: "Game", exe: #"C:\Games\g.exe"#, env: ["JP_ONLY": "1"]))))
    }

    @Test("decision 19: a sync-only plan runs no Wine process yet ends the wineserver lifetime (REA L-30, L-31)")
    func syncOnlyPlanChangesTheServerLifetime() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let created = try BottleStore(paths: paths).create(name: "sync", engineID: "test-engine", requireEngine: false)
        let target: SyncMode = created.settings.sync == .none ? .msync : .none
        let recipe = Recipe(id: "sync-only", title: "S", steps: [
            .sync(target),
            .renderer(.wined3d),
            .env(name: "A", value: "1", scope: .bottle),
            .program(Program(name: "Game", exe: #"C:\Games\g.exe"#)),
            .note(text: "n"),
        ])
        let actions = try RecipeEngine.plan(recipe, bottle: created, engine: Self.engine, paths: paths, userName: "tester")
        #expect(actions.contains(.setSync(target)))
        #expect(!actions.contains { $0.needsWine }, "`recipe apply` starts no Wine process for this plan, so `wine == nil` alone would miss the restart")
        let report = try await RecipeEngine.apply(actions, recipe: recipe, bottle: created, engine: Self.engine, paths: paths, wine: nil)
        #expect(report.bottle.settings.sync == target)
        #expect(report.changedSync(from: created), "the CLI stops the old-mode wineserver (-k → -w) before the next launch")

        // The same mode again: no lifetime change, nothing to restart.
        let same = Recipe(id: "sync-same", title: "S", steps: [.sync(target), .note(text: "n")])
        let sameActions = try RecipeEngine.plan(same, bottle: report.bottle, engine: Self.engine, paths: paths, userName: "tester")
        let sameReport = try await RecipeEngine.apply(sameActions, recipe: same, bottle: report.bottle, engine: Self.engine, paths: paths, wine: nil)
        #expect(sameReport.bottle.settings.sync == target)
        #expect(!sameReport.changedSync(from: report.bottle))
    }

    @Test("recipes/witcher3-vcrun.json carries the optional runtimes as its own recipe")
    func vcrunRecipe() throws {
        let recipe = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/witcher3-vcrun.json"))
        #expect(recipe.id == "witcher3-vcrun")
        #expect(!recipe.usesUserProfile)
        let actions = try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: Self.engine, paths: Self.paths, userName: "tester")
        #expect(actions.first == .winetricks(verbs: ["vcrun2019", "vcrun2013", "vcrun2012"], optional: false,
                                             note: "Only needed when the game aborts with a missing VCRUNTIME/MSVCP dll; Wine's builtin runtimes usually suffice."))
        #expect(actions.count == 2)
    }

    @Test func planRefusesUnmetRequirements() throws {
        let recipe = try Self.witcher()
        #expect(throws: OssoverError.self, "dxmt not installed") {
            try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: Self.engine, paths: Self.paths, installedRenderers: [], userName: "tester")
        }
        let vanilla = Fixtures.engine(capabilities: Fixtures.vanillaEsyncMacdrv)
        do {
            _ = try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: vanilla, paths: Self.paths, installedRenderers: [.dxmt], userName: "tester")
            Issue.record("an engine without msync must be refused")
        } catch let error as OssoverError {
            guard case let .unsupported(what) = error else {
                Issue.record("expected .unsupported, got \(error)")
                return
            }
            #expect(what.contains("msync"))
        }
    }

    @Test func planRefusesPathsOutsideThePrefix() {
        let escapes: [Recipe] = [
            Recipe(id: "z-drive", title: "Z", steps: [.file(path: #"Z:\etc\ossover-escape"#, contents: "x", ifMissing: false)]),
            Recipe(id: "dot-dot", title: "D", steps: [.ini(path: #"C:\..\..\outside.ini"#, section: nil, key: "k", value: "v")]),
            Recipe(id: "unresolved", title: "U", steps: [.file(path: #"${gameDir}\x.txt"#, contents: "", ifMissing: false)]),
            Recipe(id: "copy-out", title: "C", steps: [.copy(from: "/etc/hosts", to: #"C:\hosts"#)]),
        ]
        for recipe in escapes {
            #expect(throws: OssoverError.self, Comment(rawValue: recipe.id)) {
                try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: Self.engine, paths: Self.paths, userName: "tester")
            }
        }
    }

    @Test func allStepsFixturePlansWithProgramScopedEnvironment() throws {
        let recipe = try Recipe.load(from: Fixtures.url("recipes/all-steps.json"))
        let actions = try RecipeEngine.plan(recipe, bottle: Self.bottle, engine: Self.engine, paths: Self.paths, userName: "tester")
        #expect(actions.count == 14, "the program-scoped env step rides the program instead of being an action")
        #expect(actions.contains(.setBottleEnv(name: "FIXTURE_BOTTLE", value: "2")))
        #expect(actions.contains(.addDLLOverride("amd_ags_x64=")))
        #expect(actions.contains(.addRegistry(key: #"HKCU\Software\Fixture"#, name: "Flag", type: .dword, data: "1")))
        #expect(actions.contains(.upsertProgram(Program(id: "fixture-game", name: "Fixture Game", exe: #"C:\Games\Fixture\game.exe"#,
                                                        env: ["FIXTURE_PROGRAM": "1"], launchMode: .start))))
        let summaries = actions.map(\.summary)
        #expect(summaries.contains("copy /ossover-test/engines/test-engine/share/wine/fixture.dll → \(Self.prefix)/drive_c/windows/system32/fixture.dll"))
        #expect(summaries.contains("ini \(Self.prefix)/drive_c/Games/Fixture/game.ini [*] Fullscreen=0"))
        #expect(summaries.contains("write \(Self.prefix)/drive_c/Games/Fixture/note.txt (if missing)"))
        #expect(summaries.last == "note: done")
    }

    @Test func fingerprintIsStableAndContentSensitive() throws {
        let recipe = try Self.witcher()
        let fingerprint = try RecipeEngine.fingerprint(of: recipe)
        #expect(fingerprint.hasPrefix("sha256:"))
        #expect(fingerprint.count == "sha256:".count + 12)
        #expect(fingerprint == (try RecipeEngine.fingerprint(of: try Self.witcher())))
        var changed = recipe
        changed.title += "!"
        #expect(try RecipeEngine.fingerprint(of: changed) != fingerprint)
    }

    @Test func applyWithoutWineWritesFilesAndTheBottle() async throws {
        let home = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = OssoverPaths(home: home)
        let store = BottleStore(paths: paths)
        let created = try store.create(name: "apply", engineID: "test-engine", requireEngine: false)
        let layout = paths.bottleLayout("apply")
        let recipe = Recipe(id: "io-test", title: "IO", gameDir: #"C:\Games\IO"#, steps: [
            .sync(.none),
            .renderer(.wined3d),
            .env(name: "A", value: "1", scope: .bottle),
            .dlloverride(value: "foo=n"),
            .file(path: #"${gameDir}\a.txt"#, contents: "hello", ifMissing: false),
            .file(path: #"${gameDir}\a.txt"#, contents: "ignored", ifMissing: true),
            .ini(path: #"${gameDir}\g.ini"#, section: "S", key: "k", value: "v"),
            .program(Program(name: "IO Game", exe: #"${gameDir}\io.exe"#)),
            .note(text: "n"),
        ])
        let actions = try RecipeEngine.plan(recipe, bottle: created, engine: Self.engine, paths: paths, userName: "tester")
        #expect(!actions.contains { $0.needsWine })
        let report = try await RecipeEngine.apply(actions, recipe: recipe, bottle: created, engine: Self.engine, paths: paths, wine: nil)

        #expect(report.bottle.settings.sync == .none)
        #expect(report.bottle.settings.renderer == .wined3d)
        #expect(report.bottle.settings.env == ["A": "1"])
        #expect(report.bottle.settings.dllOverrides == ["foo=n"])
        #expect(report.bottle.programs.map(\.exe) == [#"C:\Games\IO\io.exe"#])
        #expect(report.bottle.recipesApplied == ["io-test"])
        #expect(report.bottle.recipeHistory.map(\.id) == ["io-test"])
        #expect(report.bottle.recipeHistory.first?.version == (try RecipeEngine.fingerprint(of: recipe)))
        #expect(report.notes == ["n"])
        #expect(report.skipped.isEmpty)
        #expect(report.performed.count == 8)
        let aTxt = layout.driveC.appending(path: "Games/IO/a.txt")
        #expect(report.performed.contains("kept existing \(aTxt.path)"))
        #expect(try String(contentsOf: aTxt, encoding: .utf8) == "hello")
        #expect(try String(contentsOf: layout.driveC.appending(path: "Games/IO/g.ini"), encoding: .utf8) == "[S]\nk=v\n")
        #expect(try store.load("apply") == report.bottle, "bottle.json on disk is what the report carries")

        let needsWine = Recipe(id: "needs-wine", title: "W", steps: [.winver(.win7)])
        let wineActions = try RecipeEngine.plan(needsWine, bottle: created, engine: Self.engine, paths: paths, userName: "tester")
        await #expect(throws: OssoverError.self) {
            try await RecipeEngine.apply(wineActions, recipe: needsWine, bottle: created, engine: Self.engine, paths: paths, wine: nil)
        }
    }
}
