// SPDX-License-Identifier: GPL-3.0-or-later
// The prefix's `HKCU\Software\Valve\Steam` keys a genuine steam_api reads to find a Steam
// client (decision 0115): Steam's folder and executable, and in `ActiveProcess` the client
// DLLs it loads. Top-ups (PrefixRegistryFile), written for a play in client mode only;
// ActiveProcess's `pid` and `ActiveUser` are the session root's to write while a play runs
// (PP_REQUEST_STEAM_CLIENT), so they are not here.

import Foundation

public enum SteamClientKeys {
    /// Where Playport's steamclient64.dll goes in the prefix, as Steam installs itself.
    public static let folder = #"C:\Program Files (x86)\Steam"#
    public static let activeProcess = #"Software\Valve\Steam\ActiveProcess"#

    public static let values: [PrefixRegistryValue] = {
        // Steam writes its own paths in lower case with forward slashes.
        let steam = folder.lowercased().replacingOccurrences(of: "\\", with: "/")
        return [
            .init(hive: .user, key: #"Software\Valve\Steam"#, name: "SteamPath", data: .string(steam)),
            .init(hive: .user, key: #"Software\Valve\Steam"#, name: "SteamExe", data: .string(steam + "/steam.exe")),
            .init(hive: .user, key: activeProcess, name: "SteamClientDll", data: .string(folder + #"\steamclient.dll"#)),
            .init(hive: .user, key: activeProcess, name: "SteamClientDll64", data: .string(folder + #"\steamclient64.dll"#)),
        ]
    }()
}
