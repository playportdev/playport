// SPDX-License-Identifier: GPL-3.0-or-later
// The driver's GOG install postcondition, separate from UI types for host tests.
// Downloads removes a finished job before the library's asynchronous adoption
// finishes. A fresh install has no previous build; an update may keep the same
// build. Neither is a reason to skip adoption or wait for a version change.

enum DriverInstallCheck {
    static func gogReady(version: String?, requestedBuild: String?, scanning: Bool) -> Bool {
        guard !scanning, let version else { return false }
        return requestedBuild == nil || version == requestedBuild
    }
}
