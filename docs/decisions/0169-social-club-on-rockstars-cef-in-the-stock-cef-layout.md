# 0169: Social Club runs on Rockstar's own CEF, single-process in the stock-CEF layout, and the game's helper is not ended under it

**Status:** accepted, 2026-10-30, by the owner (PLA-476). Supersedes
[0110](0110-own-cef-build-for-a-clients-cef.md). Amends
[0150](0150-dev-single-process-social-club.md),
[0153](0153-rdr2s-settings-are-every-games-defaults.md),
[0133](0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md) and
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md), and with them how
[0138](0138-refuse-rdr2s-social-club-restarts-at-process-creation.md) and
[0155](0155-allow-rdr2s-social-club-restart-after-a-re-sign-in.md) act under the layout. The retention of
a launcher helper's slot view is [0166](0166-detach-a-parked-threads-wait-then-unpin-its-view.md)'s.
[Plan](https://linear.app/playportdev/issue/PLA-476) (chunks 4 and 5),
[evidence](../evidence/2026-10-29-sc-stock-cef-probe.md),
[l19](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md).

**Amended 2026-11-12 by [0183](0183-no-per-game-memory-keys.md):** the layout is no longer every Play of
Rockstar's launcher: `PublisherLauncher.rockstar`'s `env.PLAYPORT_SC_LAYOUT=1` goes
([PLA-840](https://linear.app/playportdev/issue/PLA-840)), and any other Play holds no Social Club
range. The layout shrinks to the anchors its window forces, the rest claimed at the helper's first
ask; ELF_META2 and the 8,960 MiB game hold go ([PLA-841](https://linear.app/playportdev/issue/PLA-841),
[PLA-842](https://linear.app/playportdev/issue/PLA-842)). The low hold at exec stays in every Play, and
0236's refusal runs before the elastic policy.

**Amended as built 2026-11-13 ([PLA-842](https://linear.app/playportdev/issue/PLA-842), madeira-unix 0299):**
the layout holds from boot only its anchors, about 1.6 GiB where it held 30.25 GiB: libcef's pool prefix
at `0x7000000000` (64 MiB, from exec; the host's low hold keeps 64 MiB, not 256), chrome_elf's at
`0x7800000000` (64 MiB), Oilpan at `0x7c00000000` (512 MiB; FEX's arena starts at its end,
`0x7c20000000`) and ELF_META at `0x7400000000` (1 GiB). An anchor's size is the highest committed end
any phone run measured in it, rounded up to a power of two, times four, at least 64 MiB
([census](../evidence/2026-11-13-sc-census-rdr2.md): 0x5000, 0x5000 and 0x6420000; ELF_META's 0xaa82000
from l5). H1 was not settled (every attributed ELF_META commit was libcef's, at stack word 4, never 0),
so ELF_META stays an anchor, the conservative reading; it becomes on demand if a census shows no libcef
commit there and chrome_elf's at word 0. libcef's metadata (1 GiB), V8's cage (8 GiB) and V8's code
range (1 GiB, kind 7) are on demand: nothing is held until the helper's first ask places one at its home
(`0x78c0000000`, `0x7a00000000`, `0x7700000000`) when free, else at the highest free base aligned as it
needs (256 MiB, 4 GiB, 4 GiB); from then on it is held in place like an anchor, so the next helper gets
the same range, and one whose range something else took is placed anew. The code range's retry over
0243's bases goes, since the router serves that ask first: one kind 7 does not serve (another helper's, live
or kept, or a helper's second) gets a plain view where kind 7's first placement would go, 4 GiB-aligned.
ELF_META2 and the 8,960 MiB game hold are deleted, and 0228 and 0243 leave the series (0228 keeps only
PLA-482's overflow log): the game's pools are the elastic policy's, as in any Play. The JIT pool's RW alias stays
where the host maps it before any guest runs, `0x7900000000`, ending at or below the cage's home; no ask
can move it, so it is not one of the layout's slots. The Decision's layout bullet below gives the old
geometry.

**Amended as built 2026-11-13 ([PLA-865](https://linear.app/playportdev/issue/PLA-865)):** under the layout
every `SocialClubHelper.exe` `--type=` child is refused at its start (`STATUS_ACCESS_DENIED`, madeira-unix
0298), verified or not, and whether or not single-process is on. The layout holds one CEF process's pools, so a
child's 32 GiB PartitionAlloc ask is refused and its chrome_elf traps. With Social Club 2.4.0.302, a build the
guard does not verify ([PLA-866](https://linear.app/playportdev/issue/PLA-866)), the multi-process browser
started its storage service 1,237 times in 90 s and the dead children's memory ended the Play
(`pla841-rdr2-census4`). The multi-process fallback below therefore runs no child under the layout.

**The trigger, as the owner decided on PLA-840 (2026-11-12) and as built:** the layout engages when what a
Play starts is a Rockstar bootstrap Playport verified by hash (`SocialClubBootstrap`, PlayportKit): a
game whose install folder holds one, which for RDR2's Steam copy is `PlayRDR2.exe` with depot 1899671's
`Redistributables/Rockstar-Games-Launcher.exe`, or the launcher's Open when the `Launcher.exe` it starts
in the launcher's install folder is verified. Not `SocialClubHelper.exe`, which this record first named
and 0183 repeated: it is in the shared prefix, missing until the launcher's first run, while the layout
must be decided before the runtime starts, since libcef's range at `0x7000000000` comes from the low
hold at exec. The app checks before the runtime starts and sets `PLAYPORT_SC_LAYOUT=1` from the check
alone, and the configuration check refuses an `env.PLAYPORT_SC_LAYOUT` key (`TitleConfig`); a dev
build's `=0` no longer turns it off. A copy
with an unverified bootstrap (a Steam update of `PlayRDR2.exe`, a launcher self-update) gets no layout
until its hashes join the table; a dev build logs them.

**What is built and what is open.** Built: the layout (madeira-unix 0224–0231), the low hold (PLA-480),
ELF_META2 (0228), the probe refusal (0236), the code-range placement (0243), the game-helper end's default
under the layout (`GameSocialClubEndPolicy`) and the plan's chunk 4 (2026-10-31): single-process on by default
in both builds (`d1aff807`, PLA-602), the layout carried by `PublisherLauncher.rockstar`'s runtime for every
Rockstar Play (`1424a0ac`; replaced by PLA-840's verified-bootstrap trigger, above), and Playport's CEF build
removed with `pp verify`'s `cef` check (merge `b5814a58`, PLA-603). A layout play needs no keys, and no IPA,
dev or release, carries a CEF payload. A dev build's `=0` key turns single-process off; since PLA-840 no key
turns the layout on or off. Which Plays run the layout is amended as built (the Decision's layout bullet).
Open: the phone gates, chunk 6
([PLA-605](https://linear.app/playportdev/issue/PLA-605)).

## Context

- **The 0.5.0 release IPA could not start RDR2.** Release builds lack Playport's CEF 143.0.14 payload
  (0110, PLA-372). Rockstar's `libcef.dll` asks for 32 GiB PartitionAlloc pools, which fell to the soft-pool
  grant, and the launcher exited `0xE0000008` (the plan's Why). Shipping 0110's build needs PLA-372's
  source and relink work, a 4–8 h rebuild for each Social Club CEF update, and a Chromium without security
  fixes. The owner dropped it on 2026-10-29: run Rockstar's own CEF, as willfaust/Madeira does.
- **The layout reaches Story.** On stock CEF, single-process, with the layout: l12 (IPA `f2a0c7b8…`,
  `.work/ui-runs/20261030T171553-rdr2-p476l12`) held the cabin to first-frame+600 at a 7,200 MB peak, l14
  (`…T185058-rdr2-p476l14`) at 7,058 MB, l17 (`…T204959-rdr2-p476l17`) and l18 (`…T210408-rdr2-p476l18`)
  on IPA `b1a239f2…` to first-frame+600 and `[xp]` +717.
- **Ending the game's helper (B) costs the game under the layout.** In l19 (IPA `5db127bd…`,
  `…T215326-rdr2-p476l19`) the end fired at the step, the game signed in again, 0155 found no headroom
  (7,585 MB) and kept the restart refused, and the game left a heavy scene (I: the cabin) for a black
  spinner. In d1 (`…T141431-rdr2-p476d1`) the end sent the game back to its title menu; in l13
  (`…T184300-rdr2-p476l13`) 0155's allowed restarts took the footprint to 7.6 GB and the app was killed.
  With the layout the footprint at the step is 5,600–5,900 MB (l12, l14), not d1's 6,470.
- **V8's code range can miss its aligned base.** l16 (`…T202901-rdr2-p476l16`): B's 1 GiB code range had
  hints whose offset within 16 GiB was 0. Wine's hinted retry tries only 16 GiB-aligned slots for those, all
  taken under the layout, and the kernel's pick (`0x72b0370000`) is not 4 GiB-aligned, so V8 released it,
  its padded 5 GiB ask found no gap, and B died in Chromium's out-of-memory exit, with
  `[0x7300000000, +1 GiB)` free in its largest hole `[0x72b0364000, 0x73b6ef4000)`. Across l1–l16, 9 of 9
  offset-0 asks got an unaligned pick (`.work/agent-notes/pla476/reports/helper-oom.md` §2).

## Decision

- **Rockstar's CEF, single-process, in the stock-CEF layout, in both builds, with no keys.** A verified
  `SocialClubHelper.exe` (0150's exact build, its 48 SHA-256 ranges) runs single-process with the page
  bridge, and its reservations go to the layout's slots. 0150's guard and its multi-process fallback on a
  mismatch stay. Playport's CEF build is removed (plan chunk 4: `patches/wine-unix` 0039, `cef_swap`, the
  payload, `patches/cef`, `patches/chromium`, the `cef`/`chromium` pins), and `pp verify` fails any IPA
  that carries a CEF payload. The `[chromium]` switches (0109, 0111, 0114) and the PLA-447 heuristic stay.
- **The layout** (madeira-unix 0224–0226, 0228, 0231; host tests `test_sc_layout.py`, `test_sc_vm.py`):
  real ranges held natively from boot, all-or-nothing, else the launch is refused:
  kind 1 ELF (real 4 GiB at `0x7800000000`), 2 CEF (256 MiB at `0x7000000000`), 3 ELF_META
  (6.25 GiB at `0x7400000000`), 4 CEF_META (1 GiB at `0x7590000000`), 5 OILPAN (1 GiB at `0x7c00000000`),
  6 CAGE (8 GiB at `0x7a00000000`), 7 ELF_META2, the 8,960 MiB game hold at `0x75d0000000`, FEX's arena
  from `0x7c40000000`, the JIT pool's RW alias at `0x7900000000`. Only the owner commits, protects or frees
  inside a slot's real range; a dead owner's slot is held in place (0231); reported extents overlap by
  design.
- **ELF_META2** (madeira-unix 0228): a 1 GiB second chrome_elf metadata slot, real
  `[0x79c0000000, 0x7a00000000)`, for a helper started while another PEB owns kind 3. Access is
  slot-aware: real-range containment wins, a straddle across real ranges is refused, a possible metadata
  overflow is logged (PLA-482).
- **The low hold** ([PLA-480](https://linear.app/playportdev/issue/PLA-480)): `wine_host.c` holds
  `[0x7000000000, +1.5 GiB)` from exec in every play, because iOS can put its own region there before the
  pool is acquired. A layout play keeps the bottom 256 MiB for kind 2 and moves the RW alias to
  `0x7900000000`; every other play maps the JIT RW alias fixed at `0x7000000000`, where Madeira put it.
- **Impossible probes are refused** (madeira-unix 0236). `ppsc_route` refuses an unhinted reserve from the
  verified helper with `STATUS_NO_MEMORY` before any map walk, at both entry points with the same guards,
  when it is larger than `PPSC_CEILING − PPSC_FLOOR`, or 8 GiB or more once the helper owns kind 6: V8's
  sandbox ladder and gin's pool tries, 26 `NO GAP FITS` walks per helper in l10–l12. The first two
  refusals per PEB are logged; the kind-6 owner-exit line counts them all. l15–l19 logged no V8
  `NO GAP FITS` from A, and l17–l19 none from B.
- **V8's code range takes a 4 GiB-aligned base** (madeira-unix 0243). In Wine's hinted ≥1 GiB retry, for
  the verified helper under the layout (`ppsc_ready && ppsc_helper()`) whose hint is 4 GiB-aligned, each
  4 GiB-aligned base `b` with `[b, b + size)` inside `[PPSC_FLOOR, PPSC_CEILING)` — `0x7100000000`,
  `0x7200000000`, `0x7300000000` — is tried before the kernel's pick (`[jumbo] cand sc-aligned`;
  `ppsc_code_range_next` in `pp_sc_layout.h`). It reserves nothing new. Every other process and every
  play without the layout keeps the retry as it was.
- **The game's own Social Club helper is not ended under the layout.** A Play under the layout does not
  send `PP_CONTROL_END_GAME_SOCIAL_CLUB` (`GameSocialClubEndPolicy`, PlayportKit;
  `GameSocialClubEnd.enabled(socialClubLayout:)`).
  - The layout is the Play's `env.PLAYPORT_SC_LAYOUT=1` key, else the app's environment; the runtime holds
    it for such a Play or refuses the launch. *Amended as built, 2026-10-31:* the layout is every Play of
    Rockstar's launcher, its Open and RDR2's, per the plan's §2 rule "Keep these out of it" (owner's plan,
    2026-10-29: the layout applies only to a Play whose launcher is `PublisherLauncher.rockstar`). That is
    every Play that can start a verified helper in the catalog today. This record first said "every Play
    with a verified helper". *Amended 2026-11-12 by 0183 (PLA-840):* a Play whose start is a verified
    Rockstar bootstrap, as the amendment note above says; no key.
  - `endGameSocialClubAfterSignIn` and `refuseGameSocialClubRestart` stay. Without the layout they are
    unchanged: on unless turned off, both builds (0153). Under the layout the end is off when never set; a
    dev build's stored switch (`pp ui --action set:endGameSocialClubAfterSignIn=true`) still turns it on,
    to measure it; a release build ignores the stored switch there.
  - 0138's refusal goes with the end, as before: a Play that never ends B sets no
    `PLAYPORT_REFUSE_GAME_SC_RESTART`, so the game may start a helper again if one dies. 0155's re-sign-in
    watch arms only at an end, so it never runs under the layout.
  - The app logs `launcher: the game's own Social Club is not ended under the Social Club layout
    (decision 0169)`.

## Costs and risks

- **B stays alive for the whole play** (B's stock CEF ≈130 MB above d1's in l10–l11; its libcef image
  anonymous 53–58 MiB with 0167's copy). l12 ended B inside the step (−265 MB) and still peaked at
  7,200 MB; without the end the cabin's margin under 8,192 MB is not yet measured (the phone gate below).
- **A dead B is restarted.** Without the refusal, a helper that dies (l15's A-style PartitionAlloc
  failure, l13's no-hole code range) is started again by the game; under the layout the next one gets the
  slots held in place. In l13 five restarts (under 0155's allow) took the footprint from 6.9 to 7.6 GB; a
  restart loop is not bounded by this record.
- **The code-range rule does not help Story-time restarts.** At Story the window's largest hole was
  515 MB (l13): no 1 GiB aligned base exists there. A layout slot for the code range (helper-oom.md §2
  options b/c) was not taken; it would hold 1 GiB for the whole play.
- **The candidates lie in kind 2's reported 32 GiB extent,** as the guard walk's always did; commits there
  are noted, not refused (PLA-482). l15's A death (H1: two allocators over kind 3's pages) is not explained
  by this record.
- **Release is unmeasured.** The owner installs the release IPA and plays (decision 0068) once chunk 4
  lands; 0.5.0 stays held until then (PLA-475).

## Phone gate

HK first-frame+10, then RDR2 on the layout's keys with the Social Club end left unset: no
`PP_CONTROL_END_GAME_SOCIAL_CLUB`, no `PLAYPORT_REFUSE_GAME_SC_RESTART`, the not-ended log line, Story to
the cabin held to first-frame+600, the peak under the limit, and every V8 code range on a 4 GiB-aligned
base (`cand guard` or `cand sc-aligned`).
