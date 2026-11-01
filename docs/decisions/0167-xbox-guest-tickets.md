# 0167: What an Xbox game receives from the host

**Status:** proposed, 2026-10-30, with the [Xbox spec PLA-485](https://linear.app/playportdev/issue/PLA-485)
([PLA-483](https://linear.app/playportdev/issue/PLA-483)); the owner chose this split in the
plan's grilling session. Like [0059](0059-epic-exchange-code.md) and
[0063](0063-gog-galaxy-sign-in.md), it carries the conditions of
[0004](0004-steam-session-boundary.md) over to another store, and it amends
[0058](0058-store-sessions.md)'s "nothing crosses into the guest" for Xbox. The measurements
named below are made in the plan's phases 0, 4 and 5; the residual needs the owner's
acceptance before this record is accepted.

## Decision

While an Xbox copy plays, the host answers its Xbox runtime (`xgameruntime.dll`, the
`xgameruntime` pin) through a **bridge**. The runtime then signs in to Xbox Live itself.

- **The listener.**
  - Bound to 127.0.0.1 on a free port from the play's start to its end.
  - A random 64-character key is made per play, and the runtime must send it before
    anything else.
  - The port and key reach the game in its environment (`XODUS_BRIDGE_PORT`,
    `XODUS_BRIDGE_KEY`). They are not secrets of the account.
- **The wire format** is Xodus's: an 8-byte header (magic, type, length) and an XML body,
  the reply's type the request's plus one, at most 64 KiB.
- **What it answers:**
  - **A Microsoft account user ticket and device ticket** for the client ID in the copy's
    own game config, or for Xbox's platform client ID when it has none.
  - **The Store licence token** for the playing copy's Product ID and the related products
    its game config declares.
  - **Package update queries** for that copy.
- **Refusals.** A request before sign-in, without the key, or for another product is
  refused, and a request it does not serve is refused too.

With those tickets the runtime gets its own Xbox tokens (device, SISU and per-service
XSTS, with a proof key it makes). It then talks to Xbox Live directly: profile, presence,
achievements and title storage for cloud saves.

## The secrets

- **What crosses.** The user and device tickets and the licence token, minted for this play.
- **What they allow.** A thief could act as the player toward Xbox Live, and toward any
  service that accepts tickets for that client ID, until the tickets lapse. **Assumed worst
  case** until measured: usable beyond the game, for the whole account's Xbox identity.
- **How long they last.** Not yet measured. Phase 4 records each ticket's stated and
  observed lifetime. Until then they are assumed to last as long as the session they came
  from.

## Threat model

Everything runs in one process (0004), so guest code can read the tickets while they are
in memory or on the socket: the game itself (which is meant to), and any mod or DLL it
loads.

- **Per play, keyed.** The listener exists only during an Xbox play. Another app on the
  phone would need the play's key, which only the game's environment holds.
- **Bound to the copy.**
  - The client ID comes from the installed copy's game config, read by the host from the
    copy's folder at launch.
  - Licence tokens are only for the playing Product ID and its declared related products.
  - A guest gets at most what Windows' runtime would give that game.
- **The host keeps everything else.** See "What never crosses".

## The one channel

The bridge's replies on the keyed loopback socket, and only those. Not the command line,
prefix files, the registry or the `wine_host` ABI; the environment carries only the port and
the key. The host does not write a ticket anywhere.

## What never crosses

- the account's refresh token and session secrets;
- the synthetic device's private key and proof secrets;
- content keys and licences (the host decrypts; the guest sees decrypted files only during
  the play, 0166);
- the offline lease.

## Guest-side storage

The runtime and the game may cache what they receive and the Xbox tokens they mint. Phase 5
searches the prefix and the container for each ticket and token after a play and lists what
it finds in the evidence.

## Logs

The bridge never logs payloads: a connection, each request's type and size, and each reply's
type and status. `Redactor` and `pp secrets` learn every Microsoft account, Xbox and licence
token form before the bridge lands; host tests show it.

## Sign-out and revocation (the residual)

- **What sign-out does.** It deletes the host's session, and a play that starts signed out
  gets no tickets.
- **What it cannot reach.**
  - A ticket already given to a running or finished game goes on working until Microsoft
    lets it lapse.
  - So do the Xbox tokens the runtime minted from it.
- **What remains possible.** The player can still end every session from the Microsoft
  account's security page; Playport's sign-out says so.

0004's fifth condition (revocation that also invalidates what the guest got) is therefore
not met by Playport alone. This is the residual the owner must accept with this record.

## Costs and risks

- The runtime keeps Xodus's protocol, so moving the `xgameruntime` pin can change what is
  asked for. This record is re-checked when the pin moves.
- Microsoft may tie tickets to the device or proof keys differently in future, ending Xbox
  sign-in in games, not play of games that do not need it.
