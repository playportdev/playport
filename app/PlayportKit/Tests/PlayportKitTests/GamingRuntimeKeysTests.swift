// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// The keys a GDK game and its runtime read in the prefix (an Xbox copy's play, decision
/// 0166), as Xodus Nexus's prefix holds them: Gaming Services' version, a REG_QWORD, and
/// the Store's WinRT class served by xgameruntime.dll, in both views of HKLM\Software.
final class GamingRuntimeKeysTests: XCTestCase {
    func testTheGamingServicesVersionAndTheStoreClassAreToppedUpInBothViews() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("gdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let file = PrefixRegistryFile(prefix: prefix)
        try file.add(GamingRuntimeKeys.values)
        let text = try String(contentsOf: file.url(.system), encoding: .utf8)
        for root in [#"Software"#, #"Software\Wow6432Node"#] {
            // Nexus's prefix (system.reg): "CurrentVersion"=hex(b):00,00,79,69,75,00,26,00, Gaming Services 38.117.27001.0.
            for name in ["CurrentVersion", "AvailableVersion"] {
                XCTAssertTrue(text.contains("[\(PrefixRegistryFile.escape(root + #"\Microsoft\GamingServices"#, "[]"))]"), root)
                XCTAssertTrue(text.contains("\"\(name)\"=hex(b):00,00,79,69,75,00,26,00\n"), "\(root) \(name)")
            }
            let store = root + #"\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Services.Store.StoreContext"#
            XCTAssertEqual(PrefixRegistryFile.string(inHive: text, key: store, name: "DllPath"), #"C:\windows\system32\xgameruntime.dll"#)
            XCTAssertEqual(PrefixRegistryFile.dword(inHive: text, key: store, name: "ThreadingModel"), 0)
        }
        XCTAssertTrue(text.hasPrefix(";; playport:top-up\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url(.user).path))
        // Read back as written: a later top-up keeps them.
        XCTAssertEqual(file.values(.system), GamingRuntimeKeys.values)
    }
}
