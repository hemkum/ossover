// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct IniFileTests {
    static let fixture = "recipes/user.settings"

    @Test func fixtureRoundTripsByteForByte() throws {
        let data = try Fixtures.data(Self.fixture)
        let ini = IniFile(data: data)
        #expect(ini.lineEnding == "\r\n")
        #expect(ini.trailingNewline)
        #expect(!ini.hasBOM)
        #expect(ini.sections == ["General", "Rendering", "Viewport"])
        #expect(ini.data() == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(IniFile(text: text).render() == text)
    }

    @Test func quotedValuesStayVerbatim() throws {
        let ini = IniFile(data: try Fixtures.data(Self.fixture))
        #expect(ini.value(section: "Viewport", key: "Resolution") == "\"1920x1080\"")
        #expect(IniFile.unquoted(ini.value(section: "Viewport", key: "Resolution") ?? "") == "1920x1080")
        #expect(ini.value(section: "rendering", key: "hairworkslevel") == "2")
        #expect(ini.value(key: "FullScreenMode") == "0")
        #expect(ini.value(section: "General", key: "Resolution") == nil)
    }

    @Test func witcherRecipeEditsRenderExactly() throws {
        var ini = IniFile(data: try Fixtures.data(Self.fixture))
        let hair = ini.set(section: "Rendering", key: "HairWorksLevel", value: "0")
        let resolution = ini.set(section: "Viewport", key: "Resolution", value: "\"2560x1600\"")
        let fullscreen = ini.set(section: "Viewport", key: "FullScreenMode", value: "1")
        let vsync = ini.set(section: "Viewport", key: "VSync", value: "false")
        let again = ini.set(section: "Rendering", key: "HairWorksLevel", value: "0")
        #expect(hair && resolution && fullscreen && vsync)
        #expect(!again, "the same value is not a change")
        let expected = "[General]\r\nLanguage=en\r\n\r\n[Rendering]\r\nHairWorksLevel=0\r\nTextureQuality=\"high\"\r\n\r\n"
            + "[Viewport]\r\nResolution=\"2560x1600\"\r\nFullScreenMode=1\r\nVSync=false\r\n"
        #expect(ini.render() == expected)
    }

    @Test func existingKeyIsUpdatedWhereverItLives() throws {
        var ini = IniFile(data: try Fixtures.data(Self.fixture))
        let moved = ini.set(section: "Graphics", key: "FullScreenMode", value: "1")
        #expect(moved)
        #expect(ini.sections == ["General", "Rendering", "Viewport"], "no new section for a key that exists elsewhere")
        #expect(ini.value(section: "Viewport", key: "FullScreenMode") == "1")
        let added = ini.set(section: "Audio", key: "Volume", value: "0.5")
        #expect(added)
        #expect(ini.sections.last == "Audio")
        #expect(ini.render().hasSuffix("[Audio]\r\nVolume=0.5\r\n"))
    }

    @Test func newKeyGoesBeforeTheBlankLineThatEndsASection() {
        var ini = IniFile(text: "[A]\nx=1\n\n[B]\ny=2\n")
        let added = ini.set(section: "A", key: "z", value: "3")
        #expect(added)
        #expect(ini.render() == "[A]\nx=1\nz=3\n\n[B]\ny=2\n")
        let removed = ini.remove(section: "A", key: "x")
        #expect(removed == 1)
        #expect(ini.render() == "[A]\nz=3\n\n[B]\ny=2\n")
    }

    @Test func bomSpacingAndCommentsArePreserved() {
        let text = "\u{FEFF}; comment\r\n[S]\r\nkey = value \r\nother=\"a=b\"\r\n"
        var ini = IniFile(text: text)
        #expect(ini.hasBOM)
        #expect(ini.render() == text)
        #expect(ini.value(section: "S", key: "key") == "value ")
        #expect(ini.value(section: "S", key: "other") == "\"a=b\"")
        let changed = ini.set(section: "S", key: "key", value: "new")
        #expect(changed)
        #expect(ini.render() == "\u{FEFF}; comment\r\n[S]\r\nkey = new\r\nother=\"a=b\"\r\n")
    }

    @Test func flatFileAndEmptyFile() {
        var flat = IniFile(text: "a=1\n")
        #expect(flat.sections.isEmpty)
        let flatAdded = flat.set(section: nil, key: "b", value: "2")
        #expect(flatAdded)
        #expect(flat.render() == "b=2\na=1\n")
        var empty = IniFile()
        let emptyAdded = empty.set(section: "Viewport", key: "VSync", value: "false")
        #expect(emptyAdded)
        #expect(empty.render() == "[Viewport]\nVSync=false\n")
    }

    @Test func saveAndLoadThroughDisk() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "sub/user.settings")
        var ini = try IniFile.load(from: file)
        #expect(ini.lines.isEmpty, "a missing file is an empty document")
        ini.set(section: "Rendering", key: "HairWorksLevel", value: "0")
        try ini.save(to: file)
        let loaded = try IniFile.load(from: file)
        #expect(loaded == ini)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[Rendering]\nHairWorksLevel=0\n")
    }
}
