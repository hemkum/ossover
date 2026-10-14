// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import OssoverKit

// The kit's string enums parse straight from the command line (`--winver win10`).
extension WindowsVersion: ExpressibleByArgument {}
extension SyncMode: ExpressibleByArgument {}
extension RendererChoice: ExpressibleByArgument {}
extension RendererKind: ExpressibleByArgument {}
extension InputInjector.Key: ExpressibleByArgument {}

/// Which depot tool `steam fetch` runs.
enum SteamTool: String, CaseIterable, ExpressibleByArgument {
    case steamcmd
    case depotdownloader
}

/// `KEY=VALUE` as typed after `--env`.
struct EnvAssignment: ExpressibleByArgument {
    let name: String
    let value: String

    init?(argument: String) {
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else { return nil }
        name = String(argument[..<equals])
        value = String(argument[argument.index(after: equals)...])
    }

    static func dictionary(_ assignments: [EnvAssignment]) -> [String: String] {
        Dictionary(assignments.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
