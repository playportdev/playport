// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's CPU features as the kernel reports them (sysctl
// hw.optional.arm.FEAT_*). FEX cannot read the ID registers from EL0 on iOS
// and builds its feature set by hand (patches/fex-port 0009), so a launch
// passes it what it can use (LaunchCoordinator, FEXProfile.hostFeatures):
// FEAT_LRCPC2, whose LDAPUR and STLUR let a TSO access keep its offset
// (patches/fex 0008). The rest are logged for the record.

import Darwin

enum HostCPU {
    /// One feature: nil when this kernel has no such sysctl.
    static func feature(_ name: String) -> Bool? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm." + name, &value, &size, nil, 0) == 0 else { return nil }
        return value != 0
    }

    static let lrcpc2 = feature("FEAT_LRCPC2") == true

    /// `FEAT_LRCPC=1 FEAT_LRCPC2=1 ...`, `-` for a sysctl the kernel lacks.
    static let summary: String = ["FEAT_LRCPC", "FEAT_LRCPC2", "FEAT_LRCPC3", "FEAT_LSE2", "FEAT_AFP"].map { name in
        "\(name)=\(feature(name).map { $0 ? "1" : "0" } ?? "-")"
    }.joined(separator: " ")
}
