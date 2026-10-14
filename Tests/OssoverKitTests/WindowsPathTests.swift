// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct WindowsPathTests {
    static let prefix = URL(fileURLWithPath: "/ossover-test/bottles/b/prefix", isDirectory: true)

    @Test func normalizeCollapsesSeparators() {
        #expect(WindowsPath.normalize("C:/Games//The Witcher 3\\\\bin/") == #"C:\Games\The Witcher 3\bin"#)
        #expect(WindowsPath.normalize(#"C:\"#) == #"C:\"#, "a bare drive root keeps its separator")
        #expect(WindowsPath.normalize("C:/") == #"C:\"#)
        #expect(WindowsPath.normalize(#"relative\x"#) == #"relative\x"#)
    }

    @Test func driveLettersAreUppercasedAndValidated() {
        #expect(WindowsPath.driveLetter(#"c:\x"#) == "C")
        #expect(WindowsPath.driveLetter("Z:") == "Z")
        #expect(WindowsPath.driveLetter("C:/x") == "C")
        #expect(WindowsPath.driveLetter("Cx") == nil)
        #expect(WindowsPath.driveLetter("C:x") == nil)
        #expect(WindowsPath.driveLetter("1:\\x") == nil)
        #expect(WindowsPath.isAbsolute(#"C:\Games"#))
        #expect(!WindowsPath.isAbsolute(#"Games\x"#))
    }

    @Test func toUnixMapsDrives() {
        #expect(WindowsPath.toUnix(#"C:\Games\The Witcher 3\bin"#, prefix: Self.prefix)?.path
                == "/ossover-test/bottles/b/prefix/drive_c/Games/The Witcher 3/bin")
        #expect(WindowsPath.toUnix("c:/Games", prefix: Self.prefix)?.path == "/ossover-test/bottles/b/prefix/drive_c/Games")
        #expect(WindowsPath.toUnix(#"C:\"#, prefix: Self.prefix)?.path == "/ossover-test/bottles/b/prefix/drive_c")
        #expect(WindowsPath.toUnix(#"Z:\Users\x\file.exe"#, prefix: Self.prefix)?.path == "/Users/x/file.exe")
        #expect(WindowsPath.toUnix(#"Z:\"#, prefix: Self.prefix)?.path == "/")
        #expect(WindowsPath.toUnix(#"D:\x\y"#, prefix: Self.prefix)?.path == "/ossover-test/bottles/b/prefix/dosdevices/d:/x/y")
        #expect(WindowsPath.toUnix(#"relative\path"#, prefix: Self.prefix) == nil)
    }

    @Test func toWindowsIsTheInverse() {
        let driveC = Self.prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        #expect(WindowsPath.toWindows(driveC.appending(path: "Games/X"), prefix: Self.prefix) == #"C:\Games\X"#)
        #expect(WindowsPath.toWindows(driveC, prefix: Self.prefix) == #"C:\"#)
        #expect(WindowsPath.toWindows(URL(fileURLWithPath: "/Users/x"), prefix: Self.prefix) == #"Z:\Users\x"#)
        #expect(WindowsPath.toWindows(URL(fileURLWithPath: "/"), prefix: Self.prefix) == #"Z:\"#)
        #expect(WindowsPath.toWindows(Self.prefix.appending(path: "drive_cx"), prefix: Self.prefix) == #"Z:\ossover-test\bottles\b\prefix\drive_cx"#,
                "a sibling that merely starts with drive_c is not on C:")
        let logs = URL(fileURLWithPath: "/ossover-test/bottles/b/logs", isDirectory: true)
        #expect(WindowsPath.toWindows(logs, prefix: Self.prefix) == #"Z:\ossover-test\bottles\b\logs"#)
        for windows in [#"C:\Games\The Witcher 3\bin\x64"#, #"Z:\Users\x"#] {
            let unix = WindowsPath.toUnix(windows, prefix: Self.prefix)
            #expect(unix.map { WindowsPath.toWindows($0, prefix: Self.prefix) } == windows)
        }
    }

    @Test func joinAndProfile() {
        #expect(WindowsPath.join(#"C:\Games"#, #"X\y"#) == #"C:\Games\X\y"#)
        #expect(WindowsPath.join(#"C:\"#, "X") == #"C:\X"#)
        #expect(WindowsPath.join(#"C:\Games\"#, #"\X"#) == #"C:\Games\X"#)
        #expect(WindowsPath.userProfile(userName: "tester") == #"C:\users\tester"#)
    }

    @Test func variableExpansion() {
        let variables = ["USERPROFILE": #"C:\users\t"#, "gameDir": #"C:\Games\G"#]
        #expect(WindowsPath.expand(#"%USERPROFILE%\Documents"#, variables: variables) == #"C:\users\t\Documents"#)
        #expect(WindowsPath.expand(#"%userprofile%\Documents"#, variables: variables) == #"C:\users\t\Documents"#, "%NAME% is case-insensitive")
        #expect(WindowsPath.expand(#"${gameDir}\bin"#, variables: variables) == #"C:\Games\G\bin"#)
        #expect(WindowsPath.expand(#"${GameDir}\bin"#, variables: variables) == #"${GameDir}\bin"#, "${name} is case-sensitive; unknown kept")
        #expect(WindowsPath.expand("%UNKNOWN%", variables: variables) == "%UNKNOWN%")
        #expect(WindowsPath.unresolvedVariables(in: #"${a}\${b}\${a}"#) == ["a", "b", "a"])
        #expect(WindowsPath.unresolvedVariables(in: "plain").isEmpty)
    }

    @Test func standardVariablesCoverTheWinePrefixLayout() {
        let vars = WindowsPath.standardVariables(userName: "t", gameDir: "C:/Games/X", engineRoot: URL(fileURLWithPath: "/e", isDirectory: true))
        #expect(vars["USERPROFILE"] == #"C:\users\t"#)
        #expect(vars["APPDATA"] == #"C:\users\t\AppData\Roaming"#)
        #expect(vars["LOCALAPPDATA"] == #"C:\users\t\AppData\Local"#)
        #expect(vars["TEMP"] == #"C:\users\t\Temp"#)
        #expect(vars["TMP"] == vars["TEMP"])
        #expect(vars["PROGRAMDATA"] == #"C:\ProgramData"#)
        #expect(vars["SYSTEMROOT"] == #"C:\windows"#)
        #expect(vars["WINDIR"] == #"C:\windows"#)
        #expect(vars["PROGRAMFILES"] == #"C:\Program Files"#)
        #expect(vars["PROGRAMFILES(X86)"] == #"C:\Program Files (x86)"#)
        #expect(vars["SYSTEMDRIVE"] == "C:")
        #expect(vars["gameDir"] == #"C:\Games\X"#)
        #expect(vars["engine"] == "/e")
        let bare = WindowsPath.standardVariables(userName: "t")
        #expect(bare["gameDir"] == nil)
        #expect(bare["engine"] == nil)
    }
}
