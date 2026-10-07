// SPDX-License-Identifier: GPL-3.0-or-later
// The host side of Playport's URL opener (decision 0064): the provider behind
// the opener's unix call table (WineHost url_opener.c). A game that opens an
// http or https page during a play reaches it through the prefix's handler,
// playport-url-opener.exe; the call comes on the opener's thread, is checked
// here (PlayportKit UrlOpenRequest, UrlOpenRate) and answered at once, and the
// page goes to the panel over the game on the main actor (UI/GameWebSheet.swift).
// Armed by the launch (LaunchCoordinator) for the
// play's title, and disarmed at its end: with none armed every call answers
// NOT_SUPPORTED. The log names the page's host and path, never its query.

import Foundation
import ContentKit
import PlayportKit
import WineHost

enum UrlOpenerHost {
    /// The play a page is opened for.
    struct Play: Sendable {
        /// The title's name, for the sheet's confirm card.
        var title: String
        /// The launched game is an Epic game: its Epic sign-in page may open signed in to Epic.
        var epicSignIn: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var play: Play?
    nonisolated(unsafe) private static var rate = UrlOpenRate()
    nonisolated(unsafe) private static var sheetUp = false

    /// The runtime log's `url:` lines.
    static let log = Logger { line in AppLog.append("url: " + line) }

    nonisolated(unsafe) private static let opener: UnsafeMutablePointer<wine_host_url_opener> = {
        let p = UnsafeMutablePointer<wine_host_url_opener>.allocate(capacity: 1)
        p.initialize(to: wine_host_url_opener(open: open))
        return p
    }()

    /// The play's title, or nil at its end; the provider is set once.
    static func arm(_ p: Play?) {
        lock.withLock {
            play = p
            rate = UrlOpenRate()
            sheetUp = false
        }
        wine_host_set_url_opener(opener)
    }

    /// The sheet that showed a page has closed: the next page may open.
    static func sheetClosed() {
        lock.withLock { sheetUp = false }
    }

    private static let open: @convention(c) (UnsafePointer<CChar>?) -> UInt32 = { raw in
        guard let raw else { return UInt32(PP_URL_INVALID_PARAMETER) }
        guard let request = UrlOpenRequest.classify(String(cString: raw)) else {
            UrlOpenerHost.log.info("open", "refused: not a page Playport opens")
            return UInt32(PP_URL_INVALID_PARAMETER)
        }
        let taken: (Play?, UrlOpenRate.Refusal?) = UrlOpenerHost.lock.withLock {
            guard let p = UrlOpenerHost.play else { return (nil, nil) }
            let refusal = UrlOpenerHost.rate.take(at: Date(), sheetUp: UrlOpenerHost.sheetUp)
            if refusal == nil { UrlOpenerHost.sheetUp = true }
            return (p, refusal)
        }
        guard let p = taken.0 else {
            UrlOpenerHost.log.info("open", "\(request.logLabel) refused: no play armed")
            return UInt32(PP_URL_NOT_SUPPORTED)
        }
        if let refusal = taken.1 {
            UrlOpenerHost.log.info("open", "\(request.logLabel) refused: \(refusal.rawValue)")
            return UInt32(PP_URL_QUOTA_EXCEEDED)
        }
        UrlOpenerHost.log.info("open", "open \(request.logLabel) (\(request.kind.rawValue)) for \(p.title)")
        UrlOpenerHost.present(request, p)
        return UInt32(PP_URL_OK)
    }

    /// The page goes to the panel over the game (UI/GameWebSheet.swift), on the main actor;
    /// the opener's thread does not wait for it.
    private static func present(_ request: UrlOpenRequest, _ p: Play) {
        DispatchQueue.main.async { MainActor.assumeIsolated { GameWebSheet.shared.present(request, p) } }
    }
}
