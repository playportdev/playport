# 0057: A copy of a game is `(store, store game ID)`, end to end

**Status:** accepted, 2026-10-06 (owner, in the
[PC import, GOG and Epic plan](../plans/2026-10-06-pc-import-gog-epic.md), Phase 0).
Carries out the condition [0045](0045-library-store-copies.md) set before a second
store; 0045's library rules are unchanged.

## Decision

- **Stores** are `local`, `steam`, `gog` and `epic` (ContentKit `Store`). A game in one
  store is a `StoreGameKey`: the store and its ID for the game (Steam: the app ID;
  GOG: the product ID; Epic: the app name; local: the folder under `C:\Games`,
  lowercased).
- **Title IDs** stay as they are for what exists: `app-<steamID>` and `dir-<folder>`.
  New copies get store-qualified IDs: `gog-<productID>`, `epic-<appName>`. Launch
  settings, play time and cloud state are keyed by title ID, so nothing migrates.
- **The catalogue** carries `store` and `storeID` on every title; a catalogue from
  before says nothing and an app ID then means Steam. A title's source gains
  `imported` (a folder Playport copied in from Files).
- **A copy is identified by its receipt** (Steam's `installs/<appID>.json`; every other
  store's and every import's `installs/<store>-<id>.json`, a `StoreReceipt`) or by a
  cohort pin. Never by its name.
- **The sources are separate** (owner, 2026-10-06): Local, Steam, GOG and Epic. A store's
  copy is one Playport installed from that store. A game added from Files, or put in
  `C:\Games` any other way, is Local, even when its files came from a store: a
  `goggame-<id>.info` or `.egstore` record in the folder only says which executable and
  arguments start it, and `steam_appid.txt` is only a hint. A Local game never joins a
  store's listing.
- **Joins, downloads, art and navigation use the key.** The library joins an installed
  copy to its own store's listing only; the download queue holds one job per key (an
  old queue's jobs load as Steam's); a game page can be opened by key (`GameRef.store`);
  a download's Downloads item is `dl:job:<appID>` for Steam, as before, and
  `dl:job:<title ID>` otherwise.
- **Store chips** (0045) are Steam's always, then GOG and Epic Games once that store is
  signed in or has a copy in the catalogue.

## Costs

An app from before this record reads a catalogue with an `imported` title as
unreadable and rebuilds it by adoption (play history kept only for titles it can
place). Steam keeps its own receipt format and its app-ID-keyed staging, so a Steam
stage left on the phone still resumes; only new stores use the neutral forms.
