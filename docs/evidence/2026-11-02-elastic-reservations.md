# Elastic reservations: what the corpus, Mewgenics on a desktop and on the phone showed

**Linear:** [PLA-799](https://linear.app/playportdev/issue/PLA-799) (spec),
[PLA-800](https://linear.app/playportdev/issue/PLA-800),
[PLA-769](https://linear.app/playportdev/issue/PLA-769) (Mewgenics, 686060, GitHub #66),
[PLA-452](https://linear.app/playportdev/issue/PLA-452) (The Witcher 3 4.x). **Decision:**
[0180](../decisions/0180-elastic-reservations.md).

This record summarizes private research notes in the build area
(`$PLAYPORT_BUILD/agent-notes/mewgenics/`, `$PLAYPORT_BUILD/research/guestva/`). Screenshots stay
there; a game's artwork is not ours to publish.

## 1. The corpus: who hits a failed placement

`$PLAYPORT_BUILD/research/guestva/corpus.json` counts every reservation line (`[jumbo#]`,
`[bigres-use]`, `[short-reserve]`, `[alloc-fail]`, `[big-reserve]`) in 474 runtime logs under the
build area (phone runs and players' reports), grouped by the executable that made them: 46
executables, titles plus their launchers and helpers.

Three hit a failed placement (`STATUS_NO_MEMORY` on an unhinted reserve-only ask):

| Executable | Logs | Failed asks | Largest committed in one pool |
| --- | --- | --- | --- |
| `Mewgenics.exe` | 6 | 1,024 MB ×3 (three launches in the 0.5.0 report on GitHub #66, each its 34th pool), 21 MB (`0x14a0000`) ×1 (run `20261102T152055`, §3) | 6 MB |
| `witcher3.exe` (4.x) | 7 | 65,536 MB and 32,768 MB, once each, in one run with no short grants (`avx-2026-10-27-witcher3-avx`); the three runs with `short-reserve-mb=6144` (`pla452-2026-10-27/witcher-3-short*`) placed short grants and refused no commit | see [2026-10-27-witcher3-short-reserve.md](2026-10-27-witcher3-short-reserve.md) |
| `PlayRDR2.exe` and its processes | 42 | 5,119 MB `PAGE_NOACCESS` ×16, all from `SocialClubHelper.exe`, in two layout runs (12 in `20261030T184300-rdr2-p476l13`, 4 in `20261030T202901-rdr2-p476l16`); RDR2.exe's own asks never failed | 2,357 MB in RDR2.exe's 8,960 MB pool (`20261030T141431-rdr2-p476d1`) |

The other 43 never do, in 419 logs: `hollow_knight.exe` (157 logs, 2,628 Unity arenas of 511 MB,
none failed), `portal2.exe` (67), `Wow.exe` (23), `ShogunShowdown.exe` (19),
`GraveyardKeeper2.exe` (12), `Wow-ARM64.exe` (9), `Launcher.exe`, `castle.exe`, `Complete.exe`,
`Run.exe`, `BioshockHD.exe` (8 each), `TombRaider.exe` (7), `COTM.exe`, `Truth.exe`, `NSUNS4.exe`,
`IGTAPfullGame.exe`, `Valley.exe`, `KingdomTwoCrowns.exe` (6 each), `Paradox.exe`, `isaac-ng.exe`
(5 each), `AssassinsCreed_Game.exe`, `SteamworksExample.exe`, `Catherine.exe` (4 each), `hl.exe`
(3), `CatMailCo.exe`, `house_of_golf.exe`, `ASN_App_PcDx9_Final.exe`, `Muck.exe`, `mio.exe` (2
each), and one log each of `demons.exe`, `Spelunky.exe`, `tra.exe`, `DRIVERally.exe`,
`valheim.exe`, `KingdomCome.exe`, `Us.exe`, `MultiVersus.exe`, `Bioshock.exe`, `SuperMeatBoy.exe`,
`DeathsDoor.exe`, `EnGarde.exe`, `MonsterTrain.exe`, `Moonscars.exe`. Under decision 0180 nothing
changes for them: the rule engages only after a placement fails.

RDR2's 8,960 MB reservation: in the six off-layout runs (`20261020T211148-rdr2-n1`,
`20261020T211703-rdr2-n2`, `20261021T151236-rdr2-xs1`, `20261021T155940-rdr2-g1`,
`20261030T104204`, `20261030T141431-rdr2-p476d1`) it was placed at `0x7440000000` (or
`0x712cbe0000` in d1), not in the 8,960 MB hold below FEX's band; the hold sat unused. Under the
Social Club layout (every other RDR2 run listed) the layout places the game's slot itself and
ignores `jumbo-mb`.

## 2. Mewgenics on a desktop: how many pools, how deep

Mewgenics with the phone's files under Proton 10's Wine on this workstation (an owned Xvfb, a
scratch prefix, audio and browser blocked, Playport's `steamclient64.dll`), with a relay trace of
`VirtualAlloc`/`VirtualFree` and a `VirtualQueryEx` walker sampling the process every 250 ms
(`$PLAYPORT_BUILD/agent-notes/mewgenics/run.sh`, `parse.py`; runs under `runs/`).

- **The pool allocator.** Every pool reserves `0x40000000` (1 GiB) from one call site
  (`Mewgenics.exe+0x969582`) and commits from the bottom from another (`+0x9695d4`). The
  executable holds 2,246 pool descriptors of 1 GiB (`ana/pools.tsv`), one per object class.
- **Pool counts** (run `r6-play`, 306 s, driven into the story): 42 pools 2.6 s after start, 52 by
  the main menu (t+38 s), 71 five minutes in (t+299 s). Run `r4-input` (296 s, menu only) reached
  48.
- **Depth.** The deepest pool committed 6,892 KiB (`r4-input`) and 6,888 KiB (`r6-play`), about
  6.9 MB; most commit 4 to 56 KiB. At the end of `r6-play` the 71 pools held 72,704 MB reserved and
  7,628 KB committed.
- **None is freed.** Neither run makes a single `VirtualFree` call; the count only grows.
- **Other reserve-only asks:** one of 20 MiB and one of 96 MiB at start.

## 3. Mewgenics on the phone after 0179: run `20261102T152055`

Dev IPA `508e2815e771982fa40abc6d5fe298b378681c2b86d34cdd81ce5045378921ba` (head `4007b4e2`, decision
0179: no `jumbo-mb` in every game's keys), `pp ui --play app-686060 --until first-frame+60`
(`$PLAYPORT_BUILD/ui-runs/20261102T152055`).

- First frame at +5.89 s.
- 42 reservations of 1,024 MB succeed (`[jumbo#1]` … `[jumbo#42]`).
- Then a 21 MB reserve-only ask fails:
  `[alloc-fail] ml814 #1 status=c0000017 hint=0x0 size=0x14a0000 type=0x2000 protect=0x4 … | STAGE=fixed-map err=3`.
  `[va-scan]` lines before it show the window `[0x7400000000, 0x7800000000)` with no gap larger
  than `0xaa0000`.
- The game writes through the NULL (`c0000005`, a write to `0x0`) and ends with exit code
  `c0000005` after 23,152 ms.

Removing every game's hold moved the failure from the 34th pool (0.5.0) to after the 42nd; it did
not remove it.

## 4. PR #84: Mewgenics with lean reserves

PR #84 (De-Os, open, not merged; its `docs/evidence/2026-10-26-mewgenics.md`, iPhone Duo, iOS 27.1,
dev build) adds madeira-unix 0144: with `lean-reserve-mb = N` an unhinted reserve-only ask of
512 MB or more gets N MB plus a 32 MB inaccessible guard, a commit past N is refused and logged
(`[lean-reserve] OVERFLOW`). With `lean-reserve-mb=128` for `app-686060`:

- Mewgenics went past its menu into play with more than 64 pools (`[lean-reserve] #64` the last
  logged), no `OVERFLOW`, no fault, and quit with exit code 0.
- Before it, the 43rd 1 GiB reserve failed every launch, 13 to 18 s in; `arena-mb = 4096` moved the
  failure to the 54th.
- Hollow Knight on the same runtime: first frame at +7.89 s, no `[lean-reserve]` line.

Decision 0180 takes the elastic flag, the commit-path check, the guard and the overflow line from
it, not its per-title key or fixed size.

## 5. Capacity estimate

The guest can use roughly 47 GB. Under decision 0180 a lent Mewgenics pool keeps
`max(2 × committed, committed + 64 MiB)` plus a 32 MiB guard: about 96 MiB for a pool committing
under 32 MiB, so about 490 pools fit; with a 16 MiB keep floor (48 MiB per pool), about 980. Five
minutes of play created 71; the executable has 2,246 pool classes, so a session touching most of
them could still run out. The game ignores a refused commit, so that would remain a crash, logged as
a refusal.

## 6. Open measurements (closed by PLA-802)

- RDR2's commit depth into its 8,960 MB pool beyond the first minute (2,357 MB is the deepest in
  the corpus).
- Any phone log of The Witcher 3 1.32 on this runtime: its `jumbo-mb=32768 cage-hold=1` go only
  after a run without them reaches Kaer Morhen with its 32 GB ask placed whole, or short with at
  least 4 GB usable, and no refused commit.
- How a game reacts to `VirtualQuery` on a shortened view.

Social Club's 5,119 MB `PAGE_NOACCESS` asks (§1) are not left open: under the layout an ask its
router guards carries the layout exception whether the router grants, refuses or passes it, so
they fail as today; PLA-801's on-layout replay includes them and asserts no short grant.
