// SPDX-License-Identifier: GPL-3.0-or-later
// The prefix's `HKCU\Software\Valve\Steam` keys a genuine steam_api reads to find a Steam
// client (decision 0115): Steam's folder and executable, and in `ActiveProcess` the client
// DLLs it loads. Top-ups (PrefixRegistryFile), written for a play in client mode only;
// ActiveProcess's `pid` and `ActiveUser` are the session root's to write while a play runs
// (PP_REQUEST_STEAM_CLIENT), so they are not here.
//
// Every value is written in both views of HKCU\Software: this runtime sends an x64 process's
// 64-bit-view read (KEY_WOW64_64KEY, as the Rockstar launcher's steam_api asks) into
// Software\Wow6432Node (run 20261018T112347), where Windows would not look; the 64-bit copy is
// the one Windows reads.

import Foundation

public enum SteamClientKeys {
    /// Where Playport's steamclient64.dll goes in the prefix, as Steam installs itself.
    public static let folder = #"C:\Program Files (x86)\Steam"#
    /// `Software\Valve\Steam` in the 64-bit view, then the same in the Wow6432Node view.
    public static let steamKeys = [#"Software\Valve\Steam"#, #"Software\Wow6432Node\Valve\Steam"#]

    public static let values: [PrefixRegistryValue] = {
        // Steam writes its own paths in lower case with forward slashes.
        let steam = folder.lowercased().replacingOccurrences(of: "\\", with: "/")
        return steamKeys.flatMap { key in [
            PrefixRegistryValue(hive: .user, key: key, name: "SteamPath", data: .string(steam)),
            PrefixRegistryValue(hive: .user, key: key, name: "SteamExe", data: .string(steam + "/steam.exe")),
            PrefixRegistryValue(hive: .user, key: key + #"\ActiveProcess"#, name: "SteamClientDll", data: .string(folder + #"\steamclient.dll"#)),
            PrefixRegistryValue(hive: .user, key: key + #"\ActiveProcess"#, name: "SteamClientDll64",
                                data: .string(folder + #"\steamclient64.dll"#)),
        ] }
    }()
}
