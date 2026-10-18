// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// Install scripts as Steam ships them (decision 0081): the bodies below are real scripts, from
/// DiRT 3's own `_CommonRedist`, the Steamworks Common Redistributables depots (VC++ 2022, DirectX
/// June 2010, .NET 4.8) and Red Dead Redemption's root; Steam's `kvsignatures` root after each is kept.
final class SteamInstallScriptTests: XCTestCase {
    static let openAL = #"""
    "installscript"
    {
    	"Run Process"
    	{
    		"2.0.7.0"
    		{
    			"hasrunkey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\OpenAL\\2.0.7.0"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\OpenAL\\2.0.7.0\\oalinst.exe"
    			"command 1"		"/s"
    			"nocleanup"		"1"
    		}
    	}
    }
    "kvsignatures"
    {
    	"installscript"		"35e9d3762db87efad266fbbc15ae7015"
    }
    """#

    static let vc2022 = #"""
    "installscript"
    {
    	"Run Process"
    	{
    		"x86 14.51.36247.0"
    		{
    			"hasrunkey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\vcredist\\2022"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\vcredist\\2022\\Microsoft Visual C++ 2022 x86.cmd"
    			"nocleanup"		"1"
    		}
    		"x64 14.51.36247.0"
    		{
    			"hasrunkey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\vcredist\\2022"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\vcredist\\2022\\Microsoft Visual C++ 2022 x64.cmd"
    			"nocleanup"		"1"
    			"Requirement_OS"
    			{
    				"Is64BitWindows"		"1"
    			}
    		}
    	}
    }
    "kvsignatures"
    {
    	"installscript"		"37b956c53a94306a1f93f39b84e7cfcb"
    }
    """#

    static let directX = #"""
    "installscript"
    {
    	"Run Process"
    	{
    		"dxsetup"
    		{
    			"hasrunkey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\DirectX\\Jun2010"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\DirectX\\Jun2010\\DXSETUP.exe"
    			"command 1"		"/silent"
    			"nocleanup"		"1"
    		}
    	}
    }
    """#

    static let dotNet = #"""
    "InstallScript"
    {
    	"Run Process"
    	{
    		"4.8"
    		{
    			"HasRunKey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\.NET\\4.8"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\DotNet\\4.8\\noop.cmd"
    			"NoCleanUp"		"1"
    			"Requirement_OS"
    			{
    				"OSType"		"Windows XP"
    			}
    		}
    		"4.8"
    		{
    			"HasRunKey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\CommonRedist\\.NET\\4.8"
    			"process 1"		"%INSTALLDIR%\\_CommonRedist\\DotNet\\4.8\\Microsoft .NET Framework 4.8.cmd"
    			"NoCleanUp"		"1"
    		}
    	}
    }
    """#

    static let redDead = #"""
    "InstallScript"
    {
    	"Registry"
    	{
    		"HKEY_LOCAL_MACHINE\\SOFTWARE\\Rockstar Games\\Red Dead Redemption\\"
    		{
    			"string"
    			{
    				"InstallFolderSteam"		"%INSTALLDIR%\\"
    			}
    		}
    	}
    	"Run Process On Uninstall"
    	{
    		"Clear"
    		{
    			"process 1"		"%INSTALLDIR%\\Game.exe"
    		}
    	}
    }
    """#

    var games: URL!

    override func setUpWithError() throws {
        games = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: games)
    }

    func touch(_ rel: String) throws {
        let url = games.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func parse(_ s: String) throws -> SteamInstallScript { try SteamInstallScript.parse(Data(s.utf8)) }

    func testRunProcessEntriesParseWithStepsKeysAndRequirementsInAnyCase() throws {
        let al = try parse(Self.openAL)
        XCTAssertEqual(al.runProcesses, [.init(
            name: "2.0.7.0", hasRunKey: #"HKEY_LOCAL_MACHINE\Software\Valve\Steam\Apps\CommonRedist\OpenAL\2.0.7.0"#,
            minimumHasRunValue: 1, steps: [.init(process: #"%INSTALLDIR%\_CommonRedist\OpenAL\2.0.7.0\oalinst.exe"#, command: "/s")],
            noCleanUp: true, requirementOS: [:])])
        let vc = try parse(Self.vc2022)
        XCTAssertEqual(vc.runProcesses.map(\.name), ["x86 14.51.36247.0", "x64 14.51.36247.0"])
        XCTAssertEqual(vc.runProcesses[1].requirementOS, ["is64bitwindows": "1"])
        XCTAssertEqual(vc.runProcesses[0].steps.first?.command, "")
        XCTAssertThrowsError(try parse(#""AppState" { "appid" "1" }"#), "not an install script")
    }

    func testRequirementsHoldFor64BitWindows10Only() throws {
        let vc = try parse(Self.vc2022)
        XCTAssertTrue(vc.runProcesses.allSatisfy(\.appliesToPrefix), "x86 and x64 both run on 64-bit Windows, as Steam runs them")
        let net = try parse(Self.dotNet)
        XCTAssertEqual(net.runProcesses.map(\.appliesToPrefix), [false, true], "the Windows XP entry is not Windows 10's")
        var r = vc.runProcesses[1]
        r.requirementOS = ["is64bitwindows": "0"]
        XCTAssertFalse(r.appliesToPrefix)
        r.requirementOS = ["somethingnew": "1"]
        XCTAssertFalse(r.appliesToPrefix, "an unknown requirement is not guessed")
    }

    func testIdsAreTheHasRunKeyAndTheEntryOrTheAppAndScript() throws {
        let vc = try parse(Self.vc2022)
        XCTAssertEqual(vc.runProcesses[1].id(appID: 10, script: "x"),
                       #"HKEY_LOCAL_MACHINE\Software\Valve\Steam\Apps\CommonRedist\vcredist\2022|x64 14.51.36247.0"#)
        var eac = vc.runProcesses[1]
        eac.hasRunKey = nil
        XCTAssertEqual(eac.id(appID: 2655180, script: "installscript.vdf"), "steam-2655180:installscript.vdf|x64 14.51.36247.0")
    }

    func testAGamesOwnOpenALInstallerBecomesAPrerequisiteWritingItsHasRunKey() throws {
        try touch("DiRT 3/_CommonRedist/OpenAL/2.0.7.0/oalinst.exe")
        var s = SteamPrerequisites()
        s.add(try parse(Self.openAL), appID: 321040, installDir: "DiRT 3", script: "_CommonRedist/OpenAL/2.0.7.0/installscript.vdf",
              games: games, hive: "")
        XCTAssertEqual(s.notes, [])
        XCTAssertEqual(s.prerequisites, [Prerequisite(
            ids: [#"HKEY_LOCAL_MACHINE\Software\Valve\Steam\Apps\CommonRedist\OpenAL\2.0.7.0|2.0.7.0"#],
            name: "Steam 2.0.7.0 (_CommonRedist/OpenAL/2.0.7.0/installscript.vdf)",
            exe: #"Games\DiRT 3\_CommonRedist\OpenAL\2.0.7.0\oalinst.exe"#, args: ["/s"],
            successRegistry: [PrefixRegistryValue(hive: .system, key: #"Software\Valve\Steam\Apps\CommonRedist\OpenAL\2.0.7.0"#,
                                                  name: "2.0.7.0", data: .dword(1))])])
    }

    func testRedistributablesRunFromSteamworksSharedMatchedWithoutCase() throws {
        try touch("Steamworks Shared/_CommonRedist/vcredist/2022/Microsoft Visual C++ 2022 x86.cmd")
        try touch("Steamworks Shared/_CommonRedist/vcredist/2022/Microsoft Visual C++ 2022 x64.cmd")
        try touch("Steamworks Shared/_CommonRedist/DirectX/Jun2010/dxsetup.exe")
        var s = SteamPrerequisites()
        s.add(try parse(Self.vc2022), appID: 945360, installDir: "Steamworks Shared",
              script: "_CommonRedist/vcredist/2022/installscript.vdf", games: games, hive: "")
        s.add(try parse(Self.directX), appID: 945360, installDir: "Steamworks Shared",
              script: "_CommonRedist/DirectX/Jun2010/installscript.vdf", games: games, hive: "")
        XCTAssertEqual(s.prerequisites.map(\.exe), [
            #"Games\Steamworks Shared\_CommonRedist\vcredist\2022\Microsoft Visual C++ 2022 x86.cmd"#,
            #"Games\Steamworks Shared\_CommonRedist\vcredist\2022\Microsoft Visual C++ 2022 x64.cmd"#,
        ], "DXSETUP is skipped, not run")
        XCTAssertEqual(s.skipped.map(\.name), ["Steam DirectX"])
    }

    func testDirectXSetupIsSkippedWithItsHasRunKeyWrittenAsASuccessWould() throws {
        try touch("Steamworks Shared/_CommonRedist/DirectX/Jun2010/DXSETUP.exe")
        var s = SteamPrerequisites()
        s.add(try parse(Self.directX), appID: 207100, installDir: "Steamworks Shared",
              script: "_CommonRedist/DirectX/Jun2010/installscript.vdf", games: games, hive: "")
        XCTAssertEqual(s.prerequisites, [])
        XCTAssertEqual(s.notes, [])
        let key = #"HKEY_LOCAL_MACHINE\Software\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010"#
        XCTAssertEqual(s.skipped, [SteamPrerequisites.Skipped(
            ids: [key + "|dxsetup"], name: "Steam DirectX", key: key, reason: SteamPrerequisites.directXSkipReason,
            registry: [PrefixRegistryValue(hive: .system, key: #"Software\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010"#,
                                           name: "dxsetup", data: .dword(1))])])
        XCTAssertEqual(s.skipped[0].line, "prerequisite: Steam DirectX (\(key)) skipped: Playport's built-in DirectX libraries cover it")
        // Once the hive holds the value, it counts as run, as Steam's own check.
        let hive = "WINE REGISTRY Version 2\n\n[Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010] 1768033321\n"
            + "\"dxsetup\"=dword:00000001\n\n"
        var t = SteamPrerequisites()
        t.add(try parse(Self.directX), appID: 207100, installDir: "Steamworks Shared",
              script: "_CommonRedist/DirectX/Jun2010/installscript.vdf", games: games, hive: hive)
        XCTAssertEqual(t.skipped, [])
        XCTAssertTrue(t.notes[0].contains("already run"), t.notes[0])
        // Nothing ran, so the Play does not restart (decision 0084).
        XCTAssertFalse(PlayContinuation.restartsBeforeGame(prerequisitesRan: s.prerequisites.count, canRestart: true, pool: nil))
    }

    func testDirectXJun2010WithoutItsDepotIsSkippedFromTheKnownScript() throws {
        // Not downloaded (depot 228990 alone): the known script gives the same skip.
        var s = SteamPrerequisites()
        s.add(.directXJun2010, appID: 207100, installDir: "Steamworks Shared", script: SteamInstallScript.directXJun2010Script,
              games: games, hive: "")
        var t = SteamPrerequisites()
        t.add(try parse(Self.directX), appID: 207100, installDir: "Steamworks Shared",
              script: SteamInstallScript.directXJun2010Script, games: games, hive: "")
        XCTAssertEqual(s, t)
        XCTAssertEqual(s.skipped.count, 1)
        XCTAssertEqual(try parse(Self.directX).runProcesses, SteamInstallScript.directXJun2010.runProcesses)
    }

    func testOnlyDXSETUPUnderACommonRedistDirectXFolderIsDirectXSetup() throws {
        func entry(_ processes: [String]) -> SteamInstallScript.RunProcess {
            .init(name: "e", hasRunKey: nil, minimumHasRunValue: 1, steps: processes.map { .init(process: $0, command: "") },
                  noCleanUp: false, requirementOS: [:])
        }
        XCTAssertTrue(entry([#"%INSTALLDIR%\_CommonRedist\DirectX\Jun2010\DXSETUP.exe"#]).isDirectXSetup)
        XCTAssertTrue(entry([#"%INSTALLDIR%\redist\_commonredist\directx\dxsetup.EXE"#]).isDirectXSetup, "any case, any folder")
        XCTAssertTrue(entry(["%INSTALLDIR%/_CommonRedist/DirectX/Jun2010/DXSETUP.exe"]).isDirectXSetup)
        XCTAssertFalse(entry([#"%INSTALLDIR%\_CommonRedist\DXSETUP.exe"#]).isDirectXSetup, "not under DirectX")
        XCTAssertFalse(entry([#"%INSTALLDIR%\Redist\DirectX\DXSETUP.exe"#]).isDirectXSetup, "not under _CommonRedist")
        XCTAssertFalse(entry([#"%INSTALLDIR%\_CommonRedist\DirectX\Jun2010\dxwebsetup.exe"#]).isDirectXSetup)
        XCTAssertFalse(entry([#"%INSTALLDIR%\_CommonRedist\DirectX\Jun2010\DXSETUP.exe"#,
                              #"%INSTALLDIR%\_CommonRedist\vcredist\2010\vcredist_x86.exe"#]).isDirectXSetup)
        XCTAssertFalse(entry([]).isDirectXSetup)
    }

    func testAnEntryAlreadyRunPerTheHiveOrMissingIsLeftOut() throws {
        try touch("Shared/_CommonRedist/DotNet/4.8/Microsoft .NET Framework 4.8.cmd")
        // The seed's Proton keys: .NET counts as run (Wine Mono serves it).
        let hive = "WINE REGISTRY Version 2\n\n[Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\.NET\\\\4.8] 1768033321\n"
            + "#time=1dc820a31c9c926\n\"4.8\"=dword:00000001\n\n"
        var s = SteamPrerequisites()
        s.add(try parse(Self.dotNet), appID: 1, installDir: "Shared", script: "n.vdf", games: games, hive: hive)
        XCTAssertEqual(s.prerequisites, [])
        XCTAssertEqual(s.notes.count, 2)
        XCTAssertTrue(s.notes[1].contains("already run"), s.notes[1])
        // Not shipped: left out, not a failure.
        var t = SteamPrerequisites()
        t.add(try parse(Self.openAL), appID: 1, installDir: "Shared", script: "a.vdf", games: games, hive: "")
        XCTAssertEqual(t.prerequisites, [])
        XCTAssertTrue(t.notes[0].contains("is not in Games/Shared"), t.notes[0])
    }

    func testRegistryEntriesExpandTheInstallFolder() throws {
        var s = SteamPrerequisites()
        s.add(try parse(Self.redDead), appID: 2668510, installDir: "Red Dead Redemption", script: "installscript.vdf",
              games: games, hive: "")
        XCTAssertEqual(s.prerequisites, [], "Run Process On Uninstall is not run")
        XCTAssertEqual(s.registry, [PrefixRegistryValue(hive: .system, key: #"SOFTWARE\Rockstar Games\Red Dead Redemption"#,
                                                        name: "InstallFolderSteam", data: .string(#"C:\Games\Red Dead Redemption\"#))])
    }

    func testScriptsOfAGameNotDownloadedByPlayportAreFoundByName() throws {
        try touch("G/installscript.vdf")
        try touch("G/install_script.vdf")
        try touch("G/readme.txt")
        try touch("G/_CommonRedist/OpenAL/2.0.7.0/installscript.vdf")
        try touch("G/_CommonRedist/OpenAL/2.0.7.0/oalinst.exe")
        try touch("G/Data/installscript.vdf")
        XCTAssertEqual(SteamPrerequisites.scriptFiles(in: games.appendingPathComponent("G")),
                       ["_CommonRedist/OpenAL/2.0.7.0/installscript.vdf", "install_script.vdf", "installscript.vdf"])
    }

    func testRegistryFileRoundTripsInWineserversFormat() throws {
        let file = PrefixRegistryFile(prefix: games)
        try file.add([PrefixRegistryValue(hive: .system, key: #"Software\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010"#,
                                          name: "dxsetup", data: .dword(1)),
                      PrefixRegistryValue(hive: .system, key: #"SOFTWARE\Rockstar Games\Red Dead Redemption"#,
                                          name: "InstallFolderSteam", data: .string(#"C:\Games\Red "Dead"\"#))])
        try file.add([PrefixRegistryValue(hive: .system, key: #"software\rockstar games\red dead redemption"#,
                                          name: "installfoldersteam", data: .string(#"C:\Games\RDR\"#))])
        let text = try String(contentsOf: file.url(.system), encoding: .utf8)
        XCTAssertEqual(text, ";; playport:top-up\n[Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010]\n"
                       + "\"dxsetup\"=dword:00000001\n\n"
                       + ";; playport:top-up\n[software\\\\rockstar games\\\\red dead redemption]\n"
                       + "\"installfoldersteam\"=\"C:\\\\Games\\\\RDR\\\\\"\n\n")
        XCTAssertEqual(file.values(.system).count, 2)
        XCTAssertEqual(PrefixRegistryFile.dword(inHive: text, key: #"SOFTWARE\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010"#,
                                                name: "DXSETUP"), 1)
        XCTAssertNil(PrefixRegistryFile.dword(inHive: text, key: #"Software\Valve\Steam\Apps\CommonRedist\DirectX"#, name: "dxsetup"))
        XCTAssertEqual(PrefixRegistryFile.unescape(PrefixRegistryFile.escape("a\\b\"c\u{e9}\n", "\"\"")), "a\\b\"c\u{e9}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url(.user).path))
    }

    /// The keys a genuine steam_api reads to find Playport's Steam client (decision 0115): user hive
    /// top-ups, with no pid (the session root's while a play runs).
    func testSteamClientKeysPointAtThePrefixsSteamFolder() throws {
        let file = PrefixRegistryFile(prefix: games)
        try file.add(SteamClientKeys.values)
        let text = try String(contentsOf: file.url(.user), encoding: .utf8)
        XCTAssertEqual(PrefixRegistryFile.string(inHive: text, key: #"Software\Valve\Steam\ActiveProcess"#, name: "SteamClientDll64"),
                       #"C:\Program Files (x86)\Steam\steamclient64.dll"#)
        XCTAssertEqual(PrefixRegistryFile.string(inHive: text, key: #"Software\Valve\Steam"#, name: "SteamPath"),
                       "c:/program files (x86)/steam")
        XCTAssertEqual(PrefixRegistryFile.string(inHive: text, key: #"Software\Valve\Steam"#, name: "SteamExe"),
                       "c:/program files (x86)/steam/steam.exe")
        XCTAssertFalse(text.contains("\"pid\""))
        XCTAssertTrue(text.hasPrefix(";; playport:top-up\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url(.system).path))
    }
}
