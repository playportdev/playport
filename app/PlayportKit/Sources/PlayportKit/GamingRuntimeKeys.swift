// SPDX-License-Identifier: GPL-3.0-or-later
// The prefix keys a GDK game and the Xbox runtime (xgameruntime.dll, staged in the runtime's
// arm64ec-windows set and so linked into system32) read, written for an Xbox copy's play as
// Xodus Nexus has them in its prefix (decision 0179): Gaming Services' installed and available
// version, which the game's own GDK thunks check before they load the runtime (Nexus writes
// it before every launch, scripts/runtime-compat/gaming-services-version.c), and the Store's
// WinRT class, Windows.Services.Store.StoreContext, served by xgameruntime.dll. Top-ups
// (PrefixRegistryFile): a prefix that has them keeps its own.
//
// Every value is in both views of HKLM\Software, as SteamClientKeys: this runtime sends an
// x64 process's 64-bit-view read into Software\Wow6432Node.

import Foundation

public enum GamingRuntimeKeys {
    /// Gaming Services 38.117.27001.0 (Nexus's), as Windows' QWORD version: major, minor,
    /// build, revision in 16 bits each.
    public static let gamingServicesVersion: UInt64 = 38 << 48 | 117 << 32 | 27001 << 16 | 0

    public static let runtimeDLL = #"C:\windows\system32\xgameruntime.dll"#

    public static let values: [PrefixRegistryValue] = [#"Software"#, #"Software\Wow6432Node"#].flatMap { root in [
        PrefixRegistryValue(hive: .system, key: root + #"\Microsoft\GamingServices"#, name: "CurrentVersion",
                            data: .qword(gamingServicesVersion)),
        PrefixRegistryValue(hive: .system, key: root + #"\Microsoft\GamingServices"#, name: "AvailableVersion",
                            data: .qword(gamingServicesVersion)),
        PrefixRegistryValue(hive: .system, key: root + #"\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Services.Store.StoreContext"#,
                            name: "DllPath", data: .string(runtimeDLL)),
        PrefixRegistryValue(hive: .system, key: root + #"\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Services.Store.StoreContext"#,
                            name: "ThreadingModel", data: .dword(0)),
    ] }
}
