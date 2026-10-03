// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Called only after Wine has identified fresh, committed, large anonymous RW
// guest data. This cannot reach JIT code, images or already committed pages.
@_cdecl("playport_guest_memory_backing")
func playportGuestMemoryBacking(_ address: UnsafeMutableRawPointer?, _ bytes: UInt) -> Int32 {
    autoreleasepool { SharedMemoryBroker.replaceGuest(address: address, bytes: UInt64(bytes)) }
}

// Local bookkeeping only, no XPC. Wine reports exactly the host-page-aligned
// intervals it unmaps/decommits or promotes back to ordinary backing.
@_cdecl("playport_guest_memory_released")
func playportGuestMemoryReleased(_ bytes: UInt) {
    SharedMemoryBroker.releaseGuest(bytes: UInt64(bytes))
}
