// SPDX-License-Identifier: GPL-3.0-or-later
// The driver's actions on a web page a running game opened (UI/GameWebSheet.swift,
// decision 0064), as a person's taps would do them (decision 0012):
//
//   web:wait          waits (3 min at most) for the panel; on its confirm card presses
//                     Open, as A does; then waits for its page to finish loading (for an
//                     Epic sign-in, past Epic's /id/exchange) and 2 s more
//   web:click:LABEL   clicks the first visible, enabled button or link (button, a,
//                     [role=button], input[type=submit|button]) whose text is LABEL (any
//                     case), as a tap on it does; waits up to 30 s for one to appear, and
//                     fails naming how many candidates the page had
//   web:close         Close, as the panel's button does
//
// Lines go to the log as `ui: web …`, with the page's host and path only. A release
// build has none of this (its executable must not name WebSheetDriver: verify-ipa).

import Foundation
import WebKit

@MainActor
enum WebSheetDriver {
    /// nil when the action did what it says, else why not.
    static func run(_ id: String, log: (String) -> Void) async -> String? {
        let sheet = GameWebSheet.shared
        if id == "wait" {
            let deadline = Date().addingTimeInterval(180)
            while !sheet.isUp, TitleLaunch.shared.running, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let s = sheet.shown else { return "no web page was opened" }
            if !s.confirmed {
                try? await Task.sleep(for: .milliseconds(1000))   // the card drawn, for a screenshot
                sheet.press(.a)
            }
            while sheet.isUp, Date() < deadline, !ready(sheet) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard sheet.isUp else { return "the page was closed while loading" }
            guard ready(sheet) else { return "the page did not finish loading" }
            try? await Task.sleep(for: .seconds(2))
            log("web: \(where_(sheet)) (\(sheet.signInNote ?? "not signed in"); \(await probe(sheet)))")
            return nil
        }
        if id == "close" {
            guard sheet.isUp else { return "no web page is up" }
            log("web: close on \(where_(sheet))")
            sheet.close("the driver")
            try? await Task.sleep(for: .milliseconds(500))
            return nil
        }
        guard id.hasPrefix("click:") else { return "not web:wait, web:click:<label> or web:close" }
        let label = String(id.dropFirst("click:".count))
        let deadline = Date().addingTimeInterval(30)
        var candidates = 0
        while Date() < deadline {
            guard sheet.isUp, let view = sheet.webView else { return "no web page is up" }
            let result = try? await view.callAsyncJavaScript(click, arguments: ["label": label.lowercased()],
                                                             in: nil, contentWorld: .defaultClient)
            let r = result as? [String: Any]
            candidates = (r?["candidates"] as? NSNumber)?.intValue ?? 0
            if (r?["clicked"] as? NSNumber)?.boolValue == true {
                log("web: clicked \"\(label)\" on \(where_(sheet))")
                try? await Task.sleep(for: .seconds(2))
                log("web: now \(where_(sheet))")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "no \"\(label)\" to click on \(where_(sheet)) (\(candidates) buttons and links; \(await probe(sheet)))"
    }

    /// Whether the page's site has a signed-in session: Epic's /id/api/account status
    /// (on an Epic page), the page's first heading and its cookie count. No value is logged.
    private static func probe(_ sheet: GameWebSheet) async -> String {
        guard let view = sheet.webView else { return "no page" }
        let js = """
            let account = 'n/a';
            if (location.hostname.endsWith('epicgames.com')) {
                try { account = String((await fetch('/id/api/account', { credentials: 'include' })).status); }
                catch (e) { account = 'error'; }
            }
            const h = document.querySelector('h1, h2');
            return 'account ' + account + ', heading "' + (h ? h.innerText.trim().slice(0, 60) : '') + '", '
                + document.cookie.split(';').filter(c => c.trim()).length + ' script cookies';
            """
        let r = try? await view.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        return (r as? String) ?? "probe failed"
    }

    private static func ready(_ sheet: GameWebSheet) -> Bool {
        guard sheet.finishedLoads > 0, !sheet.loading, let page = sheet.lastPage else { return false }
        return !page.path.hasPrefix("/id/exchange")
    }

    /// The page's host and path, never its query.
    private static func where_(_ sheet: GameWebSheet) -> String {
        guard let u = sheet.webView?.url ?? sheet.lastPage else { return sheet.host }
        return (u.host ?? "?") + u.path
    }

    private static let click = """
        const els = Array.from(document.querySelectorAll('button, a, [role=button], input[type=submit], input[type=button]'));
        const hit = els.find(e => {
            if (e.disabled || e.getAttribute('aria-disabled') === 'true') return false;
            const text = String(e.innerText || e.value || '').trim().toLowerCase();
            const box = e.getBoundingClientRect();
            return text === label && box.width > 0 && box.height > 0;
        });
        if (hit) hit.click();
        return { candidates: els.length, clicked: !!hit };
        """
}
