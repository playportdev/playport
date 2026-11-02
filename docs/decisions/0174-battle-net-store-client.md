# 0174: Battle.net games come from Playport's own store client, not the Battle.net app

**Status:** proposed, 2026-10-30, by the owner while planning World of Warcraft
([PLA-508](https://linear.app/playportdev/issue/PLA-508)). Accepted after the host spike
([PLA-509](https://linear.app/playportdev/issue/PLA-509)) installs WoW from Blizzard's CDN in a
layout the game accepts. When accepted, it amends the launcher plan's owner decisions D6 (the
guest launcher signs itself in) and D7 (launcher-store games are out of scope) for Battle.net
alone ([launchers plan](https://linear.app/playportdev/issue/PLA-616)); Rockstar, Ubisoft and EA keep them.

**Amended 2026-11-01 by [0177](0177-wow-plays-its-x64-client-through-fex.md):** a product is offered, installed and updated with its x64 client (`Wow.exe`, `WowClassic.exe`), not the ARM64 one; an older ARM64 install gains the x64 client through an update.

## Decision

- **A Battle.net store.** Playport gets a native Swift store client, `app/BattleNetClient`, beside
  Steam, GOG and Epic. It installs and updates games from Blizzard's TACT content network through
  ContentKit. The Battle.net app (`Battle.net.exe`, `Agent.exe`) is not run for these games.
- **A fixed product list:** World of Warcraft retail and its Classic products. A product is offered
  only while its current build carries an ARM64 client (decision 0170).
- **No Battle.net session in Playport.** Anyone may install a product; the game signs itself in
  (email, password, authenticator code, typed through the text bar), and its own login enforces
  the subscription. Playport stores no Battle.net secret.
- **Install and update:** a full install before Play, refused up front when space is short; an
  update check against the version endpoint at every Play, then the update, then the play.
- **Region and language:** the store region (us, eu, kr, tw) comes from a picker defaulting to the
  phone's region; one locale, from the phone's language with `enUS` as fallback.
- **Manners on Blizzard's CDN:** only the hosts the version and `cdns` endpoints name, a User-Agent
  naming Playport, bounded concurrency, back-off on HTTP 429, no mirrors. One exception, for the
  store's art only: the World of Warcraft site's public image host,
  `blz-contentstack-images.akamaized.net` (no session, no cookies, the same manners; PLA-607).

## Why

- World of Warcraft's client signs in by itself when started directly, and Battle.net is only its
  installer and updater (Blizzard forums, 2024–2026; Linux players run it this way).
- TACT's version, CDN and content endpoints need no sign-in, so a store client covers what the
  Battle.net app would do for WoW.
- Running the Battle.net app would need its own CEF build (decision 0110), possibly the i386 path,
  its update agent and services, and the write-copy work (PLA-270). That is Ubisoft-sized work
  before any game, for a launcher that keeps breaking under Proton (Proton #7302).
- Steam, GOG and Epic already work this way.

## Costs

- Playport owns a TACT client: manifests, encoding, encryption keys and layout changes Blizzard
  makes without notice.
- Blizzard may treat an unofficial client on its CDN as abuse (rate limits, blocks). Nothing in
  Playport works around that.
- Battle.net games that need the running Battle.net app (most non-WoW titles) stay out of reach.
