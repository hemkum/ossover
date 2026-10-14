// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

// Decision 39: no renderer-specific WINEDLLOVERRIDES under strategy C (REA L-05, L-20, L-26).
// The `n,b` fragments exist for strategy B's mark-stripped prefix copies only; a prepended
// overlay wins by DLL path, as CrossOver's does, and wined3d has nothing to override. The
// golden env rows for both strategies are in WineEnvironmentGoldenTests (A/G vs B/H).

@Suite struct RendererOverridesTests {
    @Test("strategy B applies the pack's overrides, else the kind's defaults")
    func prefixCopyAppliesOverrides() {
        let dxmt = RendererSelection(choice: .dxmt, kind: .dxmt, pack: Fixtures.dxmtPack,
                                     dllPath: Fixtures.dxmtPack.wineDir, strategy: .prefixCopy)
        #expect(dxmt.overrides == ["dxgi,d3d11,d3d10core=n,b"])

        let bare = Fixtures.pack(id: "dxmt-bare", kind: .dxmt, version: "0.80", overrides: [])
        let fallback = RendererSelection(choice: .dxmt, kind: .dxmt, pack: bare, dllPath: bare.wineDir, strategy: .prefixCopy)
        #expect(fallback.overrides == RendererResolver.defaultOverrides(.dxmt))
        #expect(!fallback.overrides.isEmpty)

        let dxvk = RendererSelection(choice: .dxvk, kind: .dxvk, pack: Fixtures.dxvkPack,
                                     dllPath: Fixtures.dxvkPack.wineDir, strategy: .prefixCopy)
        #expect(dxvk.overrides == ["d3d9,d3d10core,d3d11,dxgi=n,b"])
    }

    @Test("strategy C emits no renderer override, even when the pack manifest declares one (REA L-05, L-20, L-26)")
    func prependEmitsNothing() {
        let dxmt = RendererSelection(choice: .dxmt, kind: .dxmt, pack: Fixtures.dxmtPack,
                                     dllPath: Fixtures.dxmtPack.wineDir, strategy: .prepend)
        #expect(dxmt.overrides.isEmpty, "the builtin-marked overlay wins by DLL path; CrossOver sets no override for any backend")

        let d3dmetal = RendererSelection(choice: .d3dmetal, kind: .d3dmetal, pack: Fixtures.d3dmetalPack,
                                         dllPath: Fixtures.d3dmetalPack.wineDir, strategy: .prepend)
        #expect(d3dmetal.overrides.isEmpty)
        #expect(!Fixtures.d3dmetalPack.manifest.overrides.isEmpty, "the fixture declares one, so it is the strategy gate that drops it")
    }

    @Test("wined3d, and the kind defaults for D3DMetal, carry no override")
    func noneAndDefaults() {
        #expect(RendererSelection.wined3d.overrides.isEmpty)
        #expect(RendererResolver.defaultOverrides(.d3dmetal).isEmpty, "decisions 14, 39")
        #expect(RendererResolver.defaultOverrides(.wined3d).isEmpty)
    }
}
