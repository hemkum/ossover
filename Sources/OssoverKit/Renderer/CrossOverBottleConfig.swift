// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What `CrossOverBottleConfig.parse` recovers from a CrossOver bottle's `cxbottle.conf`
/// (decision 18): the renderer and sync settings CrossOver keeps as environment variables, and
/// the rest of `[EnvironmentVariables]` for the importer to carry over as the bottle's `env`.
public struct ImportedSettings: Equatable, Sendable {
    /// From `CX_GRAPHICS_BACKEND`, else the legacy toggles; nil when the bottle says nothing.
    public var renderer: RendererChoice?
    /// From `WINEMSYNC` / `WINEESYNC`; nil when the bottle says nothing.
    public var sync: SyncMode?
    /// `[EnvironmentVariables]` minus the mapped, ignored and rejected keys, values verbatim —
    /// CrossOver's `${VAR}` and `~` expansion (`expand_string`) is not applied here.
    public var environment: [String: String]
    /// What was mapped, ignored or dropped, for the importer's log.
    public var notes: [String]

    public init(renderer: RendererChoice? = nil, sync: SyncMode? = nil, environment: [String: String] = [:], notes: [String] = []) {
        self.renderer = renderer
        self.sync = sync
        self.environment = environment
        self.notes = notes
    }
}

/// Pure reader of a CrossOver `cxbottle.conf` for the bottle importer (decision 18; REA L-17,
/// L-18, L-19, L-30, L-36, L-70).
///
/// CrossOver keeps its graphics and sync choices as `[EnvironmentVariables]` of the bottle:
/// - `CX_GRAPHICS_BACKEND` (`auto|wined3d|dxvk|dxmt|d3dmetal`, written by the GUI, by the
///   "DXVK (Builtin)" CrossTie and by the CX 25 migration; read only by the proprietary
///   `cxcompatdb.so`) is the renderer choice; the vocabulary is `RendererChoice`'s (L-17, L-18).
/// - When it is undefined, the legacy toggles decide the way `upgrade_graphics_settings`
///   (`CXBT:448-467`) migrates them: `WINEDXVK=1` → `dxvk`, then `WINED3DMETAL=1` or
///   `D3DMetal=1` → `d3dmetal`, so dxvk wins a tie (L-70).
/// - `WINEESYNC=1` → msync, as the same migration rewrites it (`CXBT:462-464`; esync is not
///   compiled into the CX tree, L-36); `WINEMSYNC` is read as Wine does, `getenv && atoi` (L-30).
/// - `CX_ACTIVE_GRAPHICS_BACKEND` is what CrossOver exports to the process for the backend in
///   effect; `WineEnvironment` sets it per launch, so it is never a setting (L-19).
/// - `CX_BOTTLE` and `WINEPREFIX` are rejected by CrossOver's own launcher in that section
///   (`CXBottle::set_environment`), so they are dropped rather than carried over.
///
/// Syntax as `CXConfig.pm` reads it: case-insensitive section and key names (a later spelling
/// of a key replaces the earlier), `"Name" = "Value"` or `Name=Value`, `;` comments, and the
/// value `<undef>` deletes the key. Only `[EnvironmentVariables]` is read; `[Bottle]` and the
/// managed-update policy are not settings ossover has.
public enum CrossOverBottleConfig {
    public static let environmentSection = "EnvironmentVariables"
    public static let undefinedValue = "<undef>"
    public static let backendKey = "CX_GRAPHICS_BACKEND"
    public static let activeBackendKey = "CX_ACTIVE_GRAPHICS_BACKEND"
    public static let legacyDXVKKey = "WINEDXVK"
    /// In the order the migration consults them; `WINED3DMETAL` is the one 91 CrossTies write.
    public static let legacyD3DMetalKeys = ["WINED3DMETAL", "D3DMetal"]
    public static let esyncKey = "WINEESYNC"
    public static let msyncKey = "WINEMSYNC"
    /// Keys CrossOver's launcher refuses in `[EnvironmentVariables]` (exit 1).
    public static let rejectedKeys = ["CX_BOTTLE", "WINEPREFIX"]

    /// The `[EnvironmentVariables]` section of `text` as CrossOver would see it, keyed by the
    /// spelling of each key's last assignment. Never fails: unreadable lines are skipped.
    public static func environmentVariables(in text: String) -> [String: String] {
        var vars = Variables()
        var inSection = false
        for line in IniFile(text: text).lines {
            switch line {
            case let .section(name, _):
                inSection = name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(environmentSection) == .orderedSame
            case let .keyValue(key, value, _) where inSection:
                let name = IniFile.unquoted(key.trimmingCharacters(in: .whitespaces))
                let value = IniFile.unquoted(value.trimmingCharacters(in: .whitespaces))
                guard !name.isEmpty else { continue }
                if value == undefinedValue {
                    vars.remove(name)
                } else {
                    vars.set(name, value)
                }
            default:
                continue
            }
        }
        return vars.dictionary
    }

