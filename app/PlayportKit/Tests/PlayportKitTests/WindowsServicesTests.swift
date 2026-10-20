// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// Windows services for a play that needs them (decision 0107): the per-game setting, the
/// compatibility table's entry for Red Dead Redemption 2, and RpcSs's and MountMgr's service entries.
final class WindowsServicesTests: XCTestCase {
    func testTheSettingIsOffUnlessAGameOrItsCompatibilityDefaultTurnsItOn() throws {
        let global = LaunchSettings()
        XCTAssertFalse(LaunchSettings.resolve(game: nil, global: global).windowsServices)
        XCTAssertTrue(LaunchSettings.resolve(game: LaunchSettings(windowsServices: true), global: global).windowsServices)
        // A person's Off wins over the game's compatibility default; nil follows it.
        let compat = LaunchSettings(windowsServices: true)
        XCTAssertEqual(LaunchSettings(windowsServices: false).over(compat).windowsServices, false)
        XCTAssertEqual(LaunchSettings().over(compat).windowsServices, true)
        XCTAssertFalse(LaunchSettings(windowsServices: false).isEmpty)
        XCTAssertTrue(LaunchSettings().isEmpty)
        // Stored and read back; a record from before the setting reads as nil.
        let back = try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(LaunchSettings(windowsServices: true)))
        XCTAssertEqual(back.windowsServices, true)
        XCTAssertNil(try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"screen":"720"}"#.utf8)).windowsServices)
    }

    func testTheShippedTableTurnsThemOnForRedDeadRedemption2Only() throws {
        let table = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        let rdr2 = try XCTUnwrap(table.entry(for: "app-1174180"))
        XCTAssertEqual(rdr2.settings, LaunchSettings(graphics: .vulkan, steamAPI: .client, runtime: CompatDefaultsTests.rdr2Runtime,
                                                     windowsServices: true, jitPoolMB: 896, khronosVulkanLoader: true,
                                                     endLauncherAfterSignIn: true))
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.settings.windowsServices)
        XCTAssertNil(table.entry(for: "app-367520"))   // Hollow Knight starts no services
    }

    /// A release build runs RDR2 with its address-space holdback, the compatibility default's own
    /// runtime key, and no person's keys (decision 0126).
    func testAReleaseBuildKeepsOnlyTheCompatibilityDefaultsRuntimeKeys() throws {
        let table = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        XCTAssertEqual(LaunchSettings.releaseRuntime(compat: table.entry(for: "app-1174180")?.settings)["jumbo-mb"], "8960")
        XCTAssertEqual(LaunchSettings.releaseRuntime(compat: table.entry(for: "app-367520")?.settings), [:])
        XCTAssertEqual(LaunchSettings.releaseRuntime(compat: LaunchSettings(runtime: "no-equals")), [:])
    }

    func testRpcSsEntryIsWineInfsAndOnlyTopsUp() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let file = PrefixRegistryFile(prefix: prefix)
        try file.add(WindowsServices.rpcss)
        let text = try String(contentsOf: file.url(.system), encoding: .utf8)
        XCTAssertEqual(text, ";; playport:top-up\n[System\\\\CurrentControlSet\\\\Services\\\\RpcSs]\n"
                       + "\"Type\"=dword:00000020\n\"Start\"=dword:00000003\n\"ErrorControl\"=dword:00000001\n"
                       + "\"ImagePath\"=\"C:\\\\windows\\\\system32\\\\rpcss.exe\"\n"
                       + "\"DisplayName\"=\"Remote Procedure Call (RPC)\"\n\"Description\"=\"RPC service\"\n\n")
        // Written again, the file is the same: one entry, never a second.
        try file.add(WindowsServices.rpcss)
        XCTAssertEqual(try String(contentsOf: file.url(.system), encoding: .utf8), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url(.user).path))
    }

    func testMountMgrEntryIsWineInfsKernelDriverAndOnlyTopsUp() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let file = PrefixRegistryFile(prefix: prefix)
        try file.add(WindowsServices.mountmgr)
        let text = try String(contentsOf: file.url(.system), encoding: .utf8)
        // wine.inf [MountMgrService]: a kernel driver (1) the SCM starts with itself (boot, 0).
        XCTAssertEqual(text, ";; playport:top-up\n[System\\\\CurrentControlSet\\\\Services\\\\MountMgr]\n"
                       + "\"Type\"=dword:00000001\n\"Start\"=dword:00000000\n\"ErrorControl\"=dword:00000001\n"
                       + "\"Group\"=\"System Bus Extender\"\n"
                       + "\"ImagePath\"=\"C:\\\\windows\\\\system32\\\\drivers\\\\mountmgr.sys\"\n"
                       + "\"DisplayName\"=\"Mount Manager\"\n\"Description\"=\"Device mounting service\"\n\n")
        try file.add(WindowsServices.mountmgr)
        XCTAssertEqual(try String(contentsOf: file.url(.system), encoding: .utf8), text)
        // A play with services writes all three.
        XCTAssertEqual(WindowsServices.prefixEntries, WindowsServices.rpcss + WindowsServices.mountmgr + [WindowsServices.startTimeout])
    }

    func testTheStartTimeoutIsAStringServicesExeReadsAndOnlyTopsUp() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let file = PrefixRegistryFile(prefix: prefix)
        try file.add([WindowsServices.startTimeout])
        // Wine's services.exe reads ServicesPipeTimeout only as REG_SZ.
        XCTAssertEqual(try String(contentsOf: file.url(.system), encoding: .utf8),
                       ";; playport:top-up\n[System\\\\CurrentControlSet\\\\Control]\n\"ServicesPipeTimeout\"=\"120000\"\n\n")
    }
}
