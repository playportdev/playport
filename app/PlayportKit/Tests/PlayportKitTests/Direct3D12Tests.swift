// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

final class Direct3D12Tests: XCTestCase {
    static func pe(plus: Bool = true, delay: Bool = false, va: Bool = false,
                   name: String = "D3D12.DLL") -> Data {
        var data = Data(repeating: 0, count: 1024)
        func put(_ at: Int, _ value: Int, _ bytes: Int = 4) {
            for i in 0..<bytes { data[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(0, 0x5a4d, 2)
        put(0x3c, 0x80)
        put(0x80, 0x4550)
        put(0x86, 1, 2)
        let size = plus ? 240 : 224
        put(0x94, size, 2)
        let opt = 0x98, directories = plus ? 112 : 96
        put(opt, plus ? 0x20b : 0x10b, 2)
        if !plus { put(opt + 28, 0x400000) }
        put(opt + 60, 512)
        put(opt + directories - 4, 16)
        let entry = opt + directories + (delay ? 13 : 1) * 8
        put(entry, 0x1000)
        put(entry + 4, delay ? 64 : 40)
        let section = opt + size
        put(section + 8, 512)
        put(section + 12, 0x1000)
        put(section + 16, 512)
        put(section + 20, 512)
        if delay { put(512, va ? 0 : 1) }
        put(512 + (delay ? 4 : 12), 0x1080 + (va ? 0x400000 : 0))
        data.replaceSubrange(640..<(640 + name.utf8.count + 1), with: Array(name.utf8) + [0])
        return data
    }

    func testNormalAndDelayImportsInPE32AndPE32Plus() {
        for plus in [false, true] {
            for delay in [false, true] {
                XCTAssertTrue(Direct3D12.imports(in: Self.pe(plus: plus, delay: delay)))
                XCTAssertFalse(Direct3D12.imports(in: Self.pe(plus: plus, delay: delay, name: "d3d11.dll")))
            }
        }
        XCTAssertTrue(Direct3D12.imports(in: Self.pe(plus: false, delay: true, va: true)))
        XCTAssertFalse(Direct3D12.imports(in: Self.pe(name: "d3d12.dll.backup")))
        XCTAssertFalse(Direct3D12.imports(in: Data("d3d12.dll".utf8)))
    }

    func testTruncatedAndMalformedPEIsSafe() {
        let valid = Self.pe()
        for size in 0..<valid.count {
            _ = Direct3D12.imports(in: Data(valid.prefix(size)))
        }
        var bad = valid
        bad.replaceSubrange(0x3c..<0x40, with: [255, 255, 255, 255])
        XCTAssertFalse(Direct3D12.imports(in: bad))
        bad = valid
        bad.replaceSubrange(524..<528, with: [255, 255, 255, 255])
        XCTAssertFalse(Direct3D12.imports(in: bad))
        bad = valid
        bad.replaceSubrange(0x98..<0x9a, with: [0, 0])
        XCTAssertFalse(Direct3D12.imports(in: bad))
    }

    func testDX12DefaultAndExplicitOverrides() {
        let global = LaunchSettings()
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: global, importsDirect3D12: true).graphics, .vulkan)
        for flag in ["-DX12", "-d3d12", "-force-d3d12"] {
            XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: flag), global: global).graphics, .vulkan)
        }
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: global, arguments: ["-DX12"]).graphics, .vulkan)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: "-dx11"), global: global,
                                             importsDirect3D12: true, arguments: ["-dx12"]).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: "-dx11 -DX12"), global: global).graphics, .vulkan)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: "-DX12-debug"), global: global).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(arguments: "-DX12")).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(graphics: .dxmt), importsDirect3D12: true).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(graphics: .dxmt, arguments: "-dx12"), global: global).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(graphics: .vulkan, arguments: "-dx11"), global: global).graphics, .vulkan)
    }
}
