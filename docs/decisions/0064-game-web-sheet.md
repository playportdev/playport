# 0064: A game opens a web page: Playport's web panel over the play

**Status:** accepted, 2026-10-07, by the supervisor for the unattended session, on the
recommended options of the [store game sign-in plan](../plans/finished.md#games-sign-in-to-their-store)
(a panel over the game, not Safari; a non-persistent web session per panel; Epic's
pre-sign-in only for an Epic game's Epic sign-in page; the EOS refresh token a game keeps in
its prefix left as a documented residual; x86-64 games first). Amends
[0058](0058-store-sessions.md) and adds a case to [0004](0004-steam-session-boundary.md)'s
exceptions. The phone measurement is in the [evidence](../evidence/2026-10-07-url-opener.md).

## Context

Snakebird Complete's EOS signs in with AccountPortal: it asks Epic for a device code, calls
`ShellExecute` on `https://www.epicgames.com/activate?userCode=…`, and polls until the
player has signed in and allowed the game in a browser. Later plays sign in silently with
the refresh token EOS keeps in the prefix's Credential Manager. The prefix had no `http` or
`https` handler (the app does not apply `wine.inf`'s associations and does not ship
`winebrowser`, whose unix side could open nothing on iOS), so shell32 answered
`SE_ERR_NOASSOC` and EOS `UnexpectedError`. Any game that opens a page (a sign-in, a news
link, a support page) met the same silence.

## Decision

- A game's `ShellExecute` (or `start`, or Unity's `Application.OpenURL`) of an **http or
  https** URL opens **Playport's web panel over the running game**. Nothing opens Safari:
  Playport would go to the background mid-game, where its audio, Metal and JIT are not
  ready to be suspended.
- **The path:** the prefix registry seed names `C:\windows\system32\playport-url-opener.exe
  "%1"` for `http` and `https` (`app/tools/prefix-registry.py` `ASSOCIATIONS`, topped up into
  an existing prefix). The opener (`app/UrlOpener`, a freestanding x86-64 program staged
  beside the session root) hands the URL to the host through one unix call table,
  `playport_url_unix_call_funcs` (`url_opener.c`, `url_opener_protocol.h`, WineHost ABI 5),
  which the runtime gives its exact export name (madeira-unix 0092), and exits; it never
  waits for the page. One fixed-size block, no pointers, checked by magic, size, protocol,
  a NUL, the scheme and no space or control character.
- **The host's rules** (`UrlOpenerHost`, PlayportKit `UrlOpenRequest` and `UrlOpenRate`):
  only while a play is armed (from the launch to its end); http or https with a host, no
  user name or password, at most 2047 bytes; one page at a time, 5 s apart, at most 10 a
  play. The call answers at once; the page goes to the main actor.
- **The panel** (`UI/GameWebSheet.swift`): a `WKWebView` over the game, about nine tenths
  of the screen, its edge dimmed. The game keeps running, its input held (its pads rest,
  keys, touches and the mouse stop, its audio pauses: `HostIO.holdGuest`), its threads not
  paused, so it sees its sign-in finish while the panel is up. The bar shows the page's
  **host** only, Back, and Close (also the controller's B); the in-game menu does not open
  over it. Each panel has its own **non-persistent** website data store, which ends with it.
- **Epic's sign-in page on an Epic game's play** (`https://www.epicgames.com/activate` with
  a `userCode`, the form measured; widened only on evidence) opens at once, **signed in to
  Epic**: the host fetches a fresh exchange code (10 s, one retry) and loads
  `https://www.epicgames.com/id/exchange?exchangeCode=…&redirectUrl=<the page>`, so the
  player has only the game's consent (Allow) to give. Epic's pages get desktop Safari's user
  agent: with a phone's, Epic's consent page drops the session and asks for a password again
  (measured, [evidence](../evidence/2026-10-07-url-opener.md)). Top-level navigation then stays on
  https `epicgames.com` and its subdomains. Without a code (Epic signed out, offline) the
  page opens as it is, and Epic asks the player to sign in within the panel.
- **Any other page**, and Epic's page from another store's game, first shows a card ("<game>
  wants to open a web page", the host, Open or Not now) and opens with no sign-in.
- **A release build has no automatic approval.** A dev build's driver has `web:wait`,
  `web:click:<label>` and `web:close` (`Dev/WebSheetDriver.swift`, decision
  [0012](0012-ui-only-entry-point.md): it drives the panel as a person's taps would);
  `pp verify --variant release` fails an executable that names it.
- **x86-64 games only, for now.** An i386 game's `C:\windows\system32` is redirected to
  `syswow64`, where the opener is not staged, so its pages still go nowhere: a follow-up
  stages it there once a 32-bit title needs it.

## The secrets

- **The exchange code** is the host's, one-time, five minutes. It goes only into the
  panel's first request, never to the guest and never to a log.
- **Epic's web session** (its cookies) lives in WebKit's network process, in a
  non-persistent store that ends with the panel: not in the app process, not at rest in
  the container. The host's `eg1` tokens never enter the web view.
- **The device flow's `userCode`** is the game's own, valid about ten minutes. It stays
  out of the host's logs: the host logs host and path only, `Redactor` masks `userCode`,
  and the runtime's process lines mask a URL argument's query (madeira-unix 0093).

## Threat model

Everything runs in one process (0004).

- **The guest chooses the URL**, and native code in the guest can call the table without
  the opener. The host enforces the scheme, the length, the rate, one page at a time, and
  "only while a play is armed".
- **Consent to another client.** A hostile game can start an Epic device flow for any
  client (the launcher's broad one included) and have the signed-in panel show its consent
  page; if the player taps Allow, that client's session goes to the guest. For an **Epic
  game** this adds nothing to [0059](0059-epic-exchange-code.md)'s residual: the guest
  already holds an exchange code any client can redeem. For other stores' games it would
  be new, so Epic's pre-sign-in is offered only on an Epic game's play. Epic's page names
  the client, and only the player taps Allow.
- **Phishing.** The signed-in panel opens only Epic's activate page and stays on
  `epicgames.com`; the bar always shows the real host. An unsigned page can imitate a
  sign-in and ask for a password, as in any browser: the visible host, the confirm card and
  the absence of a pre-filled session are the mitigations.
- **Spam.** At most one panel, 5 s apart, 10 a play; Close always works.
- **What the game keeps (residual).** EOS stores its own refresh token in the prefix
  (`HKCU\Software\Wine\Credential Manager`, `eos-sdk:<product>:0`): the game's session,
  the class 0059 already accepts as Epic's to end. Epic sign-out on the host does **not**
  delete it; the player revokes it at Epic (account › apps and accounts). Whether sign-out
  should edit the prefix offline is left for a later record if wanted.

## Alternatives rejected

- `ASWebAuthenticationSession`, `SFSafariViewController`: neither takes an injected
  session (the player would type a password, with Safari's cookies), and neither can be
  driven; `ASWebAuthenticationSession` needs a callback scheme EOS's device flow has not.
- Safari: Playport goes to the background mid-play.
- Patching shell32 in process: a Wine patch touching every process, and a second unix
  table; the association is how Windows and Wine themselves reach a browser, and every
  caller that honours associations works unchanged.
- Shipping `winebrowser`: its unix side cannot open anything on iOS.

## Costs

One short x86-64 child process per page opened (its image gets no JIT-pool copy, madeira-unix
0090; it runs in the title's job and exits within milliseconds). The panel's WebKit
processes while it is up.
