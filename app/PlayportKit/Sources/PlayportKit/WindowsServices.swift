// SPDX-License-Identifier: GPL-3.0-or-later
// Windows services for a play that needs them (decision 0107): the session root starts
// services.exe, Wine's SCM, before the title and stops it and its services before it reports
// the title's end. The prefix seed holds no service entry (decision 0080), so COM's rpcss,
// which combase starts through the SCM (StartService "RpcSs"), gets wine.inf's entry for it
// here, as a top-up: written only where the prefix lacks it, and never removed (nothing starts
// it unless the SCM runs). The mount manager's entry (decision 0118) and services.exe's start
// timeout are topped up the same way.

import Foundation

public enum WindowsServices {
    /// The service key wine.inf's `[RpcSsService]` makes (AddService=RpcSs): rpcss.exe,
    /// `ServiceType` 32 (a shared-process service), demand start, normal error control, as
    /// setupapi writes them: `Type`, `Start`, `ErrorControl`, `ImagePath`, `DisplayName` and
    /// `Description`.
    public static let rpcss: [PrefixRegistryValue] = {
        let key = #"System\CurrentControlSet\Services\RpcSs"#
        return [
            .init(hive: .system, key: key, name: "Type", data: .dword(0x20)),
            .init(hive: .system, key: key, name: "Start", data: .dword(3)),
            .init(hive: .system, key: key, name: "ErrorControl", data: .dword(1)),
            .init(hive: .system, key: key, name: "ImagePath", data: .string(#"C:\windows\system32\rpcss.exe"#)),
            .init(hive: .system, key: key, name: "DisplayName", data: .string("Remote Procedure Call (RPC)")),
            .init(hive: .system, key: key, name: "Description", data: .string("RPC service")),
        ]
    }()

    /// The service key wine.inf's `[MountMgrService]` makes (AddService=MountMgr): the mount
    /// manager, `mountmgr.sys`, a kernel driver (`ServiceType` 1) that the SCM starts with itself
    /// (boot start) in winedevice.exe, in the "System Bus Extender" group (decision 0118). It makes
    /// `\Device\Harddisk0` (`\\.\PhysicalDrive0`), a volume per drive and the mount point
    /// manager; the Rockstar Games Launcher halts after sign-in when no physical drive opens.
    public static let mountmgr: [PrefixRegistryValue] = {
        let key = #"System\CurrentControlSet\Services\MountMgr"#
        return [
            .init(hive: .system, key: key, name: "Type", data: .dword(1)),
            .init(hive: .system, key: key, name: "Start", data: .dword(0)),
            .init(hive: .system, key: key, name: "ErrorControl", data: .dword(1)),
            .init(hive: .system, key: key, name: "Group", data: .string("System Bus Extender")),
            .init(hive: .system, key: key, name: "ImagePath", data: .string(#"C:\windows\system32\drivers\mountmgr.sys"#)),
            .init(hive: .system, key: key, name: "DisplayName", data: .string("Mount Manager")),
            .init(hive: .system, key: key, name: "Description", data: .string("Device mounting service")),
        ]
    }()

    /// Everything a play with Windows services tops up in the prefix: RpcSs's and MountMgr's
    /// service entries and the SCM's start timeout.
    public static let prefixEntries: [PrefixRegistryValue] = rpcss + mountmgr + [startTimeout]

    /// How long services.exe waits for a service it started to connect (Wine reads
    /// `ServicesPipeTimeout` under `Control` as a string, in milliseconds; 10 s when absent).
    /// The Rockstar Games Launcher's Rockstar Service rewrites its own code for about 28 s
    /// under FEX before it connects, so the default ended it each time (run
    /// `20261016T004627`). Two minutes; a prefix that sets its own keeps it.
    public static let startTimeout = PrefixRegistryValue(
        hive: .system, key: #"System\CurrentControlSet\Control"#, name: "ServicesPipeTimeout", data: .string("120000"))
}
