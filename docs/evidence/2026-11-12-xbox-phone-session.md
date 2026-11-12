# Xbox: the batched phone session

**Linear:** spec [PLA-485](https://linear.app/playportdev/issue/PLA-485). Tickets
[PLA-491](https://linear.app/playportdev/issue/PLA-491),
[PLA-492](https://linear.app/playportdev/issue/PLA-492),
[PLA-497](https://linear.app/playportdev/issue/PLA-497),
[PLA-499](https://linear.app/playportdev/issue/PLA-499),
[PLA-500](https://linear.app/playportdev/issue/PLA-500),
[PLA-502](https://linear.app/playportdev/issue/PLA-502),
[PLA-506](https://linear.app/playportdev/issue/PLA-506) and
[PLA-528](https://linear.app/playportdev/issue/PLA-528). Words as in
[GLOSSARY.md](../../GLOSSARY.md) and decisions [0181](../decisions/0181-the-xbox-store.md) and
[0182](../decisions/0182-xbox-guest-tickets.md).

**Setup.** The session ran on 2026-11-12 from branch `dev/pla-485-xbox-store` in the main
checkout, with the owner at the phone and the test account (PC Game Pass). Dev IPAs:
- `4b900be4630385380da2d3e6de799c1def066e36145f271974b7e4d1a80cb1a5` (head `075c04c5`), until
  the phone could be signed for again;
- `2a982096265a9736669efe798a29e0f9ed963691c7256cf84bbd2801a8171bfc` (head `650f6ae4`);
- `17ad7fed27937c84449527ccd201035972a1aaaf90842ad426107e18203d042e` (head `2c0e8e06`), with the
  ASCII install folder.

Run directories are under `.work/ui-runs/20261112T*`.

## Sign-in and the device (PLA-491)

- `xbox:status` logged "signed in" after app relaunches. The last sign-in was on 2026-11-02,
  so silent renewal had kept the session alive for ten days.
- `xbox:signout` logged "session secrets deleted, synthetic device kept". The sign-in after
  it (`xbox:signin`, `xbox:wait`) logged "signed in" and no "synthetic device registered", so
  the same device was reused.
- **Passkeys:** Microsoft tries a passkey first. Its face/fingerprint choices fail in the
  sideloaded web view and return to the same screen; the password works. An Authenticator
  approval means switching apps, which ends a `pp ui` run. The sheet's note now names the
  password, a code and Authenticator (`aaa10179`); the changed note was **not** shown on the
  phone (the owner declined another sign-in).

## Library (PLA-492)

- 457 copies: 15 owned, 442 PC Game Pass, and 344 licensed products left out. The pilot is
  listed, with Microsoft's art.
- With the pilot installed, All › Installed only shows the Steam and the Xbox Hollow Knight as
  two tiles.

## Install (PLA-497), downloads and add-ons (PLA-502)

| Copy | Download | Time | Files verified | Kept encrypted |
|---|---|---|---|---|
| Hollow Knight: Voidheart Edition `9MW9469V91LM` | 5,281,849,344 B | 109 s | 1,795/1,795 | 2 |
| Moonlighter 2 `9NDJX252Q5BW` | 5,646,360,576 B | 125 s | 1,730/1,730 | 2 |
| THPS 3+4 `9N1WK33QNSRJ` | 42,814,242,816 B | 1,058 s | 224/224 | 1 |
| THPS Content Pack `9NBL11JLNLMV` (add-on) | 10,612,736 B | 3 s | 9/9 | — |

- **The add-on:** THPS's play named 2 related products to the runtime and set the add-on's
  content root. The bridge served all 6 `STORE_LICENSE_TOKEN_REQUEST`, so a Game Pass add-on
  comes with its content key. Whether its items show in game was not checked (owner).
- **THPS 3+4 play:** first frame at +14.0 s. The menus ran at 12–15 FPS, and the owner saw
  single-digit frame rates and stalls of tens of seconds to minutes (PLA-834). The bridge's
  rate limit refused 2 of the game's 8 `STORE_PACKAGE_UPDATES_REQUEST`.

- The CDN is plain HTTP: `assets1`/`assets2`/`d1`/`d2.xboxlive.com` present Fastly's
  `fallback.tls.fastly.net` certificate on 443.
- **Update checks:** the pilot (1.5.12620.0) and DIRT 5 (1.2770.47.0) are the Store's current
  versions.
- **Remove keeping saves:** `uninstall:` removed the folder, the record and the stage. The
  pilot's save containers (SCID `…7abd14db`) stayed.
- **Remove deleting saves:** after a reinstall (150 s), the owner chose Remove › delete saves on
  the game page. The folder and the `…7abd14db` containers are gone; the cloud keeps them.
- **The ASCII folder:** THPS's first install was named after the Store title,
  `Tony Hawk's™ Pro Skater™ 3 + 4`, and its Play was refused: "only ASCII names are supported"
  (WineHost `title_path.c`). Since `2c0e8e06`, accents are folded and other non-ASCII
  characters dropped.

## Play (PLA-499) and more titles (PLA-506)

- **The pilot:** first frame at +10.26 s, 60 FPS. The bridge served one `MSA_TOKEN_REQUEST`.
- **Forced kill:** after `pp phone kill` at first frame +10, the copy's folder held both
  plaintext executables, with their `.playport-original` files beside them. The next app start
  logged "the plaintext the last process left is deleted and the originals are back". The
  folder then held only the encrypted originals (675,840 and 1,531,904 B).
- **Steam Hollow Knight smoke:** first frame at +10.42 s on IPA `2a982096…`.
- **DIRT 5 `9PJGM0T0827V`:** first frame at +12.7 s with the shaders cached. The owner drove a
  race, and the game exited with code 0 after 379 s.
  - **Frame rate:** 24 FPS in the garage, thermal state Serious.
  - **Bridge:** 4 requests served, none refused.
  - **Seen, not diagnosed:** a "lost connection to servers" notice after the race, which
    cleared by itself, and "Certain game modes and features are only available with the latest
    game updates".
- **Moonlighter 2 `9NDJX252Q5BW`:** first frame at +10.1 s. The owner started a new game and
  played, and the game exited with code 0 after 558 s.
  - **Frame rate:** 24 FPS in the canyon level at 400 s, thermal state Serious.
  - **Pauses:** gameplay stops for up to several seconds at a time (owner), even though the
    game compiles its shaders at start. Measurement: PLA-833.
  - **Bridge:** 2 `MSA_TOKEN_REQUEST` served. It refused 2 `STORE_LICENSE_TOKEN_REQUEST` for
    `9PMH7MP59NZK`, which is not a related product the game declares.

## Cloud saves (PLA-500)

The "Windows" side was unmodified Xodus Nexus 0.5.0 on the workstation, signed in to the same
account. Its game ran in a nested gamescope window: under niri's xwayland-satellite, Wine's X
connection broke about 1 s after the window opened, three times.

1. **Phone:** the owner played and saved slot 3. The container's `index` went to `dirty 0`,
   with the remote time equal to the local one (13:01:33Z).
2. **Nexus:** the start downloaded all five containers. Slot 3 showed the phone's progress
   (owner). At exit Nexus uploaded slot 3 again (13:17:32Z).
3. **Phone:** slot 3 showed the workstation's state (owner). After a bench rest the runtime
   uploaded during play (13:19:17Z), so a force-quit left nothing unsynced.

**Skipped by the owner:** the conflict card and a play with the cloud unreachable. Today's phone
can't be cut off from the internet while staying on the LAN.

## Security measurements (PLA-528)

- **Prefix:** after plays, `user.reg` and `system.reg` have no `pp secrets` match and no
  Xbox, Xodus, MSA or live.com entry. Wine's credential store holds only two EOS SDK items.
  There is no `Xodus Nexus/offline-identity`.
- **On-disk identifier:** `XodusGameSave` is keyed by the account's XUID, which is an account
  identifier stored on disk.
- **Device name:** Wine's `ComputerName` is `PLAYPORT`.
- **Not measured:** ticket lifetimes after sign-out, the runtime's own tokens, a sign-out
  during play, an unscrubbed log scan, the Keychain classes and a 30-minute bridge count. They
  stay as residual risks in PLA-527.

## Skipped by the owner

- **PLA-501** (updates): needs a title that ships an update after it is installed.
- **PLA-504** (offline device): needs the phone offline but still on the LAN.
- **PLA-505** (licence lapse): needs a real refusal from Microsoft.
- **PLA-500's conflict and unreachable-cloud checks** (above).
