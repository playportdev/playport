# Playport

Playport runs x86-64 Windows games, obtained from PC game stores, on an iPhone. This glossary
names where a game comes from, what a player owns, installs and plays, and what may stand
between the player and Play.

## Game sources

**Store**:
Where a player gets games in Playport: Steam, GOG, Epic, Battle.net with a fixed list of
supported products, and Xbox.
_Avoid_: source (an installed title's origin), platform, storefront, launcher, provider

**Copy**:
One game as one store knows it, identified by the store and that store's game ID;
copies of the same game from two stores are two copies.
_Avoid_: install, edition, entry

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

**Xbox**:
The store for Microsoft's PC games, both bought ones and those in the Game Pass
subscription.
_Avoid_: Microsoft Store, Game Pass (as a store name), MS Store, Xbox app

**Product ID**:
Xbox's game ID for a copy: the Store's twelve-character product identifier
(such as `9NBLGGH4R315`), the same across the game's updates and packages.
_Avoid_: Store ID, BigId, package family name, content ID

## Xbox licensing

**Licence**:
Microsoft's time-limited permission for one account to play one Xbox copy, granted
by a purchase or by a Game Pass subscription. Once Microsoft definitively refuses
it, the copy is removed after a notice, but never before its saves reach the cloud.
_Avoid_: entitlement, ownership, subscription (for the permission itself)

**Content key**:
The key, delivered with a licence, that decrypts a copy's encrypted files.
_Avoid_: CIK, game key, decryption key

**Synthetic device**:
The Windows PC that Playport presents to Microsoft on behalf of one app
installation, with made-up hardware details and none of the phone's own.
_Avoid_: fake device, emulated PC, device ID

**Offline device**:
The one device an account designates for playing Xbox copies without a connection
while their licences remain valid.
_Avoid_: offline PC, home console

**Offline lease**:
Microsoft's grant, with a licence, that lets the offline device keep using the
copy's content key without a connection until the lease expires.
_Avoid_: offline licence, licence cache

## Saves

**Cloud save**:
The save data Microsoft keeps for one account and one Xbox copy, shared with that
account's other devices.
_Avoid_: connected storage, roaming save, title storage

**Unsynced save**:
Save data on the phone that has changed since the copy's last exchange with its
cloud save.
_Avoid_: local-only save, pending upload

**Save conflict**:
An unsynced save whose cloud save has also changed since their last exchange; the
player chooses which one to keep.
_Avoid_: sync error, merge

## Play gates

**Anti-cheat refusal**:
Playport declining to install or play a title because its anti-cheat cannot run, or is known to
reject Wine.
_Avoid_: blocked, unsupported

**Ban-risk notice**:
A warning shown before Play for a title whose anti-cheat Playport allows but the publisher does
not support on Playport.
_Avoid_: anti-cheat warning, disclaimer

## Guest address space

**Memory key**:
A setting that reserves, places, commits or sizes guest memory, carried by a compatibility entry, a
cohort entry, a launcher or every game's default rather than following from what the game does.
Decision 0183 allows none: what a game needs is decided by a property the runtime observes.
_Avoid_: per-title hold, address-space key

**Claim**:
The size a guest reservation was told it got. Under elastic reservations it can be larger than the
view behind it; a later commit inside the claim grows the view or is refused (decision 0180).
_Avoid_: reservation size, virtual size

**Live claim**:
The part of a claim beyond a shortened view's real part: room the guest was promised that is not
mapped for it, and that later pools are placed outside while room elsewhere allows.
_Avoid_: lent tail, phantom range

**Lend**:
Giving the untouched upper part of a large plain reservation (the lender) back to the host after
a placement fails. The view shrinks and its claim stays.
_Avoid_: reclaim, release, trim

**Lender**:
The reservation a lend shortens: unhinted, reserve-only, 256 MiB or more, not held, not committed
to its top; the one with the most lendable room.
_Avoid_: donor (the donor pool is the helpers' memory that backs guest commits), victim, source pool

**Short grant**:
A reservation of 1 GiB or more that cannot be placed whole, given a smaller real part with a guard
while the caller is told it got its full size.
_Avoid_: partial reservation, lean reserve

**Anchor**:
A range of the Social Club layout held from boot, in a Play that starts a verified Rockstar bootstrap:
an address the Social Club helper's 64 GiB window forces, sized from its measured committed peak with
a margin.
_Avoid_: fixed slot, hold

**On-demand slot**:
A range of the Social Club layout that nothing holds until the helper's first ask for it places it;
from then on it is held in place for the next helper.
_Avoid_: claim (the size a reservation was told it got), lazy slot

**Guard (elastic)**:
The 32 MiB of inaccessible view above a shortened view's or short grant's real part. A commit
there grows the view or is refused, so a pool that outgrows its room faults at its own end, never
in a neighbour.
_Avoid_: red zone, padding
