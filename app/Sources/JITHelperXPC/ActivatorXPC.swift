// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The standalone activator's isolated, terminable JIT worker.
@objc(PlayportActivatorJITHelping)
public protocol ActivatorJITHelping {
    func enableJIT(bundleIdentifier: String, pairingFile: Data, playportScript: Bool, reply: @escaping (String?) -> Void)
    /// Runs on the XPC handler, independently of the blocking JIT queue, and ends only this helper process.
    func cancel()
}
