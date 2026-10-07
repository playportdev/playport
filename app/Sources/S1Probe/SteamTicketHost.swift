// SPDX-License-Identifier: GPL-3.0-or-later
// The host side of the game's Steam tickets (decision 0062): the provider
// behind the emulator's unix call table (WineHost steam_ticket.c), which
// passes each call to the play's SteamTicketBroker. The calls come on the
// game's threads; the broker answers without waiting on the network. Armed by
// the launch (LaunchCoordinator) with the broker LibraryModel.play prepared,
// or with none: then HELLO answers off and the emulator makes up its own.

import Foundation
import SteamClientKit
import WineHost

enum SteamTicketHost {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var broker: SteamTicketBroker?

    /// The runtime log's `steam:` lines: the play's tickets, by handle, type and size only.
    static let log = Logger { line in AppLog.append("steam: " + line) }

    nonisolated(unsafe) private static let provider: UnsafeMutablePointer<wine_host_steam_ticket_provider> = {
        let p = UnsafeMutablePointer<wine_host_steam_ticket_provider>.allocate(capacity: 1)
        p.initialize(to: wine_host_steam_ticket_provider(hello: hello, create: create, status: status, cancel: cancel))
        return p
    }()

    /// The play's broker, or nil for none; the provider is set once.
    static func arm(_ b: SteamTicketBroker?) {
        lock.withLock { broker = b }
        wine_host_set_steam_ticket_provider(provider)
    }

    private static var current: SteamTicketBroker? { lock.withLock { broker } }

    private static let ok = UInt32(PP_STEAM_OK)
    private static let notSupported = UInt32(PP_STEAM_NOT_SUPPORTED)

    private static let hello: @convention(c) () -> UInt32 = {
        let armed = SteamTicketHost.current?.isArmed == true
        SteamTicketHost.log.info("emulator", "emulator connected (protocol \(PP_STEAM_PROTOCOL), tickets \(armed ? "armed" : "off"))")
        return armed ? 1 : 0
    }

    private static let create: @convention(c) (UInt32, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt32>?,
                                                UnsafeMutablePointer<UInt8>?, UInt32, UnsafeMutablePointer<UInt32>?) -> UInt32 = {
        type, identity, handle, ticket, cap, size in
        guard let b = SteamTicketHost.current, let handle, let ticket, let size,
              let kind = SteamTicketBroker.TicketType(rawValue: type) else { return SteamTicketHost.notSupported }
        let id = identity.map { String(cString: $0) } ?? ""
        switch b.create(type: kind, identity: id) {
        case let .success(made):
            let bytes = made.ticket.value
            guard bytes.count <= Int(cap) else {
                b.cancel(made.handle)
                return UInt32(PP_STEAM_INVALID_PARAMETER)
            }
            bytes.withUnsafeBufferPointer { ticket.update(from: $0.baseAddress!, count: bytes.count) }
            size.pointee = UInt32(bytes.count)
            handle.pointee = made.handle
            return SteamTicketHost.ok
        case .failure(.rateLimited), .failure(.tooManyLive): return UInt32(PP_STEAM_QUOTA_EXCEEDED)
        case .failure(.noTokens): return UInt32(PP_STEAM_NO_MORE_ENTRIES)
        case .failure(.notArmed): return SteamTicketHost.notSupported
        }
    }

    private static let status: @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32 = {
        handle, state, eresult in
        guard let b = SteamTicketHost.current else { return SteamTicketHost.notSupported }
        guard let s = b.status(handle) else { return UInt32(PP_STEAM_INVALID_HANDLE) }
        state?.pointee = s.state.rawValue
        eresult?.pointee = s.eresult
        return SteamTicketHost.ok
    }

    private static let cancel: @convention(c) (UInt32) -> UInt32 = { handle in
        guard let b = SteamTicketHost.current else { return SteamTicketHost.notSupported }
        b.cancel(handle)
        return SteamTicketHost.ok
    }
}
