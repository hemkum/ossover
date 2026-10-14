// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Windows ↔ Unix path mapping for a prefix, and the variable expansion recipes and programs
/// use (`%USERPROFILE%`, `${gameDir}`, `${engine}`).
///
/// `C:` is `<prefix>/drive_c`, `Z:` is the Unix root, any other letter is
/// `<prefix>/dosdevices/<letter>:` (a symlink Wine keeps). Mapping is textual: no path is
/// required to exist, and case is left alone (APFS is case-insensitive by default, as is Windows).
public enum WindowsPath {
    /// Backslashes throughout, runs collapsed, no trailing separator (except a bare drive root).
    public static func normalize(_ path: String) -> String {
        var out = ""
        var lastWasSeparator = false
        for ch in path {
            if ch == "/" || ch == "\\" {
                if !lastWasSeparator { out.append("\\") }
                lastWasSeparator = true
            } else {
                out.append(ch)
                lastWasSeparator = false
            }
        }
        if out.count > 3, out.hasSuffix("\\") { out.removeLast() }
        return out
    }

    /// `X:` or `X:\...` with an ASCII letter.
    public static func driveLetter(_ path: String) -> Character? {
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":", chars[0].isASCII, chars[0].isLetter else { return nil }
        if chars.count > 2, chars[2] != "\\", chars[2] != "/" { return nil }
        return Character(chars[0].uppercased())
    }

    public static func isAbsolute(_ path: String) -> Bool { driveLetter(path) != nil }

    /// `C:\Games\X` → `<prefix>/drive_c/Games/X`; `Z:\Users\h` → `/Users/h`;
    /// `D:\x` → `<prefix>/dosdevices/d:/x`. Nil for a relative path.
    public static func toUnix(_ windows: String, prefix: URL) -> URL? {
        let normalized = normalize(windows)
        guard let letter = driveLetter(normalized) else { return nil }
        let rest = normalized.dropFirst(2).drop(while: { $0 == "\\" })
        let components = rest.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        let base: URL
        switch letter {
        case "C": base = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        case "Z": base = URL(fileURLWithPath: "/", isDirectory: true)
        default: base = prefix.appending(path: "dosdevices/\(letter.lowercased()):", directoryHint: .isDirectory)
        }
        var url = base
        for component in components { url.appendPathComponent(component) }
        return url.standardizedFileURL
    }

    /// Inverse of `toUnix`: under `<prefix>/drive_c` → `C:\...`, otherwise `Z:\...`.
    public static func toWindows(_ unix: URL, prefix: URL) -> String {
        let path = unix.standardizedFileURL.path
        let driveC = prefix.standardizedFileURL.appending(path: "drive_c", directoryHint: .isDirectory).path
        if path == driveC { return "C:\\" }
        if path.hasPrefix(driveC + "/") {
            let rest = path.dropFirst(driveC.count + 1)
            return "C:\\" + rest.replacingOccurrences(of: "/", with: "\\")
        }
        if path == "/" { return "Z:\\" }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// `base\component`, with one separator between.
    public static func join(_ base: String, _ component: String) -> String {
        let left = normalize(base)
        let right = normalize(component).drop(while: { $0 == "\\" })
        if left.hasSuffix("\\") { return left + right }
        return left + "\\" + right
    }

    /// The Windows user profile for a Unix user name: `C:\users\<name>`.
    public static func userProfile(userName: String) -> String { "C:\\users\\\(userName)" }

    // MARK: Variables

    /// Expands `%NAME%` (case-insensitive name) and `${name}` (case-sensitive) from `variables`.
    /// Unknown references are left untouched. Not recursive.
    public static func expand(_ text: String, variables: [String: String]) -> String {
        var out = ""
        var index = text.startIndex
        let folded = Dictionary(variables.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        while index < text.endIndex {
            let ch = text[index]
            if ch == "%", let close = text[text.index(after: index)...].firstIndex(of: "%"), close > text.index(after: index) {
                let name = String(text[text.index(after: index)..<close])
                if !name.contains(where: { $0 == " " || $0 == "\\" || $0 == "/" }), let value = folded[name.lowercased()] {
                    out += value
                    index = text.index(after: close)
                    continue
                }
            }
            if ch == "$", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "{",
               let close = text[index...].firstIndex(of: "}") {
                let name = String(text[text.index(index, offsetBy: 2)..<close])
                if let value = variables[name] {
                    out += value
                    index = text.index(after: close)
                    continue
                }
            }
            out.append(ch)
            index = text.index(after: index)
        }
        return out
    }

    /// Names still referenced after expansion (`["gameDir"]`), so a plan can refuse early.
    public static func unresolvedVariables(in text: String) -> [String] {
        var names: [String] = []
        var scanner = text[...]
        while let open = scanner.range(of: "${"), let close = scanner[open.upperBound...].firstIndex(of: "}") {
            names.append(String(scanner[open.upperBound..<close]))
            scanner = scanner[scanner.index(after: close)...]
        }
        scanner = text[...]
        while let open = scanner.firstIndex(of: "%"),
              let close = scanner[scanner.index(after: open)...].firstIndex(of: "%") {
            let name = String(scanner[scanner.index(after: open)..<close])
            if !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\\" || $0 == "/" }) {
                names.append(name)
                scanner = scanner[scanner.index(after: close)...]
            } else {
                scanner = scanner[scanner.index(after: open)...]
            }
        }
        return names
    }

    /// The variables every recipe and program path may use. Windows-side values throughout.
    /// - `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `PROGRAMDATA`, `SYSTEMROOT`/`WINDIR`,
    ///   `PROGRAMFILES`, `PROGRAMFILES(X86)`, `TEMP`/`TMP` (as Wine lays a 64-bit prefix out)
    /// - `gameDir` from the recipe, `engine` (Unix path) from the engine, when given.
    public static func standardVariables(userName: String, gameDir: String? = nil, engineRoot: URL? = nil) -> [String: String] {
        let profile = userProfile(userName: userName)
        var vars: [String: String] = [
            "USERPROFILE": profile,
            "APPDATA": profile + "\\AppData\\Roaming",
            "LOCALAPPDATA": profile + "\\AppData\\Local",
            "TEMP": profile + "\\Temp",
            "TMP": profile + "\\Temp",
            "PROGRAMDATA": "C:\\ProgramData",
            "SYSTEMROOT": "C:\\windows",
            "WINDIR": "C:\\windows",
            "PROGRAMFILES": "C:\\Program Files",
            "PROGRAMFILES(X86)": "C:\\Program Files (x86)",
            "SYSTEMDRIVE": "C:",
        ]
        if let gameDir { vars["gameDir"] = normalize(gameDir) }
        if let engineRoot { vars["engine"] = engineRoot.standardizedFileURL.path }
        return vars
    }
}
