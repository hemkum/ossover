// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct RegFileTests {
    /// The init batch, golden (decisions 22–24): the Mac driver values on the global key, winecfg's
    /// `LogPixels`, and the one `[WineSettingsReg]` value with a reader (`cb_access_map_w`,
    /// REG_DWORD, wined3d only). Nothing under `AppDefaults`, no `Systray`/`ShowSystray`, nothing
    /// under `HKLM` (`winecfg -v` writes `CurrentBuild`/`UBR` itself, REA L-38).
    @Test func prefixSettingsBatchRendersExactly() throws {
        let settings = BottleSettings(retina: true, dpi: 96, captureDisplaysForFullscreen: false)
        let display = "Windows Registry Editor Version 5.00\r\n"
            + "\r\n"
            + "[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n"
            + "\"RetinaMode\"=\"y\"\r\n"
            + "\"CaptureDisplaysForFullscreen\"=\"n\"\r\n"
            + "\r\n"
            + "[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n"
            + "\"LogPixels\"=dword:00000060\r\n"
            + "\r\n"
        let defaults = "[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]\r\n"
            + "\"cb_access_map_w\"=dword:00000001\r\n"
            + "\r\n"
        #expect(try RegFile.render(Prefix.registryEntries(for: settings)) == display + defaults)
        #expect(try RegFile.render(Prefix.displayEntries(for: settings)) == display,
                "a display-only re-apply is the same batch without the fixed defaults")
    }

    @Test func windowsBuildEntriesRenderUnderHKLM() throws {
        let text = try RegFile.render(WinVersion.buildEntries(19045))
        #expect(text == "Windows Registry Editor Version 5.00\r\n\r\n"
                + "[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion]\r\n"
                + "\"CurrentBuild\"=\"19045\"\r\n"
                + "\"CurrentBuildNumber\"=\"19045\"\r\n\r\n")
        #expect(WinVersion.defaultBuild(for: .win10) == 19045)
        #expect(WinVersion.defaultBuild(for: .win11) == 22631)
    }

    @Test func valueLinesPerType() throws {
        let key = #"HKCU\Software\Test"#
        #expect(try RegFile.valueLine(.string(key, "Path", #"C:\a "b""#)) == #""Path"="C:\\a \"b\"""#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "", type: .string, data: "default")) == #"@="default""#)
        #expect(try RegFile.valueLine(.dword(key, "Flag", 1)) == #""Flag"=dword:00000001"#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "Hex", type: .dword, data: "0x60")) == #""Hex"=dword:00000060"#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "Q", type: .qword, data: "1")) == #""Q"=hex(b):01,00,00,00,00,00,00,00"#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "E", type: .expandString, data: #"C:\x"#))
                == #""E"=hex(2):43,00,3a,00,5c,00,78,00,00,00"#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "M", type: .multiString, data: "a\nb"))
                == #""M"=hex(7):61,00,00,00,62,00,00,00,00,00"#)
        #expect(try RegFile.valueLine(RegistryEntry(key: key, name: "B", type: .binary, data: "0a ff")) == #""B"=hex:0a,ff"#)
    }

    @Test func badDataIsRejected() {
        let key = #"HKCU\Software\Test"#
        #expect(throws: OssoverError.self) { try RegFile.valueLine(RegistryEntry(key: key, name: "D", type: .dword, data: "-1")) }
        #expect(throws: OssoverError.self) { try RegFile.valueLine(RegistryEntry(key: key, name: "D", type: .dword, data: "4294967296")) }
        #expect(throws: OssoverError.self) { try RegFile.valueLine(RegistryEntry(key: key, name: "B", type: .binary, data: "abc")) }
        #expect(throws: OssoverError.self) { try RegFile.valueLine(RegistryEntry(key: key, name: "Q", type: .qword, data: "x")) }
    }

    @Test func rootsExpandAndKeysGroupInFirstSeenOrder() throws {
        #expect(RegFile.expandRoot(#"HKLM\Software"#) == #"HKEY_LOCAL_MACHINE\Software"#)
        #expect(RegFile.expandRoot(#"HKCU/Software/Wine"#) == #"HKEY_CURRENT_USER\Software\Wine"#)
        #expect(RegFile.expandRoot(#"HKEY_CURRENT_USER\Already"#) == #"HKEY_CURRENT_USER\Already"#)
        let text = try RegFile.render([
            .string(#"HKCU\B"#, "one", "1"),
            .string(#"HKCU\A"#, "two", "2"),
            .string(#"HKCU\B"#, "three", "3"),
        ])
        #expect(text == "Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\B]\r\n\"one\"=\"1\"\r\n\"three\"=\"3\"\r\n\r\n"
                + "[HKEY_CURRENT_USER\\A]\r\n\"two\"=\"2\"\r\n\r\n")
    }

    @Test func fileBytesAreUTF16LEWithBOM() {
        let data = RegFile.data("Ab")
        #expect(Array(data) == [0xFF, 0xFE, 0x41, 0x00, 0x62, 0x00])
        #expect(RegFile.parseInteger("96") == 96)
        #expect(RegFile.parseInteger("0x60") == 96)
        #expect(RegFile.parseInteger(" 7 ") == 7)
        #expect(RegFile.parseInteger("x") == nil)
        #expect(RegFile.escape(#"a\b"c"#) == #"a\\b\"c"#)
    }

    @Test func queryOutputParses() {
        let output = "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\n    RetinaMode    REG_SZ    y\n"
        let parsed = Registry.parseQuery(output, name: "RetinaMode")
        #expect(parsed?.type == "REG_SZ")
        #expect(parsed?.value == "y")
        #expect(Registry.parseQuery(output, name: "Other") == nil)
        #expect(WinVersion.parse("win10\n") == .win10)
        #expect(WinVersion.parse("wine: warning\nwin81") == .win81)
        #expect(WinVersion.parse("") == nil)
    }
}
