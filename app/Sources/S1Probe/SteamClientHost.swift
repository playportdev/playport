// SPDX-License-Identifier: GPL-3.0-or-later
// The host side of Playport's steamclient64.dll (decision 0115): the provider
// behind its unix call table (WineHost steam_client.c). HELLO answers the
// play's snapshot (the SteamID, the persona name, logged on, ownership of the
// launched app, the language); CALL passes auth session and web API tickets to
// the play's SteamTicketBroker (decision 0062) and hands out the encrypted app
// ticket fetched at Play (decision 0017); POLL reads a ticket's state. The calls
// come on the guest's threads and answer from a lock, never waiting on the
// network. Armed by the launch (LaunchCoordinator) for a play in client mode,
// or with nil: then HELLO answers off and the shim answers as Steam's client
// does when not logged on. Nothing crosses for another app.

import Foundation
import SteamClientKit
import WineHost

enum SteamClientHost {
    /// What the launched app's client answers with, for this play only.
    struct Play {
        var appID: UInt32
        var steamID: UInt64?
        var personaName: String?
        /// A Steam API language code.
        var language: String
        /// The play's ticket broker: the CM session stays logged on for it (LibraryModel.play);
        /// nil when the session is not up, and then the client says it is not logged on.
        var tickets: SteamTicketBroker?
        var appTicket: Secret<[UInt8]>?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var play: Play?

    /// The runtime log's `steamclient:` lines: the shim's own, and what the host answered
    /// (handles, types and sizes only; no SteamID, persona or ticket bytes).
    private static func log(_ line: String) { AppLog.append("steamclient: " + line) }

    nonisolated(unsafe) private static let provider: UnsafeMutablePointer<wine_host_steamclient_provider> = {
        let p = UnsafeMutablePointer<wine_host_steamclient_provider>.allocate(capacity: 1)
        p.initialize(to: wine_host_steamclient_provider(hello: hello, call: call, poll: poll, log: guestLog))
        return p
    }()

    /// The play's client, or nil for none; the provider is set once.
    static func arm(_ p: Play?) {
        lock.withLock { play = p }
        wine_host_set_steamclient_provider(provider)
    }

    private static var current: Play? { lock.withLock { play } }

    /// ActiveProcess's ActiveUser for the armed play: the SteamID's account ID (its low half), 0 for none.
    static var accountID: UInt32 { lock.withLock { UInt32(truncatingIfNeeded: play?.steamID ?? 0) } }

    private static let ok = UInt32(PP_SC_OK)
    private static let notSupported = UInt32(PP_SC_NOT_SUPPORTED)

    /// Copies a string's UTF-8 into a fixed C field, cut to leave its NUL.
    private static func copy<T>(_ s: String, into field: inout T) {
        withUnsafeMutableBytes(of: &field) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            let bytes = Array(s.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
        }
    }

    private static let hello: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { raw in
        guard let raw else { return 0 }
        let h = raw.assumingMemoryBound(to: pp_sc_hello.self)
        guard let p = SteamClientHost.current else {
            SteamClientHost.log("client connected (protocol \(PP_SC_PROTOCOL)); no play armed: not logged on")
            return 0
        }
        let loggedOn = p.tickets?.isArmed == true
        h.pointee.steam_id = p.steamID ?? 0
        h.pointee.app_id = p.appID
        h.pointee.logged_on = loggedOn ? 1 : 0
        h.pointee.owns_app = 1   // a Play from the Steam library is of an app the account owns
        h.pointee.tickets = loggedOn ? 1 : 0
        #if !PLAYPORT_RELEASE
        // A dev app has the shim trace every call (steamclient_trace.h: no secrets, bounded); a release app never does.
        h.pointee.trace = 1
        #endif
        SteamClientHost.copy(p.personaName ?? "", into: &h.pointee.persona)
        SteamClientHost.copy(p.language, into: &h.pointee.language)
        SteamClientHost.log("client connected (protocol \(PP_SC_PROTOCOL)) for app \(p.appID): "
                            + "steamid \(p.steamID == nil ? "none" : "set"), persona \(p.personaName == nil ? "none" : "set"), "
                            + "\(loggedOn ? "logged on, tickets armed" : "not logged on"), language \(p.language), "
                            + "encrypted app ticket \(p.appTicket == nil ? "none" : "held")")
        return 1
    }

    private static let call: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { raw in
        guard let raw, let p = SteamClientHost.current else { return SteamClientHost.notSupported }
        let c = raw.assumingMemoryBound(to: pp_sc_call.self)
        let cap = MemoryLayout.size(ofValue: c.pointee.data)
        func put(_ bytes: [UInt8]) -> Bool {
            guard bytes.count <= cap else { return false }
            withUnsafeMutableBytes(of: &c.pointee.data) { $0.copyBytes(from: bytes) }
            c.pointee.data_size = UInt32(bytes.count)
            return true
        }
        switch c.pointee.method {
        case UInt32(PP_SC_TICKET_SESSION.rawValue), UInt32(PP_SC_TICKET_WEB_API.rawValue):
            guard let b = p.tickets else { return SteamClientHost.notSupported }
            let web = c.pointee.method == UInt32(PP_SC_TICKET_WEB_API.rawValue)
            let identity = withUnsafeBytes(of: &c.pointee.identity) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            switch b.create(type: web ? .webAPI : .authSession, identity: identity) {
            case let .success(made):
                guard put(made.ticket.value) else {
                    b.cancel(made.handle)
                    return UInt32(PP_SC_INVALID_PARAMETER)
                }
                c.pointee.handle = made.handle
                SteamClientHost.log("\(web ? "web API" : "auth session") ticket \(made.handle): \(made.ticket.value.count) bytes")
                return SteamClientHost.ok
            case .failure(.rateLimited), .failure(.tooManyLive): return UInt32(PP_SC_QUOTA_EXCEEDED)
            case .failure(.noTokens): return UInt32(PP_SC_NO_MORE_ENTRIES)
            case .failure(.notArmed): return SteamClientHost.notSupported
            }
        case UInt32(PP_SC_TICKET_CANCEL.rawValue):
            guard let b = p.tickets else { return SteamClientHost.notSupported }
            b.cancel(c.pointee.handle)
            return SteamClientHost.ok
        case UInt32(PP_SC_APP_TICKET.rawValue):
            guard let t = p.appTicket else { return UInt32(PP_SC_NO_MORE_ENTRIES) }
            return put(t.value) ? SteamClientHost.ok : UInt32(PP_SC_NO_MORE_ENTRIES)
        default:
            return UInt32(PP_SC_INVALID_PARAMETER)
        }
    }

    private static let poll: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { raw in
        guard let raw, let b = SteamClientHost.current?.tickets else { return SteamClientHost.notSupported }
        let s = raw.assumingMemoryBound(to: pp_sc_poll.self)
        guard let st = b.status(s.pointee.handle) else { return UInt32(PP_SC_INVALID_HANDLE) }
        s.pointee.state = st.state.rawValue
        s.pointee.eresult = st.eresult
        return SteamClientHost.ok
    }

    private static let guestLog: @convention(c) (UnsafePointer<CChar>?) -> Void = { text in
        guard let text else { return }
        let line = String(cString: text)
        GameSocialClubEnd.noteSteamTrace(line)   // decision 0155's fallback detector
        SteamClientHost.log(line)
    }
}
