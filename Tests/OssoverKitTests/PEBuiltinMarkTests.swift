// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import OssoverKit

@Suite struct PEBuiltinMarkTests {
    /// A minimal PE image: `MZ`, `e_lfanew` at 0x3C, a stub filled with 0xCC after the mark
    /// region, and `PE\0\0` at `lfanew`.
    static func image(lfanew: Int, mark: String? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: lfanew + 24)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        for i in 0..<4 { bytes[0x3C + i] = UInt8((lfanew >> (8 * i)) & 0xFF) }
        if lfanew > 0x60 { for i in 0x60..<lfanew { bytes[i] = 0xCC } }
        if let mark {
            for (i, byte) in (Array(mark.utf8) + [0]).enumerated() { bytes[0x40 + i] = byte }
        }
        bytes[lfanew] = 0x50
        bytes[lfanew + 1] = 0x45
        return Data(bytes)
    }

    static let marked = image(lfanew: 0x80, mark: PEBuiltinMark.signature)
    static let unmarked = image(lfanew: 0x80)

    @Test func detectsTheMark() {
        #expect(PEBuiltinMark.peHeaderOffset(Self.marked) == 0x80)
        #expect(PEBuiltinMark.hasRoom(Self.marked))
        #expect(PEBuiltinMark.isMarked(Self.marked))
        #expect(!PEBuiltinMark.isMarked(Self.unmarked))
        #expect(!PEBuiltinMark.isPlaceholder(Self.marked))
        #expect(PEBuiltinMark.signatureBytes.count == PEBuiltinMark.length)
        #expect(PEBuiltinMark.length == 17)
    }

    @Test func stripZeroesOnlyTheMark() throws {
        let stripped = try PEBuiltinMark.strip(Self.marked)
        #expect(!PEBuiltinMark.isMarked(stripped))
        #expect(stripped.count == Self.marked.count)
        #expect(stripped[0..<0x40] == Self.marked[0..<0x40])
        #expect(stripped[0x51...] == Self.marked[0x51...])
        #expect(Array(stripped[0x40..<0x51]) == [UInt8](repeating: 0, count: 17))
        #expect(stripped == Self.unmarked, "stripping yields the unmarked image byte for byte")
        #expect(try PEBuiltinMark.strip(Self.unmarked) == Self.unmarked, "unmarked input comes back as is")
    }

    @Test func markIsTheInverseOfStrip() throws {
        #expect(try PEBuiltinMark.mark(Self.unmarked) == Self.marked)
        #expect(try PEBuiltinMark.mark(Self.marked) == Self.marked)
        #expect(try PEBuiltinMark.mark(try PEBuiltinMark.strip(Self.marked)) == Self.marked)
    }

    @Test func shortStubHasNoRoom() throws {
        let short = Self.image(lfanew: 0x40, mark: nil)
        #expect(PEBuiltinMark.peHeaderOffset(short) == 0x40)
        #expect(!PEBuiltinMark.hasRoom(short))
        #expect(!PEBuiltinMark.isMarked(short))
        #expect(throws: OssoverError.self) { try PEBuiltinMark.mark(short) }
        #expect(try PEBuiltinMark.strip(short) == short, "nothing to strip, no error")
    }

    @Test func rejectsNonPEData() {
        let text = Data("not a PE file at all, just text".utf8)
        #expect(PEBuiltinMark.peHeaderOffset(text) == nil)
        #expect(!PEBuiltinMark.isMarked(text))
        #expect(throws: OssoverError.self) { try PEBuiltinMark.strip(text) }
        #expect(throws: OssoverError.self) { try PEBuiltinMark.mark(text) }
        #expect(PEBuiltinMark.peHeaderOffset(Data([0x4D, 0x5A])) == nil, "too short for e_lfanew")
    }

    @Test func placeholderMarkIsRecognisedSeparately() {
        let placeholder = Self.image(lfanew: 0x80, mark: PEBuiltinMark.placeholderSignature)
        #expect(PEBuiltinMark.isPlaceholder(placeholder))
        #expect(!PEBuiltinMark.isMarked(placeholder))
    }

    @Test func fileOperations() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "d3d11.dll")
        let target = dir.appending(path: "system32/d3d11.dll")
        try Self.marked.write(to: source)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        #expect(try PEBuiltinMark.isMarked(file: source))
        #expect(try PEBuiltinMark.strip(file: source, to: target), "reports that the source was marked")
        #expect(try PEBuiltinMark.isMarked(file: target) == false)
        #expect(try Data(contentsOf: target) == Self.unmarked)
        #expect(try PEBuiltinMark.strip(file: target, to: dir.appending(path: "copy.dll")) == false, "an unmarked source reports false")

        #expect(try PEBuiltinMark.mark(file: target), "marking an unmarked file changes it")
        #expect(try Data(contentsOf: target) == Self.marked)
        #expect(try PEBuiltinMark.mark(file: target) == false, "marking twice is a no-op")
    }

    @Test func strategyBPlanCopiesOnlyDirect3DWithTheMarkStripped() throws {
        let layout = Fixtures.paths.bottleLayout("golden")
        let selection = RendererSelection(choice: .dxmt, kind: .dxmt, pack: Fixtures.dxmtPack,
                                          dllPath: Fixtures.dxmtPack.wineDir, strategy: .prefixCopy)
        let copies = RendererMaterializer.plan(selection: selection, layout: layout)
        #expect(copies.map { $0.destination.lastPathComponent } == ["d3d11.dll", "dxgi.dll", "d3d10core.dll"])
        #expect(copies.allSatisfy { $0.stripMark }, "every strategy-B copy is stripped")
        #expect(copies.allSatisfy { $0.destination.deletingLastPathComponent().path == layout.system32.path })
        #expect(copies.allSatisfy { $0.source == Fixtures.dxmtPack.peDir.appending(path: $0.destination.lastPathComponent) })
        #expect(!copies.contains { $0.destination.lastPathComponent == "winemetal.dll" }, "winemetal.dll is never placed")

        // The shipped 0.80 manifest: nvapi64/nvngx/winemetal stay out, the 32-bit half goes to syswow64.
        let shipped = try RendererPackManifest.load(from: Fixtures.repoRoot.appending(path: "renderers/dxmt-0.80.json"))
        let pack = RendererPack(root: Fixtures.paths.renderer(shipped.id), manifest: shipped)
        let full = RendererMaterializer.plan(selection: RendererSelection(choice: .dxmt, kind: .dxmt, pack: pack, dllPath: pack.wineDir,
                                                                          strategy: .prefixCopy), layout: layout)
        #expect(full.map { $0.destination.lastPathComponent } == ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"])
        #expect(full.filter { $0.destination.deletingLastPathComponent().path == layout.syswow64.path }.count == 3)
        #expect(full.filter { $0.destination.deletingLastPathComponent().path == layout.system32.path }.count == 3)
        #expect(RendererMaterializer.direct3DNames(["nvapi64.dll", "D3D12.dll", "winemetal.dll", "d3d10_1.dll", "d3d9.dll"]) == ["D3D12.dll", "d3d10_1.dll", "d3d9.dll"])

        #expect(RendererMaterializer.plan(selection: .wined3d, layout: layout).isEmpty)
        #expect(RendererMaterializer.plan(selection: RendererSelection(choice: .dxmt, kind: .dxmt, pack: Fixtures.dxmtPack,
                                                                       dllPath: Fixtures.dxmtPack.wineDir, strategy: .prepend),
                                          layout: layout).isEmpty, "strategy C never touches the prefix")
    }
}
