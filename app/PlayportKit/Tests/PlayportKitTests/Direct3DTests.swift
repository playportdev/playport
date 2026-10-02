// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

final class Direct3DTests: XCTestCase {
    /// Synthetic PE with named imports. No proprietary game binaries in tests.
    static func pe(_ imports: [(String, [String])], plus: Bool = true, delay: Bool = false,
                   strings: [String] = [], wide: Bool = false, sectionName: String = ".rdata") -> Data {
        var data = Data(repeating: 0, count: 8192)
        func put(_ at: Int, _ value: Int, _ bytes: Int = 4) {
            for i in 0..<bytes { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        func copy(_ at: Int, _ bytes: [UInt8]) { data.replaceSubrange(at..<(at + bytes.count), with: bytes) }
        put(0, 0x5a4d, 2); put(0x3c, 0x80); put(0x80, 0x4550); put(0x86, 1, 2)
        let opt = 0x98, size = plus ? 240 : 224, directories = plus ? 112 : 96
        put(0x94, size, 2); put(opt, plus ? 0x20b : 0x10b, 2)
        put(opt + 60, 512); put(opt + directories - 4, 16)
        let stride = delay ? 32 : 20
        put(opt + directories + (delay ? 13 : 1) * 8, 0x1000)
        put(opt + directories + (delay ? 13 : 1) * 8 + 4, stride * (imports.count + 1))
        let section = opt + size
        copy(section, Array(sectionName.utf8.prefix(8)))
        put(section + 8, data.count - 512); put(section + 12, 0x1000)
        put(section + 16, data.count - 512); put(section + 20, 512); put(section + 36, 0x40000040)
        var cursor = max(2048, 512 + (imports.count + 1) * stride + 16)
        func rva(_ at: Int) -> Int { at + 0x1000 - 512 }
        func string(_ value: String, hint: Bool = false) -> Int {
            let at = cursor
            let bytes = (hint ? [UInt8(0), 0] : []) + Array(value.utf8) + [0]
            copy(at, bytes); cursor += bytes.count
            return rva(at)
        }
        for (i, item) in imports.enumerated() {
            let descriptor = 512 + i * stride
            if delay { put(descriptor, 1) }
            put(descriptor + (delay ? 4 : 12), string(item.0))
            let names = item.1.map { string($0, hint: true) }
            let thunks = cursor, width = plus ? 8 : 4
            cursor += (names.count + 1) * width
            for (n, address) in names.enumerated() { put(thunks + n * width, address, width) }
            put(descriptor + (delay ? 16 : 0), rva(thunks))
        }
        for value in strings {
            if wide {
                let bytes: [UInt8] = value.utf16.flatMap { unit -> [UInt8] in
                    [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)]
                } + [0, 0]
                copy(cursor, bytes); cursor += bytes.count
            } else { _ = string(value) }
        }
        return data
    }

    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("direct3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult
    func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testAPIExportsThroughAnArbitrarilyNamedInterposer() throws {
        // Actual missed shape: D3D12CreateDevice imported from an interposer,
        // not d3d12.dll. Normal AND delay tables in PE32 AND PE32+.
        for plus in [true, false] {
            for delay in [true, false] {
                let data = Self.pe([("renderer-proxy.dll", ["D3D12CreateDevice", "D3D12SerializeRootSignature"])], plus: plus, delay: delay)
                XCTAssertTrue(Direct3D12.imports(in: data))
                let inspection = try XCTUnwrap(Direct3D.inspect(data))
                XCTAssertEqual(inspection.evidence.count, 1)
                XCTAssertEqual(inspection.evidence.first?.kind, .functionImport)
                XCTAssertEqual(inspection.evidence.first?.name, "renderer-proxy.dll!D3D12CreateDevice")
            }
        }
    }

    func testReachableDependenciesCaseInsensitiveNestedAndCyclic() throws {
        let exe = try write("bin/game.exe", Self.pe([("engine.dll", [])]))
        try write("bin/Engine.DLL", Self.pe([("shared.dll", [])]))
        try write("SHARED.dll", Self.pe([("engine.dll", []), ("renderer.dll", [])]))
        try write("renderer.dll", Self.pe([("D3D12.DLL", [])], delay: true))
        let result = Direct3D.detect(executable: exe, root: root)
        XCTAssertTrue(result.hasDirect3D12)
        XCTAssertEqual(result.modulesScanned, 4)
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.evidence.first?.module, "renderer.dll")
        XCTAssertEqual(result.evidence.first?.kind, .libraryImport)
    }

    func testUnusedRendererAndOtherEXENotCounted() throws {
        let exe = try write("dx11/game.exe", Self.pe([("d3d11.dll", [])]))
        try write("dx11/d3d12.dll", Self.pe([("d3d12core.dll", [])]))
        try write("dx11/unused.dll", Self.pe([("d3d12.dll", [])]))
        try write("dx12/game.exe", Self.pe([("d3d12.dll", [])]))
        let result = Direct3D.detect(executable: exe, root: root)
        XCTAssertEqual(result.apis, [.d3d11])
        XCTAssertEqual(result.modulesScanned, 1)
        XCTAssertFalse(result.hasDirect3D12)
    }

    func testDynamicLoadingNeedsLoaderDLLAndAPIFunctionOutsideResources() throws {
        let loader = [("kernel32.dll", ["LoadLibraryW", "GetProcAddress"])]
        for wide in [true, false] {
            let data = Self.pe(loader, strings: ["D3d12.dLl", "D3D12CreateDevice"], wide: wide)
            let evidence = try XCTUnwrap(Direct3D.inspect(data)).evidence
            XCTAssertEqual(evidence.first?.api, .d3d12)
            XCTAssertEqual(evidence.first?.kind, .dynamicReference)
            XCTAssertFalse(Direct3D12.imports(in: data)) // direct import facade remains literal
            XCTAssertTrue(try XCTUnwrap(Direct3D.inspect(Self.pe(loader,
                strings: ["unused-d3d12.dll", "D3D12CreateDevice"], wide: wide))).evidence.isEmpty)
        }
        for data in [Self.pe(loader, strings: ["d3d12.dll"]),
                     Self.pe(loader, strings: ["D3D12CreateDevice"]),
                     Self.pe([], strings: ["d3d12.dll", "D3D12CreateDevice"]),
                     Self.pe(loader, strings: ["d3d12.dll", "D3D12CreateDevice"], sectionName: ".rsrc"),
                     Self.pe(loader, strings: ["unused-d3d12.dll", "D3D12CreateDevice"])] {
            XCTAssertTrue(try XCTUnwrap(Direct3D.inspect(data)).evidence.isEmpty)
        }
        let exe = try write("game.exe", Self.pe(loader, strings: ["d3d12.dll", "D3D12CreateDevice"]))
        XCTAssertTrue(Direct3D.detect(executable: exe, root: root).hasDirect3D12)
    }

    func testAPIVersionsAndDualRendererDoNotClaimActiveVersion() throws {
        for (api, library, function) in [(Direct3D.API.d3d8, "d3d8.dll", "Direct3DCreate8"),
                                          (.d3d9, "d3d9.dll", "Direct3DCreate9Ex"),
                                          (.d3d10, "d3d10_1.dll", "D3D10CreateDevice"),
                                          (.d3d11, "d3d11.dll", "D3D11CreateDevice"),
                                          (.d3d12, "d3d12core.dll", "D3D12GetInterface")] {
            XCTAssertEqual(Direct3D.inspect(Self.pe([(library, [])]))?.evidence.first?.api, api)
            XCTAssertEqual(Direct3D.inspect(Self.pe([("proxy.dll", [function])]))?.evidence.first?.api, api)
        }
        let exe = try write("game.exe", Self.pe([("proxy.dll", ["D3D11CreateDevice", "D3D12CreateDevice"])]))
        let result = Direct3D.detect(executable: exe, root: root)
        XCTAssertEqual(result.apis, [.d3d11, .d3d12])
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(), importsDirect3D12: result.hasDirect3D12).graphics, .vulkan)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: "-dx11"), global: LaunchSettings(), importsDirect3D12: result.hasDirect3D12).graphics, .dxmt)
    }

    func testUnknownIsUnknownAndDetectionRoundTrips() throws {
        let exe = try write("game.exe", Self.pe([]))
        let result = Direct3D.detect(executable: exe, root: root)
        XCTAssertEqual(result.summary, "Unknown")
        XCTAssertEqual(try JSONDecoder().decode(Direct3D.Detection.self, from: JSONEncoder().encode(result)), result)
        XCTAssertNil(Direct3D.inspect(Data("d3d12.dll\0D3D12CreateDevice\0".utf8)))
    }

    func testEscapingPathsAndSymlinksAreNotFollowed() throws {
        let outside = root.appendingPathComponent("outside")
        let game = root.appendingPathComponent("title")
        try write("outside/engine.dll", Self.pe([("d3d12.dll", [])]))
        let exe = try write("title/game.exe", Self.pe([("engine.dll", []), ("../outside/engine.dll", [])]))
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("engine.dll"), withDestinationURL: outside.appendingPathComponent("engine.dll"))
        XCTAssertFalse(Direct3D.detect(executable: exe, root: game).hasDirect3D12)
        XCTAssertEqual(Direct3D.detect(executable: outside.appendingPathComponent("engine.dll"), root: game).modulesScanned, 0)
    }

    func testDependencyDepthAndModuleBudgets() throws {
        let exe = try write("game.exe", Self.pe([("a0.dll", [])]))
        for n in 0..<6 { try write("a\(n).dll", Self.pe([("a\(n + 1).dll", [])])) }
        try write("a6.dll", Self.pe([("d3d12.dll", [])]))
        var result = Direct3D.detect(executable: exe, root: root)
        XCTAssertFalse(result.hasDirect3D12)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.modulesScanned, 5)
        let imports = (0..<40).map { ("m\($0).dll", [String]()) }
        try Self.pe(imports).write(to: exe)
        for n in 0..<40 { try write("m\(n).dll", Self.pe([])) }
        result = Direct3D.detect(executable: exe, root: root)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.modulesScanned, 32)
    }

    func testOversizedFileBudgetDoesNotReadTheWholeFile() throws {
        let exe = try write("huge.exe", Self.pe([("d3d12.dll", [])]))
        let handle = try FileHandle(forWritingTo: exe)
        try handle.truncate(atOffset: 129 * 1024 * 1024) // sparse; no 129 MiB allocation
        try handle.close()
        let result = Direct3D.detect(executable: exe, root: root)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.modulesScanned, 0)
        XCTAssertFalse(result.hasDirect3D12)
    }

    func testVAAddressedDelayFunctionsInPE32() throws {
        var data = Self.pe([("proxy.dll", ["D3D12CreateDevice"])], plus: false, delay: true)
        func get(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) } }
        func put(_ at: Int, _ value: Int) {
            for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        let base = 0x400000, thunk = get(512 + 16) - 0x1000 + 512
        put(0x98 + 28, base)
        put(512, 0) // VA-based delay import descriptor
        put(512 + 4, get(512 + 4) + base)
        put(512 + 16, get(512 + 16) + base)
        put(thunk, get(thunk) + base)
        XCTAssertTrue(Direct3D12.imports(in: data))
    }

    func testMalformedThunksAndOrdinalsAreSafe() throws {
        var data = Self.pe([("proxy.dll", ["D3D12CreateDevice"])])
        // Find the normal import's thunk table and replace its first entry with
        // a 64-bit ordinal (not an enormous name RVA).
        let thunkRVA = (0..<4).reduce(0) { $0 | Int(data[512 + $1]) << ($1 * 8) }
        let at = thunkRVA - 0x1000 + 512
        data.replaceSubrange(at..<(at + 8), with: [1, 0, 0, 0, 0, 0, 0, 128])
        XCTAssertTrue(try XCTUnwrap(Direct3D.inspect(data)).evidence.isEmpty)
        data.replaceSubrange(at..<(at + 8), with: [255, 255, 255, 255, 0, 0, 0, 0])
        XCTAssertTrue(try XCTUnwrap(Direct3D.inspect(data)).evidence.isEmpty)
        for size in stride(from: 0, to: data.count, by: 13) { _ = Direct3D.inspect(Data(data.prefix(size))) }
    }
}
