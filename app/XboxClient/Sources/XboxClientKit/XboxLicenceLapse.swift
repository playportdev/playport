// SPDX-License-Identifier: GPL-3.0-only
// What a licence result says about the copy itself, for its lapse (PLA-505;
// PlayportKit LicenceLapses): Playport's own, no Xodus or Nexus counterpart.
import Foundation

extension XboxLicenceResult {
    /// True when Microsoft granted the licence just now; false when it definitively refused
    /// this copy's; nil for no verdict on the copy: no answer, the stored licence standing
    /// in while licensing can't be reached, or the device refused (its ten-device limit).
    public var copyLicensed: Bool? {
        switch self {
        case .licensed(let licence): licence.source == .microsoft ? true : nil
        case .refused(.refused): false
        case .refused(.deviceLimit), .unavailable: nil
        }
    }
}