    /// Maps `cxbottleConf` onto ossover settings. Pure.
    public static func parse(cxbottleConf text: String) -> ImportedSettings {
        var vars = Variables(environmentVariables(in: text))
        var out = ImportedSettings()

        // Renderer: CX_GRAPHICS_BACKEND when defined (any value), else the legacy toggles.
        if let backend = vars.take(backendKey) {
            if let choice = RendererChoice(rawValue: backend.lowercased()) {
                out.renderer = choice
                out.notes.append("renderer \(choice.rawValue) from \(backendKey)=\(backend) (REA L-17, L-18)")
            } else {
                let known = RendererChoice.allCases.map(\.rawValue).joined(separator: "|")
                out.notes.append("ignored \(backendKey)=\(backend): not one of \(known) (REA L-18)")
            }
            for key in [legacyDXVKKey] + legacyD3DMetalKeys {
                if let value = vars.take(key) {
                    out.notes.append("dropped legacy \(key)=\(value): \(backendKey) is defined (CXBT:448-467)")
                }
            }
        } else {
            let dxvk = vars.take(legacyDXVKKey)
            let d3dmetal = legacyD3DMetalKeys.compactMap { key in vars.take(key).map { (key: key, value: $0) } }
            if let dxvk, isOn(dxvk) {
                out.renderer = .dxvk
                out.notes.append("renderer dxvk from legacy \(legacyDXVKKey)=1 (REA L-70; dxvk wins a tie)")
            } else if let hit = d3dmetal.first(where: { isOn($0.value) }) {
                out.renderer = .d3dmetal
                out.notes.append("renderer d3dmetal from legacy \(hit.key)=1 (REA L-70)")
            } else if dxvk != nil || !d3dmetal.isEmpty {
                out.notes.append("legacy graphics toggles present but not set to 1; renderer left unset (REA L-70)")
            }
        }

        // Sync: WINEMSYNC as Wine reads it; WINEESYNC=1 is migrated to msync, anything else dropped.
        if let msync = vars.take(msyncKey) {
            out.sync = leadingInt(msync) != 0 ? .msync : SyncMode.none
            out.notes.append("sync \(out.sync?.rawValue ?? "") from \(msyncKey)=\(msync) (REA L-30)")
        }
        if let esync = vars.take(esyncKey) {
            if isOn(esync) {
                out.sync = .msync
                out.notes.append("sync msync from legacy \(esyncKey)=1 (REA L-36)")
            } else {
                out.notes.append("dropped \(esyncKey)=\(esync): esync does not exist in CrossOver-derived engines (REA L-32, L-36)")
            }
        }

        if let active = vars.take(activeBackendKey) {
            out.notes.append("ignored \(activeBackendKey)=\(active): set per launch for the backend in effect, never a setting (REA L-19)")
        }
        for key in rejectedKeys {
            if let value = vars.take(key) {
                out.notes.append("dropped \(key)=\(value): CrossOver's launcher rejects it in [\(environmentSection)]")
            }
        }

        out.environment = vars.dictionary
        return out
    }

    /// CrossOver's migration tests the legacy toggles against the literal `1`.
    static func isOn(_ value: String) -> Bool { value == "1" }

    /// `atoi`: an optional sign and leading digits, 0 for anything else.
    static func leadingInt(_ value: String) -> Int {
        var digits = Substring(value.drop { $0 == " " || $0 == "\t" })
        var negative = false
        if let sign = digits.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            digits = digits.dropFirst()
        }
        let number = Int(digits.prefix { $0.isASCII && $0.isNumber }) ?? 0
        return negative ? -number : number
    }

    /// Case-insensitive variable table that keeps each key's last spelling.
    struct Variables {
        private var byLowercased: [String: (name: String, value: String)] = [:]

        init() {}
        init(_ dictionary: [String: String]) {
            for (name, value) in dictionary { set(name, value) }
        }

        mutating func set(_ name: String, _ value: String) { byLowercased[name.lowercased()] = (name, value) }
        mutating func remove(_ name: String) { byLowercased[name.lowercased()] = nil }

        /// Removes `name` (any case) and returns its value.
        mutating func take(_ name: String) -> String? { byLowercased.removeValue(forKey: name.lowercased())?.value }

        var dictionary: [String: String] {
            Dictionary(uniqueKeysWithValues: byLowercased.values.map { ($0.name, $0.value) })
        }
    }
}
