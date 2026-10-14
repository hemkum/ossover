// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

/// The recipe `when` clause (CrossTie `useif platform|locale` + engine capabilities, REA L-67,
/// decisions 36/37) and the `status`/`reports` fields.
@Suite struct RecipeConditionTests {
    static let mac = RecipeHost(locale: "en_US")

    @Test("locale matches exactly or by language, ignoring case and separator")
    func localeMatching() {
        #expect(RecipeCondition.localeMatches("ja_JP", host: "ja_JP"))
        #expect(RecipeCondition.localeMatches("ja", host: "ja_JP"))
        #expect(RecipeCondition.localeMatches("ja-jp", host: "ja_JP"))
        #expect(RecipeCondition.localeMatches("ja", host: "ja"))
        #expect(!RecipeCondition.localeMatches("ja_JP", host: "ja"))
        #expect(!RecipeCondition.localeMatches("ja", host: "jam_X"))
        #expect(!RecipeCondition.localeMatches("en_GB", host: "en_US"))
        #expect(RecipeHost.normalisedLocale("en_US@rg=gbzzzz") == "en_US")
        #expect(RecipeHost.normalisedLocale("en-US") == "en_US")
        #expect(RecipeHost.normalisedLocale("C.UTF-8") == "C")
        #expect(RecipeHost.current.platform == RecipeHost.mac)
    }

