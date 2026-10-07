# 0058: GOG and Epic Games sessions stay on the host

**Status:** accepted, 2026-10-06 (owner, in the
[PC import, GOG and Epic plan](../plans/2026-10-06-pc-import-gog-epic.md), 0.4).
Applies [0004](0004-steam-session-boundary.md) to the two new stores.

## Decision

- **Sign-in** is each store's web login in an in-app `WKWebView` sheet, with the
  store's public desktop-client OAuth identity, the only route a third-party client
  has. The sheet is touch, the exception 0034 already makes for system pickers;
  everything after it is on the controller.
- **Tokens** (refresh and access) are `Secret<T>` values, held only in the Keychain:
  `ThisDeviceOnly`, not synchronisable, one service name per store
  (`dev.playport.app.gog`, `dev.playport.app.epic`), apart from Steam's.
- **Nothing crosses into the guest**: no token, no code, no session file. A game that
  needs one (Epic's exchange code on the command line) is refused with a message until
  a separate decision (0059, proposed only when a wanted game needs it) says otherwise.
  **Amended by [0059](0059-epic-exchange-code.md)** (2026-10-07): an Epic game gets a
  five-minute exchange code and, when its catalogue asks, an ownership token at
  launch; the session's tokens still never cross.
  **Amended by [0064](0064-game-web-sheet.md)** (2026-10-07): a web session is no longer
  only the store's own login. A page an Epic game opens during its play (Epic's sign-in
  page) is signed in to Epic in Playport's panel with a fresh exchange code, in a
  non-persistent web session that ends with the panel; nothing of it crosses into the guest.
- **Logs**: `Redactor` scrubs Epic's `eg1~` tokens, every `access_token`/`refresh_token`,
  and the login and exchange codes (`authorizationCode`, `exchangeCode`, a `code=`
  query or JSON field), with tests, before any network code ships.
- **Sign-out** deletes the Keychain item. Epic's session is also killed at Epic; GOG
  has no revoke endpoint, so its item is deleted and the sign-out says the token
  expires by itself.

## Costs and risks

The stores tolerate third-party use of their desktop-client identities today and
could block it; a block ends sign-in for that store, not imports or Steam. The owner
accepted this risk (2026-10-06). A store's web login may change its redirect, which
the sheet watches for; the change is a code update, not a new decision.
