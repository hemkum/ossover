// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Decision 18: the CrossOver bottle importer's mapping of `cxbottle.conf` (REA L-17, L-18,
// L-19, L-30, L-36, L-70; `upgrade_graphics_settings`, CXBT:448-467).

@Suite struct CrossOverBottleConfigTests {
    /// A `cxbottle.conf` in the template's shape: `[Bottle]` first, then `[EnvironmentVariables]`.
    static func conf(_ environment: String, trailing: String = "") -> String {
        """
        ;; CrossOver bottle configuration
        [Bottle]
        "Version" = "26.3.0.39832"
        "WindowsVersion" = "win10"
        "Timestamp" = "1760000000"

        [EnvironmentVariables]
        ; "PROMPT" = "$p$g"
        \(environment)
        \(trailing)
        """
    }

    @Test("CX_GRAPHICS_BACKEND maps onto the renderer choice: every value, quoted or bare, any case")
    func backendValues() {
        let expected: [(String, RendererChoice)] = [("auto", .auto), ("wined3d", .wined3d), ("dxvk", .dxvk), ("dxmt", .dxmt), ("d3dmetal", .d3dmetal)]
        for (value, choice) in expected {
            #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"\(value)\"")).renderer == choice)
            #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("CX_GRAPHICS_BACKEND=\(value)")).renderer == choice)
        }
        let loud = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"cx_graphics_backend\" = \"DXVK\""))
        #expect(loud.renderer == .dxvk, "section and key names are case-insensitive, the value is matched case-insensitively")
        #expect(loud.environment.isEmpty, "the mapped key is consumed")
        #expect(loud.notes.contains { $0.contains("REA L-17") })
    }

    @Test("legacy toggles: WINEDXVK wins over WINED3DMETAL/D3DMetal, and only when CX_GRAPHICS_BACKEND is undefined")
    func legacyToggles() {
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEDXVK\" = \"1\"")).renderer == .dxvk)
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINED3DMETAL\" = \"1\"")).renderer == .d3dmetal)
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"D3DMetal\" = \"1\"")).renderer == .d3dmetal)
        let tie = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINED3DMETAL\" = \"1\"\n\"WINEDXVK\" = \"1\""))
        #expect(tie.renderer == .dxvk, "upgrade_graphics_settings checks WINEDXVK first")
        #expect(tie.environment.isEmpty, "both legacy keys are consumed")
        #expect(tie.notes.contains { $0.contains("dxvk wins a tie") })

        let explicit = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"dxmt\"\n\"WINED3DMETAL\" = \"1\"\n\"WINEDXVK\" = \"1\""))
        #expect(explicit.renderer == .dxmt, "a defined CX_GRAPHICS_BACKEND is never overridden by the legacy keys")
        #expect(explicit.environment.isEmpty, "the legacy keys are still taken out")
        #expect(explicit.notes.filter { $0.contains("dropped legacy") }.count == 2)

        let off = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEDXVK\" = \"0\"\n\"WINED3DMETAL\" = \"yes\""))
        #expect(off.renderer == nil, "only the literal 1 counts")
        #expect(off.environment.isEmpty)
        #expect(off.notes.contains { $0.contains("not set to 1") })
    }

    @Test("an unknown backend is ignored with a note and does not fall back to the legacy keys")
    func unknownBackend() {
        let out = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"vkd3d\"\n\"WINEDXVK\" = \"1\""))
        #expect(out.renderer == nil)
        #expect(out.notes.contains { $0.contains("ignored CX_GRAPHICS_BACKEND=vkd3d") && $0.contains("auto|dxmt|dxvk|d3dmetal|wined3d") })
        #expect(out.environment.isEmpty, "neither the unknown value nor the legacy key is passed through")
    }

    @Test("WINEESYNC=1 becomes msync; WINEMSYNC is read as atoi; neither is passed through")
    func sync() {
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEESYNC\" = \"1\"")).sync == .msync)
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEMSYNC\" = \"1\"")).sync == .msync)
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEMSYNC\" = \"0\"")).sync == SyncMode.none)
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEMSYNC\" = \"2x\"")).sync == .msync, "atoi")
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEMSYNC\" = \"yes\"")).sync == SyncMode.none, "atoi(\"yes\") == 0")
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("")).sync == nil, "a fresh bottle has no sync key (SH-TT-68)")

        let esyncOff = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEESYNC\" = \"0\""))
        #expect(esyncOff.sync == nil)
        #expect(esyncOff.environment.isEmpty, "WINEESYNC never reaches an ossover bottle")
        #expect(esyncOff.notes.contains { $0.contains("dropped WINEESYNC=0") })

        let both = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"WINEMSYNC\" = \"0\"\n\"WINEESYNC\" = \"1\""))
        #expect(both.sync == .msync, "the migration writes WINEMSYNC=1 whenever WINEESYNC=1")
        #expect(both.environment.isEmpty)
    }

    @Test("CX_ACTIVE_GRAPHICS_BACKEND is never a setting")
    func activeBackendIgnored() {
        let out = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_ACTIVE_GRAPHICS_BACKEND\" = \"d3dmetal\""))
        #expect(out.renderer == nil)
        #expect(out.environment.isEmpty)
        #expect(out.notes.contains { $0.contains("ignored CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal") && $0.contains("REA L-19") })
    }

    @Test("<undef> deletes, a later assignment wins, other sections and comments are ignored, CRLF survives")
    func syntax() {
        let undef = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"dxvk\"\n\"CX_GRAPHICS_BACKEND\" = \"<undef>\"\n\"WINED3DMETAL\" = \"1\""))
        #expect(undef.renderer == .d3dmetal, "the deleted backend leaves the legacy toggle in charge")

        let later = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"dxvk\"\ncx_graphics_backend=dxmt"))
        #expect(later.renderer == .dxmt, "CXConfig::read overwrites fields; the key is case-insensitive")

        let elsewhere = CrossOverBottleConfig.parse(cxbottleConf: """
            [Bottle]
            "CX_GRAPHICS_BACKEND" = "dxvk"
            [ManagedUpdatePolicy]
            "WINEMSYNC" = "1"
            [EnvironmentVariables]
            ; "CX_GRAPHICS_BACKEND" = "d3dmetal"
            "LC_ALL" = "de_DE.UTF-8"
            [Other]
            "WINEDXVK" = "1"
            """)
        #expect(elsewhere.renderer == nil)
        #expect(elsewhere.sync == nil)
        #expect(elsewhere.environment == ["LC_ALL": "de_DE.UTF-8"])

        let crlf = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("\"CX_GRAPHICS_BACKEND\" = \"dxmt\"\n\"WINEESYNC\" = \"1\"").replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(crlf.renderer == .dxmt)
        #expect(crlf.sync == .msync)

        #expect(CrossOverBottleConfig.parse(cxbottleConf: "") == ImportedSettings())
        #expect(CrossOverBottleConfig.parse(cxbottleConf: Self.conf("")) == ImportedSettings(), "the template's commented PROMPT example yields nothing")
    }

    @Test("untouched variables pass through verbatim; CX_BOTTLE and WINEPREFIX are dropped")
    func passThrough() {
        let out = CrossOverBottleConfig.parse(cxbottleConf: Self.conf("""
            "CX_GRAPHICS_BACKEND" = "dxmt"
            "WINEESYNC" = "1"
            "WINE_WAIT_CHILD_PIPE_IGNORE" = "steam.exe"
            "DXMT_CONFIG" = "d3d11.preferredMaxFrameRate=60;"
            PROMPT=$p$g
            "HOME_LIKE" = "~/Games/${CX_BOTTLE}"
            "CX_BOTTLE" = "Steam"
            "WINEPREFIX" = "/Users/h/Library/Application Support/CrossOver/Bottles/Steam"
            """))
        #expect(out.renderer == .dxmt)
        #expect(out.sync == .msync)
        #expect(out.environment == [
            "WINE_WAIT_CHILD_PIPE_IGNORE": "steam.exe",
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
            "PROMPT": "$p$g",
            "HOME_LIKE": "~/Games/${CX_BOTTLE}",
        ], "values are verbatim: no ${VAR} or ~ expansion")
        #expect(out.notes.contains { $0.hasPrefix("dropped CX_BOTTLE=Steam") })
        #expect(out.notes.contains { $0.hasPrefix("dropped WINEPREFIX=") })
    }

    @Test("the raw section reader keeps the last spelling of a key")
    func rawSection() {
        let vars = CrossOverBottleConfig.environmentVariables(in: Self.conf("\"Foo\" = \"1\"\nFOO=2\n\"bar\" = \"x\"\n\"BAR\" = \"<undef>\""))
        #expect(vars == ["FOO": "2"])
        #expect(CrossOverBottleConfig.leadingInt(" -12abc") == -12)
        #expect(CrossOverBottleConfig.leadingInt("+7") == 7)
        #expect(CrossOverBottleConfig.leadingInt("abc") == 0)
    }
}