    @Test("every given field must hold; the reasons name what did not")
    func unmetReasons() {
        let cx = Fixtures.crossOver
        let vanilla = Fixtures.vanillaEsync
        #expect(RecipeCondition(platform: "mac").holds(host: Self.mac, capabilities: vanilla))
        #expect(RecipeCondition(platform: "mac").unmet(host: RecipeHost(platform: "linux", locale: "en_US"), capabilities: cx)
                == ["platform is linux, not mac"])
        #expect(RecipeCondition(locale: "ja").unmet(host: Self.mac, capabilities: cx) == ["locale is en_US, not ja"])
        #expect(RecipeCondition(engineCapabilities: ["msync"]).holds(host: Self.mac, capabilities: cx))
        #expect(RecipeCondition(engineCapabilities: ["msync", "dllPathPrepend"]).unmet(host: Self.mac, capabilities: cx)
                == ["engine lacks capability dllPathPrepend"], "all-of")
        #expect(RecipeCondition(platform: "mac", locale: "ko", engineCapabilities: ["msync"]).unmet(host: Self.mac, capabilities: vanilla)
                == ["locale is en_US, not ko", "engine lacks capability msync"])
        #expect(RecipeCondition(platform: "mac", locale: "ko", engineCapabilities: ["msync", "wow64"]).summary
                == "when platform=mac, locale=ko, engineCapabilities=msync+wow64")
        #expect(RecipeCondition().isEmpty)
    }

    @Test("validation rejects empty, unknown-platform, unknown-capability and nested clauses")
    func validation() {
        #expect(throws: OssoverError.self) { try RecipeCondition().validate() }
        #expect(throws: OssoverError.self) { try RecipeCondition(platform: "macos").validate() }
        #expect(throws: OssoverError.self) { try RecipeCondition(engineCapabilities: ["esync", "turbo"]).validate() }
        #expect(throws: OssoverError.self) { try RecipeCondition(locale: "").validate() }
        #expect(throws: Never.self) { try RecipeCondition(platform: "mac", locale: "ja_JP", engineCapabilities: ["msync"]).validate() }

        let env = RecipeStep.env(name: "X", value: "1", scope: .bottle)
        let nested = Recipe(id: "nested", title: "N", steps: [
            .conditional(when: RecipeCondition(platform: "mac"), step: .conditional(when: RecipeCondition(locale: "ja"), step: env)),
        ])
        #expect(throws: OssoverError.self) { try nested.validate() }
        let badInner = Recipe(id: "inner", title: "I", steps: [
            .conditional(when: RecipeCondition(platform: "mac"), step: .env(name: "A=B", value: "1", scope: .bottle)),
        ])
        #expect(throws: OssoverError.self, "the wrapped step is validated too") { try badInner.validate() }
        let fine = Recipe(id: "fine", title: "F", steps: [.conditional(when: RecipeCondition(platform: "mac"), step: env)])
        #expect(throws: Never.self) { try fine.validate() }
    }

    @Test("a conditional step keeps the flat on-disk form: the step's keys plus `when` beside them")
    func conditionalStepRoundTrips() throws {
        let json = """
        {"schema":"ossover.recipe/1","id":"w","title":"W","steps":[
          {"type":"env","name":"WINE_WAIT_CHILD_PIPE_IGNORE","value":"steam.exe","scope":"bottle","when":{"engineCapabilities":["msync"]}},
          {"type":"program","name":"Game","exe":"C:\\\\g.exe","when":{"platform":"mac","locale":"ja"}},
          {"type":"note","text":"plain"}
        ]}
        """
        let recipe = try JSONDocument.decode(Recipe.self, from: Data(json.utf8))
        try recipe.validate()
        #expect(recipe.steps.count == 3)
        #expect(recipe.steps[0] == .conditional(when: RecipeCondition(engineCapabilities: ["msync"]),
                                                step: .env(name: "WINE_WAIT_CHILD_PIPE_IGNORE", value: "steam.exe", scope: .bottle)))
        #expect(recipe.steps[1] == .conditional(when: RecipeCondition(platform: "mac", locale: "ja"),
                                                step: .program(Program(name: "Game", exe: #"C:\g.exe"#))))
        #expect(recipe.steps[2] == .note(text: "plain"))
        #expect(recipe.steps.map(\.typeName) == ["env", "program", "note"], "typeName sees through the wrapper")
        #expect(recipe.steps[0].base == .env(name: "WINE_WAIT_CHILD_PIPE_IGNORE", value: "steam.exe", scope: .bottle))
        #expect(recipe.steps[0].condition == RecipeCondition(engineCapabilities: ["msync"]))
        #expect(recipe.steps[2].condition == nil)
        #expect(recipe.steps[0].summary == "env WINE_WAIT_CHILD_PIPE_IGNORE=steam.exe (bottle) [when engineCapabilities=msync]")
        #expect(recipe.programs.map(\.id) == ["game"], "programs sees through the wrapper")
        #expect(recipe.changesLaunchEnvironment)

        let data = try JSONDocument.encode(recipe)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""when" : {"#))
        #expect(!text.contains("conditional"))
        #expect(try JSONDocument.decode(Recipe.self, from: data) == recipe)
        // The encoder writes neither an empty `engineCapabilities` nor nil fields.
        let whenOnly = try JSONDocument.encode(RecipeCondition(platform: "mac"))
        #expect(String(decoding: whenOnly, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "{\n  \"platform\" : \"mac\"\n}")
    }

    @Test("status and reports are optional, validated and round-trip")
    func statusAndReports() throws {
        let json = """
        {"schema":"ossover.recipe/1","id":"s","title":"S","steps":[],"status":"partial","reports":[
          {"status":"works","date":"2026-10-14","engine":"x64-ossover-cx26.3-r1","renderer":"dxmt","macOS":"26.0","hardware":"M5 Pro","note":"novigrad 72 fps"},
          {"status":"broken","date":"2026-10-01","renderer":"dxvk"}
        ]}
        """
        let recipe = try JSONDocument.decode(Recipe.self, from: Data(json.utf8))
        try recipe.validate()
        #expect(recipe.status == .partial)
        #expect(recipe.reports.count == 2)
        #expect(recipe.reports[0] == CompatibilityReport(status: .works, date: "2026-10-14", engine: "x64-ossover-cx26.3-r1", renderer: .dxmt,
                                                         macOS: "26.0", hardware: "M5 Pro", note: "novigrad 72 fps"))
        #expect(recipe.reports[1].engine == nil)
        #expect(try JSONDocument.decode(Recipe.self, from: try JSONDocument.encode(recipe)) == recipe)

        let none = try JSONDocument.decode(Recipe.self, from: Data(#"{"schema":"ossover.recipe/1","id":"n","title":"N","steps":[]}"#.utf8))
        #expect(none.status == nil && none.reports.isEmpty)
        #expect(!String(decoding: try JSONDocument.encode(none), as: UTF8.self).contains("reports"), "empty reports are not written")

        var bad = recipe
        bad.reports.append(CompatibilityReport(status: .works, date: "14/10/2026"))
        #expect(throws: OssoverError.self) { try bad.validate() }
        #expect(!CompatibilityReport.isValidDate("2026-1-14"))
        #expect(CompatibilityReport.isValidDate("2026-01-14"))
        #expect(throws: OssoverError.self, "unknown status words are refused") {
            try JSONDocument.decode(Recipe.self, from: Data(#"{"schema":"ossover.recipe/1","id":"n","title":"N","steps":[],"status":"gold"}"#.utf8))
        }
    }

    @Test("the shipped recipes carry a status and the schema knows the new keys")
    func shippedRecipesAndSchema() throws {
        for name in ["witcher3", "witcher3-dxvk", "witcher3-vcrun", "steam"] {
            let recipe = try Recipe.load(from: Fixtures.repoRoot.appending(path: "recipes/\(name).json"))
            #expect(recipe.status == .untested, Comment(rawValue: name))
        }
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.repoRoot.appending(path: "recipes/_schema.json"))) as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?["status"] != nil && properties?["reports"] != nil)
        let definitions = schema?["definitions"] as? [String: Any]
        let when = definitions?["when"] as? [String: Any]
        let whenProperties = when?["properties"] as? [String: Any]
        #expect(Set((whenProperties ?? [:]).keys) == ["platform", "locale", "engineCapabilities"])
        let status = definitions?["status"] as? [String: Any]
        #expect((status?["enum"] as? [String]) == RecipeStatus.allCases.map(\.rawValue))
        let step = definitions?["step"] as? [String: Any]
        let branches = step?["oneOf"] as? [[String: Any]] ?? []
        #expect(branches.count == 13)
        #expect(branches.allSatisfy { ($0["properties"] as? [String: Any])?["when"] != nil }, "every step type takes a when clause")
    }
}
