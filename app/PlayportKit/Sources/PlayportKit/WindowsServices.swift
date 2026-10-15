// SPDX-License-Identifier: GPL-3.0-or-later
// Windows services for a play that needs them (decision 0107): the session root starts
// services.exe, Wine's SCM, before the title and stops it and its services before it reports
// the title's end. The prefix seed holds no service entry (decision 0080), so COM's rpcss,
// which combase starts through the SCM (StartService "RpcSs"), gets wine.inf's entry for it
// here, as a top-up: written only where the prefix lacks it, and never removed (nothing starts
// it unless the SCM runs).

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
}
