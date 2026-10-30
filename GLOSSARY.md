# Playport

Playport runs x86-64 Windows games on an iPhone. This glossary names where a game comes from and
what may stand between the player and Play.

## Game sources

**Store**:
Where a player gets games in Playport: Steam, GOG, Epic, and Battle.net with a fixed list of
supported products.
_Avoid_: source (an installed title's origin), platform, storefront

**Store region**:
The Battle.net region (us, eu, kr, tw) a Battle.net install belongs to; the game signs in to
that region.
_Avoid_: server, realm, locale

**Store client**:
Playport's own native client for a store's content network, which installs and updates a game on
the phone without that store's Windows program.
_Avoid_: downloader, store integration, native launcher

**Publisher launcher**:
A store's or publisher's own Windows program, run in the guest, that signs itself in and starts
its games.
_Avoid_: launcher (alone), store app, client

**Launcher-store game**:
A game sold only in a publisher launcher's own store, not on Steam, GOG or Epic.
_Avoid_: launcher game, Battle.net game

## Play gates

**Anti-cheat refusal**:
Playport declining to install or play a title because its anti-cheat cannot run, or is known to
reject Wine.
_Avoid_: blocked, unsupported

**Ban-risk notice**:
A warning shown before Play for a title whose anti-cheat Playport allows but the publisher does
not support on Playport.
_Avoid_: anti-cheat warning, disclaimer
