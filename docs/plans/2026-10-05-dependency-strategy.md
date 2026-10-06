# Plan draft: how Playport carries its dependencies

**Date:** 2026-10-05. **Kind:** research and proposal, then the order below.
**Status (2026-10-06):** order rows 1–3 done; rows 4 and 5 superseded by
[decision 0054](../decisions/0054-madeira-frozen.md): the `madeira` pin is frozen at
`8c050d0` and Playport owns that layer. The `bbbf8d0` move (row 5) was done on branch
`madeira-main`, which stays unmerged as a reference. What waits for the owner is under
[Pending the owner](#pending-the-owner). Raw trial scripts and outputs were left in the build area (`$PLAYPORT_BUILD/agent-notes/dep-strategy/`), not committed.
**Pins read:** `pins.lock` at HEAD (`madeira` 8c050d0, `wine` wine-11.18 7b3fff7,
`wine-valve` dc26e61, `fex` FEX-2609.1 9fbdc00, `dxmt` 7c8dee1, `mesa` 82d4f86,
`dxvk` 52fe923, `vkd3d-proton` 472989a, `gbe` 7103add).
**Upstream heads used for the trials:** only what was already fetched on this
machine. Madeira `origin/main` 69b2fc0 (2026-10-01; the alignment plan's
`bbbf8d0`, 438 commits ahead, was not fetched). FEX `main` 0df84d38 (09-28),
DXMT `main` fb45156, WineHQ `master` 6d1b094 (09-28). Madeira's three fork
repositories were fetched into scratch with `--filter=tree:0` to count commits.
Scripts and raw outputs are in `$PLAYPORT_BUILD/agent-notes/dep-strategy/`
(`inventory.py`, `pick.sh`, `overlap.py`, `*-pick.tsv`, `perpatch.json`).

Every claim below comes from a measured number or a cited file. Inferences
are marked **(inference)**.

---

## Order across the plans (owner, 2026-10-05)

One sequence for this plan and
[the Proton alignment](2026-10-05-proton-arm64-alignment.md):

| Order | What | From |
|---|---|---|
| 1 | Sync tooling for Madeira's reorganisation: `research/dxmt` → `dxmt` in `tools/sync.py` and `build/pipeline`, and what `madeira-dock` means for `sources`. **Done, a8c0859e**: `madeira-dock` is not used and never checked out | strategy, step 0 |
| 2 | The rebase helper (rerere, conflict trial, `range-diff`, re-export), proven on the FEX → `main` move. **Done, 0dd5f68**: `pp rebase`; FEX trial onto `main` 3648ee9: 6 conflicts in 83 patches (72 clean, 5 3-way), resolved and compiled, draft in the build area (`agent-notes/dep-strategy/fex-main/`) | strategy, step 1 |
| 3 | Wine, FEX, DXMT, Mesa, DXVK, vkd3d-proton and the rest to latest, one per commit. **Rows 2–7 and 2b done** (decision 0049, e71e8a7..b011dbf, one commit and IPA each): every IPA passes the gate on both titles; the final build does less CPU work a frame than the baseline, and Portal 2's ≥25 ms load-segment hitch count (52 → 134 in the first pair) is run-to-run spread, the baseline alone spanning 52–268 over three runs ([deps-latest](../evidence/2026-10-05-deps-latest.md)). **Rows 8–10 done** (1e86afc, 2370713, 7ce2b51 after the rebase): freetype VER-2-14-3, rust 1.99.0 and stikjit 1.9.0 moved, one commit and IPA each; gbe, abseil-cpp, idevice, llvm-project, xtool (needs a machine-wide Darwin SDK reinstall) and gstreamer (a new release needs a new licensing audit) held, each with its reason. Every `pins.lock` row except `madeira` (order 5) is now moved or held. **DONE (2026-10-05):** the branch was rebased onto `main` 0.3.2 (which had taken the StikJIT 1.9.0 move itself), and one gate on the rebased final IPA `35956f63`, which contains all three moves, passed on both titles (JIT 2.31 / 2.50 s, first frame +9.53 / +7.48 s); xtool and GStreamer held by the owner | alignment, step 1 (rows 2–10) |
| 4 | Madeira reconciliation: per overlapping area (i386/WoW64, in-process sync, winegstreamer, D3D9, DXMT slots 145–149), whose design Playport runs. **Superseded by [0054](../decisions/0054-madeira-frozen.md) (Madeira frozen); `madeira-main` kept as a reference branch.** Before that, **done (2026-10-05): [decision 0052](../decisions/0052-madeira-reconciliation.md)** (0051 is taken on `main`), with the owner's answers: Madeira's WoW64, fastsync on by default, GStreamer and DXVK d3d9 kept, slots appended at 150–155. The carrying model is [0053](../decisions/0053-carrying-model.md) | strategy, step 2 |
| 5 | Madeira to `main`, re-porting its fork deltas once, onto the new bases. **Superseded by [0054](../decisions/0054-madeira-frozen.md) (Madeira frozen); `madeira-main` kept as a reference branch.** The move ran on `madeira-main` (2026-10-06, [Row 5 plan](#row-5-plan-madeira-to-bbbf8d0)): it reached Portal 2 parity but brought four issues the other moves did not (0054). Fastsync, its one measured win, is ported onto `8c050d0` as Playport patches and on by default ([evidence](../evidence/2026-10-06-fastsync-on-8c050d0.md)); `pp sync` is now a watch report | alignment, step 1 (row 11) |
| 6 | The alignment items (A, B) and the Portal 2 performance follow-ups. Both halves ran on `madeira-main`'s base (its evidence records); which results carry over to the frozen base is open | alignment, step 2 |

Steps 1–2 come first because the helper pays off on the moves of step 3; step 4
needs Madeira `main` as it is when Madeira is next. Nothing is offered upstream
(owner, 2026-10-05): every patch stays carried.

## Pending the owner

As of 2026-10-06, with Madeira frozen (0054):

1. **No public mirror of the frozen commits** (owner asked for one, 2026-10-06; not
   made, see 0054): Madeira `8c050d0`'s own tree carries Apple's non-redistributable
   `libmetalirconverter.dylib`, and every release's source bundle (0042) already holds
   the frozen sources without it. A filtered mirror needs a new decision record.
2. ~~A release-variant play.~~ Done 2026-10-06: the owner played both titles on the
   release app (`96ecadd9`), which passed; it showed the false *Not synced* fixed in
   3bfe88c. Was: The UI driver cannot drive the release app (0009), so a
   person plays both titles on `Playport.app` (B5's release log defaults, ported from
   `madeira-main` as 2331995, are in it).
3. **From `madeira-main`'s alignment work, if wanted on this base:** the human Portal 2
   runs (a 300 s play with a death and reload, a 30-minute play, a fresh-install play;
   A1 `MaxInst=500` is taken without a sweep, decision 0055),
   B1 (The Witcher 3's warm-cache crash: found and fixed, `patches/fex` 0021,
   [evidence](../evidence/2026-10-06-fex-disk-cache.md); on by default, decision 0056), and the
   B4 and B6 decisions. Their evidence is on that branch.

## Part A. Measurements

### A1. Patch series inventory (`patches/<target>/series`)

Lines are `+`/`-` lines inside the diffs of the listed patches. Files are the
distinct paths the series touches. Every series file is listed in its
`series`: there are no orphan patches.

| Series | Patches | +lines | −lines | Files | Class breakdown | Rebased/Picked trailers |
|---|---:|---:|---:|---:|---|---|
| `wine-valve` | 127 | 2,792 | 349 | 131 | valve 127 | Picked: clean 114, resolved 13 |
| `madeira-unix` | 79 | 10,337 | 3,760 | 47 | feature 26, upstream-bug 25, diagnostics 9, host-app 8, madeira-port 7, ios-port 2, build-fix 2 | – |
| `fex-port` | 63 | 10,733 | 853 | 74 | madeira-port 63 | clean 36, resolved 26 (+1 adaptation) |
| `wine-port` | 57 | 13,034 | 422 | 68 | madeira-port 57 | clean 49, resolved 7 (+1 follow-up) |
| `dxmt-port` | 45 | 9,334 | 865 | 71 | madeira-port 45 | clean 32, resolved 12 (+1 regeneration) |
| `wine-pe` | 27 | 1,459 | 235 | 28 | feature 10, upstream-bug 7, diagnostics 4, build-fix 2, linux-build 2, host-app 2 | – |
| `fex` | 20 | 865 | 190 | 29 | upstream-bug 6, feature 4, diagnostics 3, build-fix 3, linux-build 2, host-app 1, ios-port 1 | – |
| `mesa` | 16 | 4,633 | 302 | 31 | ios-port 13, feature 3 | – |
| `rpmalloc-port` | 16 | 1,992 | 57 | 5 | madeira-port 16 | clean 13, resolved 3 |
| `wine-unix` | 14 | 464 | 60 | 19 | upstream-bug 5, feature 5, diagnostics 2, build-fix 1, host-app 1 | – |
| `dxmt` | 9 | 765 | 56 | 22 | upstream-bug 3, linux-build 2, diagnostics 2, host-app 2 | – |
| `gbe` | 5 | 791 | 180 | 116 | upstream-bug 3, linux-build 2 | – |
| `vkd3d-proton` | 4 | 104 | 11 | 2 | feature 3, diagnostics 1 | – |
| `madeira-winios` | 3 | 146 | 22 | 1 | host-app 3 | – |
| `rpmalloc` | 3 | 73 | 2 | 1 | feature 1, upstream-bug 1, diagnostics 1 | – |
| `idevice` | 1 | 95 | 4 | 3 | host-app 1 | – |
| **Total** | **489** | **57,617** | **7,368** | | | |

Totals by origin:

| Origin | Patches | +lines | −lines |
|---|---:|---:|---:|
| Madeira's code rebased by Playport (`madeira-port`, 4 port series plus 7 in `madeira-unix`) | 188 | 38,512 | 5,070 |
| Valve's commits (`valve`) | 127 | 2,792 | 349 |
| Playport's own (every other class) | 174 | 16,313 | 1,949 |

**Offered upstream.** All 489 say `Offered-upstream: no`, some with a reason
(for example 28 say "the window exists only on the iOS port"). ARCHITECTURE.md
says the same: "No patch has been offered upstream yet." The `idevice` patch
says "to be offered to jkcoxson/idevice". LICENSING.md "Other projects" notes
that FEX-Emu does not accept AI-generated contributions.

**Age (from each patch's `Date:` header).** The repository history was
squashed on 2026-10-01 (decision 0043), so `git log --follow` cannot date
anything earlier. `git log` since 10-01 shows 32 commits touching `patches/`.
- The Madeira port series carry Madeira's author dates: `fex-port` 2026-03-07
  to 09-24, `wine-port` 04-28 to 09-26, `dxmt-port` 04-24 to 09-25,
  `rpmalloc-port` 04-29 to 09-24.
- `wine-valve` carries Valve's dates (2018-03 to 2026-06).
- Every Playport patch is from 2026-09-24 to 10-05, so 174 patches in 12 days.

| Day | New Playport patches | Running total | Where |
|---|---:|---:|---|
| 09-24 | 31 | 31 | madeira-unix 14, wine-pe 6, dxmt 3, wine-unix 3, madeira-winios 3, fex 2 |
| 09-25 | 8 | 39 | madeira-unix 5, dxmt 3 |
| 09-26 | 24 | 63 | mesa 12, madeira-unix 4, fex 3, dxmt 2, wine-unix 2, wine-pe 1 |
| 09-27 | 8 | 71 | |
| 09-28 | 17 | 88 | madeira-unix 9, fex 4, rpmalloc 2 |
| 09-29 | 6 | 94 | |
| 09-30 | 12 | 106 | vkd3d-proton 4, madeira-unix 3, wine-pe 2 |
| 10-01 to 10-02 | 3 | 109 | fex |
| 10-03 | 37 | 146 | madeira-unix 22, wine-pe 8, fex 3, wine-unix 3 |
| 10-04 | 23 | 169 | madeira-unix 6, wine-pe 6, fex 3, mesa 3, wine-unix 3, gbe 2 |
| 10-05 | 5 | 174 | |

**Churn.** `madeira-unix` is both the largest Playport series and the one that
churns most. It has 72 Playport patches (+6,918 lines), and since the 10-01
squash 26 of the 32 commits that touched `patches/` touched it. The Portal 2
i386/WoW64 work is the biggest single block. A subject/Evidence heuristic
(WoW64, i386, window, 32-bit, `portal2`) counts **67 of the 174 Playport
patches, +7,806 lines**: `madeira-unix` 32, `wine-pe` 15, `wine-unix` 7,
`fex` 6, and others. Within that, `madeira-unix` 0049-0075 alone is 27
patches, +4,650/−777.

### A2. Cost of past rebases and syncs (evidence records)

| Event | Upstream distance | Patches carried | Needed resolution | Wall time |
|---|---|---|---|---|
| DXMT onto upstream main ([2026-09-24-dxmt-latest-rebase](../evidence/2026-09-24-dxmt-latest-rebase.md)) | 327 upstream commits | 44 Madeira commits | 11 three-way, 1 empty, 3 semantic breaks with no marker (one is the slot ABI), 3 renames, 4 build changes, a licence change | about 2.5 h, device gates included |
| FEX onto FEX-2609.1 ([2026-09-24-fex-latest-rebase](../evidence/2026-09-24-fex-latest-rebase.md)) | 591 upstream commits | 64 + rpmalloc 16 | 16 three-way, 3 compile fixes, 14 gitlink bumps moved to rpmalloc; rpmalloc 3 resolved; git silently misplaced auto-merged hunks | about 4 h |
| Wine onto wine-11.18 ([2026-09-26-wine-latest-rebase](../evidence/2026-09-26-wine-latest-rebase.md)) | 3,493 commits (wine-11.4 to 11.18) | 56 fork commits + about 92k lines of `*_ios.c` replacements | 7 of 56 three-way. Each replacement was ported by reading it against upstream's rework (thread_data, main_module, pe_mapping_info, split arm64 contexts). This became `madeira-unix` 0020-0026 (+3,419/−2,873) | not recorded; the record has 8 steps |
| Valve picks ([2026-09-28-wine-proton-rebase](../evidence/2026-09-28-wine-proton-rebase.md)) | 1,453 Valve commits classified | 127 picked | 13 resolved | not recorded |
| The one `pp sync` so far (Madeira 5a82d39 to 8c050d0, [2026-09-25-dxmt-port-ca8a251](../evidence/2026-09-25-dxmt-port-ca8a251.md)) | 5 Madeira commits | all series | all replayed clean; held on `dxmt-port-moved` and a licence-file change; 1 commit re-ported by hand (dxmt-port 0045, resolved in 4 files, including two unix calls upstream already had) | landed by hand |

### A3. Trial: what a move to each head costs today

Method (`pick.sh`): take the build's patched tree in `.work/run` (the pin
with its series as commits). Cherry-pick every commit onto the newer upstream
in a scratch clone. A commit that does not apply cleanly is counted as
`conflict`, then re-picked with `-X theirs` so that later commits are not
counted twice for the same cause. These numbers are textual conflicts only.
Semantic breaks (slot ABIs, misplaced hunks) are not caught, and the records
in A2 show they are common.

| Tree | Move | Upstream commits | Replayed | Clean | Conflict | Conflicting patches |
|---|---|---:|---:|---:|---:|---|
| `madeira-unix` on Madeira | 8c050d0 → `origin/main` 69b2fc0 (10-01) | 214 (165 non-merge) | 79 | 58 | **21** | 0002, 0003, 0008, 0014, 0018, the six replacement ports 0020-0025, 0029, 0041, 0046, 0049, 0050, 0053, 0061, 0068, 0072, 0074 |
| `fex-port` + `fex` on FEX | FEX-2609.1 → `main` 0df84d38 (09-28) | 137 | 83 | 77 | **6** | fex-port 0001 (Syscalls.h), 0006, 0009 (CPUFeatures), 0043 (SharedCodeBufferManager); fex WOW64 0016, 0018 |
| `dxmt-port` + `dxmt` on DXMT | 7c8dee1 → `main` fb45156 | 3 | 54 | 53 | **1** | `dxmt_context` device init |
| `wine-port` + `wine-valve` + `wine-pe` on Wine | wine-11.18 → `master` 6d1b094 (09-28) | 318 | 211 | 210 | **1** | wine-port 0031 (`signal_arm64ec.c`) |

Without the conflict suppression, `git am -3` with skip-on-conflict (the way a
naive replay goes) gives these upper bounds:
- `madeira-unix`: 26 clean, 5 3-way, 48 conflict or no fake ancestor.
- `fex-port`: 30 clean, 4 3-way, 29 conflict.
- `fex`: 1 clean, 1 3-way, 18 conflict or fail.

The skips cascade.

**What the Wine replacements drift by.** The Wine files that Madeira's
`*_ios.c` replace are 22 files in `dlls/ntdll/unix`, `dlls/win32u`, `server`
and `crypt32`. WineHQ commits touching them:
- wine-11.4 → 11.18: 254 commits, +3,110/−2,596 in 19 files.
- wine-11.18 → master (318 commits): 6 commits, +35/−36 in 4 files.

Following Wine tag by tag is cheap. The jump from 11.4 was the expensive one.

**Madeira's own fork repositories also moved** (69b2fc0's gitlinks, fetched
into scratch). A `pp sync` to that commit holds on all three `*-port-moved`
flags:

| Gitlink | Pin's fork commit → `origin/main`'s | Commits | What they are |
|---|---|---:|---|
| `wine` | 723d1bf → 4f5b197 | 31 | the iOS WoW64 series (third-party PRs #6-#12: window-aware wow64/wow64win pointer conversion, per-process GDI table, WoW64 thread contexts), opt-in fastsync client and server, async APC hand-over, nsi fallbacks |
| `FEX` | 0f8edf8 → 26859e1 | 12 | "FEX WOW64: run 32-bit guests on the iOS host", 32-bit guest-window base register, rpmalloc advance, CPUID bound |
| DXMT | `research/dxmt` ca8a251 → `dxmt` a5e0cd3 (path moved) | 22 | a DXSO/D3D9 frontend on winemetal unix-call **slots 145-149**, BCn decoder, present cap, WoW64 pointer conversion |
| new: `madeira-dock` | – | – | a new submodule |

`tools/sync.py` (`GITLINKS`, line 96) and `build/pipeline` (line 213) both read
`research/dxmt`. Madeira's "Reorganize the repository" (79e28f0) moved it to
`dxmt`, so the sync tooling breaks on that commit before any patch is
replayed.

### A4. Madeira: its own code, what Playport uses, what Playport changes

**The Madeira repository at the pin** (8c050d0, 206 commits, 2026-03-07 to
09-25) has 178k tracked text lines outside its submodules. The largest areas:

| Area | Lines | Used by Playport? |
|---|---:|---|
| `build/ntdll-unix` (`virtual_ios.c` 21,398; `signal_arm64_ios.c` 14,482; server, thread, loader, process, env, audio, unixlibs) | about 58k | yes (P3) |
| `build/win32u-unix` (sysparams, message, defwnd, driver, class, winstation) | about 21k | yes (P4-win32u) |
| `build/wineserver` (queue, fd, window, mapping, request, mach) | about 20k | yes (P4-server) |
| `build/crypto-unix`, `build/madsync`, gnutls/freetype recipes, `madeira_cfg.h` | about 2k + scripts | yes |
| `app/Madeira/Winios` (Winios.m 1,370) + `IOSDisplayShim` | about 1.5k | yes (P5-winios with `madeira-winios`, P5-dxshim) |
| `research/madeira-d3d12` | 29,174 | no |
| `app/Madeira` (Madeira's own Swift/ObjC app) apart from Winios | about 15k | no (Playport has its own app, decision 0012) |
| `build/x64-tests`, research handoffs, docs | about 20k | no |

**How much of the replacements is Wine and how much is iOS code.** Each
patched `*_ios.c` in `.work/run/unix/mythic` was diffed against its WineHQ
original in the patched Wine tree (histogram diff):

| Replacement | Lines now | WineHQ original | Lines identical to Wine | Lines not in Wine |
|---|---:|---:|---:|---:|
| `ntdll-unix/virtual_ios.c` | 23,305 | 7,321 | 7,026 | 69.9 % |
| `ntdll-unix/signal_arm64_ios.c` | 14,988 | 1,955 | 1,749 | 88.3 % |
| `ntdll-unix/server_ios.c` | 5,090 | 2,058 | 2,043 | 59.9 % |
| `ntdll-unix/loader_ios.c` | 3,526 | 2,126 | 2,110 | 40.2 % |
| `ntdll-unix/process_ios.c` | 3,303 | 2,015 | 2,013 | 39.1 % |
| `ntdll-unix/thread_ios.c` | 3,369 | 2,822 | 2,802 | 16.8 % |
| `ntdll-unix/env_ios.c` | 2,883 | 2,492 | 2,463 | 14.6 % |
| `win32u-unix/*` (7 files) | 21,597 | 23,885 | 19,931 | 2-34 % each |
| `wineserver/*` (8 files) | 16,498 | 14,696 | 14,135 | 2-60 % each |
| others (audio_null 1,487 new; crypt32, nsi, dwrite/freetype stubs) | 3,008 | | | |
| **All 26 replacements** | **97,567** | **61,911** | **55,694** | **41,873 (43 %)** |

So Madeira's host layer is about 98k lines:
- about 56k are Wine's code copied, which has to follow every Wine move by
  hand (0013);
- about 42k are iOS logic: Madeira's plus Playport's.

The replacements carry **563 distinct `ml###` markers**, Madeira's numbered
device findings (a measure of the device knowledge embedded in them).

**What Playport changes in Madeira's tree** (`git diff 8c050d0 HEAD` in
`.work/run/unix/mythic`):
- 47 files, +9,917/−3,324.
- The 7 `madeira-port` patches (the port onto wine-11.18) are +3,419/−2,873.
- The 72 Playport patches are +6,918/−887: feature 3,953, upstream-bug 1,109,
  ios-port 798, diagnostics 720, host-app 331.
- Churn relative to each file: `virtual_ios.c` +2,627/−720 (15.6 % of its
  21,398 lines), `signal_arm64_ios.c` 5.2 %, `server_ios.c` 15.5 %,
  `thread_ios.c` 18.3 %, `loader_ios.c` 18.0 %, `class_ios.c` 47.9 %,
  `mach_ios.c` 27.3 %.
- 17 new headers (`wow64_*.h`, `audio_wow64_*.h`, `image_reloc.h`; about
  2,400 lines) are Playport's alone.
- No Madeira file was rewritten wholesale. The heaviest are `class_ios.c`
  (48 % of its lines, mostly the 11.18 port) and `gnutls_symtab_ios.c`.

**Madeira's design versus Playport's in what runs (inference from the line
counts).** Count only the code that is neither WineHQ, FEX-Emu nor 3Shain:
- Madeira wrote about 35k lines of iOS logic in the replacements (42k minus
  Playport's 6.9k) and +35.1k lines in the four port series. That is about
  70k lines, plus Winios (1.4k) and the build recipes.
- Playport wrote about 16.3k lines in its own patches and 3.4k in porting the
  replacements.

The in-process design is Madeira's: wineserver as a thread, JIT pool aliases,
x18/TEB retargeting, the signal and exception paths, the FEX iOS hardening,
the winemetal remote transport. Playport has added the pseudo-process window
for i386 WoW64, the JIT-pool policy (0019/0036), the host-band and arena
accounting, diagnostics, and the Vulkan and GStreamer routing. **By lines,
about 75-80 % of the non-upstream runtime code is Madeira's (inference).**

**Madeira's upstream activity** (8c050d0 → 69b2fc0, 2026-09-25 to 10-01, 6 days):
- 214 commits, 49 of them merges of pull requests. 141 are by one third-party
  contributor (the same contributor `LICENSE-MADEIRA.md` already credits;
  [dxmt-port-ca8a251 record](../evidence/2026-09-25-dxmt-port-ca8a251.md)).
- Diffstat: `app/Madeira` +23,109, `tests` +15,062 (the reorganisation),
  `build/ntdll-unix` +12,815, `madeira-d3d12` +11,175, `build/win32u-unix`
  +681, `build/wineserver` +388.
- 47 of the 165 non-merge commits touch paths Playport builds (+14,944/−476 in
  41 files).

What these 47 commits do:
- **Duplicates of Playport fixes**, matched by subject. Diffs were not compared.
  - TEB/TSD retarget bitmap by bit: Playport's `madeira-unix` 0002.
  - Killed thread leaves its uninterrupted section: 0041.
  - Audio unixlib without MIDI: 0046.
  - GDI handle table reachable by 32-bit programs: 0064.
  - Queue a system APC on a live thread: Playport's `wine-unix` 0002.
- **A parallel i386/WoW64 implementation.**
  - In Madeira: "ntdll iOS: 32-bit processes in guest windows" and "iOS VA:
    lazy WoW64 guest windows".
  - In the wine fork: wow64/wow64win window-aware conversion.
  - In the FEX fork: "FEX WOW64: run 32-bit guests on the iOS host".
  - These overlap Playport's Portal 2 work (67 patches, +7.8k lines).
    PORTAL2-PLAN.md line 64 still says "Madeira has only run ARM64EC".
- **Design choices Playport has decided against or made differently:**
  - fastsync made the default sync engine. Playport keeps in-process sync off
    (0023, `madeira-unix` 0014).
  - A winegstreamer unix side on FFmpeg/VideoToolbox (+5.8k lines).
    Playport uses GStreamer's iOS release (P6-gst).
  - D3D9 on a DXMT frontend. Playport uses DXVK d3d9 on KosmicKrisp (0047).
  - A swap tier, and Madeira Dock.

Madeira is moving fast, accepts outside pull requests within days, and is
moving into the same areas Playport has been building on its own.

### A5. Tooling and disk facts that bear on the choice

- **The build already holds each series as a branch.** `build/lib.sh`
  (`apply_series`, `ensure_series`, `check_series` by patch-id, 94 lines)
  materialises the pin plus the series as commits in `.work/run/<tree>`, and
  re-applies any series whose patch-ids differ. Each run tree is a local fork
  branch that gets rebuilt from the patch files.
- **Sync tooling.** `tools/sync.py` is 1,118 lines: replay classes
  `clean`/`merged-3way`/`already-upstream`/`conflict`, device gates, the
  `*-port-moved` holds and the Valve report. `tools/checks.py` and `pp test`
  check the trailers, and CI runs `pp test --quick`.
- **Disk.** `.work/run` is 20 GB (`pe` 14 GB) and `.work/cache` 5.4 GB with
  full mirrors of wine, FEX, DXMT, rpmalloc and gbe. Decision 0028 removed
  per-agent checkouts to save disk. A fork-branch model needs no additional
  checkout: the run trees and cache mirrors already exist.
- **Provenance.**
  - The name gate `pp names` only rejects the retired project name. "Name no
    project other than willfaust/Madeira as provenance" (AGENTS.md) is a
    policy, enforced by review.
  - Decision 0001 chose a superproject over a fork for two reasons. Privacy
    is obsolete: Playport is public (0043). The 30 MB proprietary
    `libmetalirconverter.dylib` in Madeira's history still holds, for a
    Madeira fork only.
- **Licences of a fork or rewrite.**
  - The `build/*-unix` replacements are copies of LGPL-2.1+ Wine files inside
    Madeira's GPL-3.0+ tree (LICENSING.md components table; "many carry
    Wine's LGPL header"). Madeira's FEX, DXMT and rpmalloc changes are
    GPL-3.0+ with Madeira's exception, over MIT, LGPL-2.1+ and 0BSD upstreams.
  - Anything rewritten from those files is a derivative and keeps both the
    Madeira copyright and the GPL/LGPL terms **(inference: a "rewrite" by
    people who have read the code is not a clean room)**.
  - Playport's own exception (0006) covers only Playport-owned lines.
  - The Corresponding Source duty (0042: the public repository at the tag
    plus `pp build --clean` from pins) needs every pinned commit to stay
    fetchable. With fork branches that are rebased, that means an immutable
    tag per pinned commit in a public repository Playport controls.

---

## Part B. The options against the numbers

### (a) Status quo: pins plus patch series everywhere

- **For.**
  - Three of the four big trees are cheap to move by the measured numbers.
    Wine: 1 conflict in 211 patches over 318 commits, and 6 commits on the
    replaced files. DXMT: 1 in 54. FEX: 6 in 83 over 137 commits.
  - Moving more often keeps each move small. The 591-commit FEX jump cost 16
    resolutions, and the 3,493-commit Wine jump cost a hand re-port of the
    replacements.
  - Content checks, trailers, the source bundle and CI all work today.
- **Against.**
  - Madeira: 21 conflicts in 79 for 6 days of upstream, plus three port
    re-ports, a path rename the tooling does not handle, and overlapping
    designs.
  - Patch files are reviewed as diffs of diffs, and rerere state is lost
    between rebases.
  - Every hand port of a `*-port` series repeats work Madeira has already
    done in its own fork.

### (b) Own fork branches per dependency (patches as commits in remote repos)

- **For.**
  - Native `git rebase`, `rerere` and `range-diff` (AGENTS.md already requires
    range-diff by hand).
  - Branches that are ready for pull requests (helps d).
  - A pin is a commit, not a content check.
- **Cost.**
  - Rewrite the build's fetch (`clone_at`, `ensure_series`), `pp sync`
    (1.1k lines), `checks.py`'s trailer checks, the source bundle and
    `pp test`'s series checks.
  - Host 6-9 public repositories and tag every pinned commit, so that rebased
    history stays fetchable (0042).
  - A Madeira fork would carry the proprietary dylib (0001).
- **Gain.** Small **(inference)**:
  - The run trees already are those branches locally.
  - The conflict counts in A3 come from upstream, not from the storage
    format. A fork rebases the same 21, 6, 1 and 1 conflicts.
  - What a fork mostly adds is rerere and PR-ready history. A tooling change
    can add both without moving the canonical form out of the repository.

### (c) Madeira: stop tracking it and own (or rewrite) its layer

What Playport would own:
- about 98k replacement lines, 56k of them Wine copies that must follow Wine;
- about 35k port-series lines (FEX, DXMT, rpmalloc, Wine);
- Winios and the build recipes;
- 563 `ml###` findings' worth of device knowledge.

Weighed:
- **A rewrite from scratch** would redo the hardest code in the stack:
  `virtual_ios.c`, 23k lines, 70 % iOS-specific; `signal_arm64_ios.c`, 15k
  lines, 88 % iOS-specific. It would not escape the licences (above).
  **Not recommended.**
- **A freeze-and-own fork** ("soft fork": stop moving the `madeira` pin, own
  `build/*-unix` from here). It costs little in mechanics, because Playport
  already ports the replacements to each Wine itself (`madeira-unix`
  0020-0025, 0013) and already carries Madeira's FEX, DXMT and Wine commits
  as its own series. What it loses is Madeira's stream:
  - in 6 days, 47 relevant commits, including fixes Playport also found and
    WoW64 work that Playport is building in parallel;
  - the third-party contributor's FEX, Wine and DXMT work.
- **Provenance.** AGENTS.md and 0001 make willfaust/Madeira the only named
  provenance. A soft fork keeps that true: the code still comes from Madeira
  at a recorded commit. A rewrite would need a new decision that redefines
  provenance. Licence notices (`LICENSE-MADEIRA.md`, GPL-3.0+ with Madeira's
  exception) stay owed either way.

### (d) Upstream what can go upstream: not pursued

The owner offers nothing upstream (2026-10-05). Every patch stays carried, and
`Offered-upstream:` stays `no`. Fixes that Madeira or another upstream makes on
its own (A4 lists 5 by subject) still drop out of the series as
`already-upstream` when they arrive in a sync.

---

## Part C. Recommendation per dependency

| Dependency | Carried today | Measured move cost | Recommendation | Why | Tooling implications |
|---|---|---|---|---|---|
| **dxvk** | none | pin edit | status quo | unmodified | none |
| **vkd3d-proton** | 4 patches, +104 | not trialled (no history locally); plan: 20 commits | status quo series | tiny | none |
| **mesa** | 16, +4,633 | not trialled; plan: head unknown | status quo series, moved often | biggest Playport-owned series; each Mesa move replays 16 ios-port patches, so small moves keep it cheap | the rebase helper (Part D) |
| **gbe** | 5, +791 | no move pending | status quo | small | none |
| **idevice** | 1, +95 | – | status quo | one patch | none |
| **rpmalloc** (+ `rpmalloc-port`) | 3 + 16 | moves with FEX | status quo, same commit as FEX | defined by FEX's gitlink | none |
| **fex** (+ `fex-port`) | 20 + 63, +11.6k | **6 / 83** conflicts over 137 commits | status quo series, moved **often** (FEX main every 1-2 weeks) | small moves are cheap; the 591-commit jump cost 16 + 3 + 3; FEX-Emu will not take Playport's patches | add a rerere-backed rebase helper (Part D) |
| **dxmt** (+ `dxmt-port`) | 9 + 45, +10.1k | **1 / 54** over 3 commits | status quo series | upstream DXMT moves slowly; the slot-ABI check (`pp slots`) is the real gate. **Madeira's DXMT fork now uses slots 145-149 for DXSO**, which collide with the port's 146-149 | `pp slots` stays mandatory; port the slot reconciliation into the helper |
| **wine** (+ `wine-port`, `wine-pe`, `wine-unix`) | 57 + 27 + 14 | **1 / 211** over 318 commits; replaced files: 6 commits, 71 lines | status quo, moved **every WineHQ tag** | cheap per tag; the cost was the 11.4 → 11.18 jump | none |
| **wine-valve** | 127 | not measured (Valve's repo is not in the cache) | status quo series (0018); picks from bleeding-edge per the alignment plan | | `pp sync`'s Valve report must list bleeding-edge (plan B2) |
| **madeira** (`madeira-unix`, `madeira-winios`, and the source of the 4 port series) | 79 + 3, plus the 188 port patches | **21 / 79** in 6 days; 3 port re-ports (31 + 12 + 22 fork commits); a path rename; parallel WoW64, sync, video and D3D9 designs | **reconcile and carry**: stay on Madeira as the base (no rewrite); take a decision per overlapping area (take Madeira's, or keep Playport's and carry it); keep a freeze-and-own fork as a named fallback with triggers | most of the runtime is Madeira's design (about 75-80 % of non-upstream lines, inference); Madeira is active, and taking its design where it overlaps removes a conflict source | `tools/sync.py` and `build/pipeline` must learn `dxmt` (not `research/dxmt`) and ignore or handle `madeira-dock`; a sync report section listing Madeira commits that touch built paths |

---

## Part D. Proposal

### The model

**Keep the pins plus series model (status quo) as the canonical form for every
dependency, add two things to it, and settle the Madeira overlaps by decision
rather than replaying them.**

1. **Rebase tooling, not fork repositories.**
   - A `pp` command (`pp rebase`, done) rebases one target's run tree onto a
     new pin in a throwaway clone. It uses `rerere` (with its cache in
     `$PLAYPORT_BUILD`), `zdiff3`, and the cascade-suppressed conflict trial
     used here (`pick.sh`), and writes a `range-diff` against the old series.
   - It re-exports with the documented `format-patch` command and keeps
     `Rebased:` and `Picked:` trailers.
   - This gives most of option (b)'s benefit without new repositories, a
     source-bundle change, or new pin semantics **(inference)**.
2. **Small, frequent moves for Wine, FEX and DXMT.** Measured: a tag-to-tag
   Wine move is 1 conflict; FEX two weeks behind is 6. This is what the
   owner's "latest possible" direction implies anyway.
3. **No upstreaming** (owner, 2026-10-05): every patch stays carried;
   `Offered-upstream:` stays `no`.
4. **Madeira reconciliation.** For each overlapping area, a short decision:
   take Madeira's, or keep Playport's and carry it. The areas are:
   - i386/WoW64 windows;
   - in-process sync (fastsync);
   - winegstreamer;
   - D3D9;
   - DXMT slots 145-149.
5. **Named fallback: a freeze-and-own fork of Madeira's host layer.** It is
   adopted only by a new decision record, if one of these triggers holds:
   - Madeira's design diverges where Playport cannot follow (for example,
     fastsync becoming mandatory);
   - two consecutive syncs each cost more than one work session to reconcile.

   No rewrite.

### Migration steps

| # | Step | Effort (inference, from A2 wall times and A3 counts) |
|---|---|---|
| 0 | Fix the sync tooling for Madeira's reorganisation: `GITLINKS`/pipeline `research/dxmt` → `dxmt`, and decide what `madeira-dock` means for `sources`. **Done, a8c0859e** (a dry `pp sync bbbf8d0` reaches the four `*-port-moved` holds); left for the Madeira move: `build/source-bundle.json`'s madeira rules (`research/dxmt`, `madeira-dock`, `build/*-tests/*.exe` now `tests/`) | about half a day |
| 1 | Rebase helper (rerere, trial, range-diff, re-export), tested on the FEX → main move. **Done, 0dd5f68**: `pp rebase` ([UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md#moving-a-component-pin)); FEX trial onto `main` 3648ee9 (145 commits): 6 conflicts (fex-port 0001, 0006, 0009, 0043; fex 0016, 0018), 5 3-way, all flagged hunks checked, both DLLs compile; rpmalloc unchanged; draft in the build area, the move itself is order row 3 | 1-2 days |
| 2 | Madeira reconciliation: a per-area comparison of Madeira main (fetch `bbbf8d0` or newer) with Playport's series; one decision record listing what is taken from each side | 1-2 days of reading, plus Portal 2 and Hollow Knight gates |
| 3 | Step 1 of the alignment plan, reordered (below) | as the plan |

### Interaction with the alignment plan's step 1

- The plan puts Madeira first "because the port rows must equal Madeira's
  gitlinks". That rule constrains the `*-port` rows, not the `wine`, `fex` and
  `dxmt` base rows. Those can move under their current port rows, as 0007,
  0008 and 0013 did.
- The measurements say Madeira is by far the most expensive move (A3) and
  the one with open design questions (A4). The others are cheap.
- **Recommended order:**
  1. Steps 0-1 above.
  2. Then `wine` (tag), `fex` + `rpmalloc` (main), `dxmt` (main), `mesa`,
     `dxvk`, `vkd3d-proton`, one per commit, as the plan says.
  3. Then the Madeira reconciliation (step 2 above).
  4. Then the Madeira `pp sync` with the three port re-ports landing together.

  The Madeira fork deltas (31 Wine, 12 FEX, 22 DXMT commits) are then
  re-ported once, onto the new bases, rather than before and after.
- **The model change (steps 0-2) should happen before Madeira moves, but need
  not block the other rows.**
- The owner agreed to this order (2026-10-05); the alignment plan's table has
  it, and the step-1 pin-policy record states it.

### Decision records needed

- **Pin policy for heads** (already planned by the alignment plan): supersedes
  the pin-source parts of 0008, 0013 and 0018. Add: Wine moves every tag, FEX
  moves frequently, and the step-1 order is changed as above.
- **Carrying model:** series stay canonical (0001 holds, with its obsolete
  privacy reason noted); rebases use the helper; nothing is offered upstream,
  so every patch is carried for good.
- **Madeira reconciliation:** per area, whose design Playport runs. This may
  touch 0023 (sync), 0047 (D3D9 path) and P6-gst (video).
- **Fallback criteria for a Madeira soft fork** (could be part of the
  previous record). It must restate provenance (AGENTS.md, 0001) and the
  licence duties: LGPL Wine copies, GPL-3.0+ Madeira code with its exception,
  the MIT/0BSD upstream notices.

### Risks

- **Silent semantic breaks** are the main real cost (A2: slot ABI, misplaced
  hunks, stale calls hidden by `-Wno-implicit-function-declaration`). Neither
  forks nor series remove them. Only `pp slots`, undefined-symbol comparison
  and device gates catch them.
- **Parallel WoW64 implementations.** Taking Madeira main's WoW64 wholesale
  could break Portal 2. Keeping Playport's could make every later Madeira
  sync conflict in `virtual_ios.c`. 13 of the 21 trial conflicts are in
  `virtual_ios.c`, `loader_ios.c` or `env_ios.c`.
- **Carrying everything.** With no upstreaming, Playport's 174 patches only
  shrink when an upstream fixes the same thing itself; frequent small moves
  and the helper are what keep that load cheap.
- **Relying on Madeira's pace.** In 6 days it rewrote its layout and added
  about 15k lines in built paths. A slow sync cadence lets this pile up
  (the plan's 438 commits by 10-04).
- **Unmeasured here:**
  - Valve bleeding-edge picks;
  - Mesa, DXVK and vkd3d-proton head moves (their run trees are shallow);
  - Madeira beyond 69b2fc0;
  - diff-level (not subject-level) equivalence of the "duplicate" fixes;
  - whether Madeira's WoW64 and Playport's are compatible designs.

---

## Row 5 plan: Madeira to bbbf8d0

**Superseded by [0054](../decisions/0054-madeira-frozen.md) (Madeira frozen); `madeira-main` kept as a reference branch.** Kept as the record of the move that ran on `madeira-main`; it does not run on `main`.

Measured on 2026-10-05 for [decision 0052](../decisions/0052-madeira-reconciliation.md),
with the owner's answers applied. The trial scripts and their tables were left
in the build area. Estimates are inferences from A2's wall times.

**Heads.** Madeira `main` is `bbbf8d0` (still the head by `ls-remote` on
2026-10-05), 438 commits past the pin `8c050d0`; 88 non-merge commits touch
built paths (+19,208/−650 in 43 files). Its gitlinks: wine `3a54f56` (the
`madeira-lgpl` head, still based on wine-11.4), FEX `be778d7`, dxmt `8937c08`
(now at `dxmt`), FEX's `External/rpmalloc` `812c2b9` (the fork's one newer
commit, `2dc128f`, is a licence record only), and `madeira-dock` (not used).

**Trial conflicts on the new bases** (cascade-suppressed picks; textual only,
so lower bounds):

| Step | Units | Clean | Conflict | Notes |
|---|---:|---:|---:|---|
| wine-port: Madeira's wine `723d1bf..3a54f56` onto wine-11.19 + wine-port | 27 | 16 | 10 | plus 1 modify/delete: `dlls/bcrypt/gnutls.c` (WineHQ dropped the bcrypt unixlib) |
| wine-valve on that | 132 | 131 | 1 | 0097 `WINE_HEAP_TOP_DOWN` against Madeira's heap.c |
| wine-pe on that | 27 | 19 | 8 | 0001 (duplicate), 0005, 0013, WoW64 0016 0018 0021 0022 0025 |
| wine-unix on that | 14 | 7 | 7 | 0001 (duplicate), 0002 (APC), WoW64 0008 0009 0010 0012 0013 |
| fex-port: Madeira's FEX `0f8edf8..be778d7` onto FEX `3648ee9` + fex-port | 23 | 12 | 6 | 4 empty (pull-request pairs), 1 gitlink |
| fex on that | 20 | 15 | 4 | 0003, 0005, 0016, 0018; 0013 empty (Madeira's 293c524) |
| dxmt-port: Madeira's dxmt `ca8a251..8937c08` onto DXMT `68af85e` + dxmt-port | 55 | 32 | 15 | 8 empty (pull-request pairs) |
| dxmt on that | 9 | 4 | 5 | 0002, 0003, 0005, 0007, 0008 |
| rpmalloc-port `1f271c0..812c2b9`, then rpmalloc | 6 + 3 | 9 | 0 | |
| madeira-unix on `bbbf8d0` | 80 | 54 | 26 | 82 hunks; `pp sync --dry-run` (am -3, no suppression): 24 clean, 6 3-way, 50 conflict |
| madeira-winios on `bbbf8d0` | 3 | 3 | 0 | review against Madeira's 1b09614 (Winios input) |

**Steps.**

| # | Step | Estimate |
|---|---|---|
| 0 | **Tooling. Done:** `pp sync` replays in the clone that keeps the preimages and calls a failed merge `conflict` (553adf2); every series' `index` lines re-exported (87326e3); an honest `bbbf8d0` dry run (084721b) | done |
| 1 | Decision 0052 accepted. Branch for the move (0028). Re-fetch Madeira; if `main` moved past `bbbf8d0`, re-run the trials | — |
| 2 | **rpmalloc-port** (6, all clean) and rpmalloc (3); the row → `812c2b9` | 15 min |
| 3 | **fex-port** with `pp rebase`: Madeira's 23 FEX commits onto FEX `3648ee9` + fex-port. **fex:** drop 0013 (empty); resolve 0003 and 0005; drop 0005/0008 if Madeira's `FEX_MADEIRA_HOSTPROBE` path makes `FEX_HOSTFEATURES` redundant (recheck LRCPC2's unix-side decode, Madeira ce34c10); 0015–0018 (WoW64) drop after Portal 2 parity; re-port 0019/0020 on Madeira's WOW64 module. Build `xtajit.dll` with Madeira's `FEX_GUEST_WINDOW` options; check `xtajit64.dll`'s code is unchanged where Madeira claims byte identity | 3–5 h |
| 4 | **wine-port**: Madeira's 27 Wine commits onto wine-11.19 + wine-port; drop Madeira's bcrypt wow64 thunk (the unixlib is gone). Fastsync arrives with it (f6848ad client, e200a5e server cells). **wine-valve:** resolve 0097. **wine-pe:** drop 0001 (Madeira's real export-IAT classifier, d52b3e6, replaces the stub: an HK gate) and the WoW64 set; resolve 0005, 0013. **wine-unix:** drop 0001 (d280865) and 0008/0009/0012/0013; re-port 0006 and 0007 onto the fastsync-bearing `sync.c`; re-port 0010, 0011; **rework 0002 for fastsync**: take 3ba35ad and c311978 (a system APC goes to a waiting thread), replace 074e0e3's drop with "keep it on the issuing thread" for every system APC type, and make sure a thread in a fastsync wait runs a queued system APC (the wait falls through to the server after its ≤2 ms park; check that is enough, or wake it) | 1 day |
| 5 | **dxmt-port**: Madeira's 55 DXMT commits onto DXMT `68af85e` + dxmt-port. Slots: keep upstream 0–145 and Madeira's 146–149 as rebased; append `DXSOInitialize` 150, `DXSODestroy` 151, `DXSOCompile` 152, `DXSOGetCompiledBitcode` 153, `DXSODestroyBitcode` 154, `d3d9_nop` 155 to both tables (wow64 twins at the same numbers), without Madeira's NULL 141–144 padding; renumber the PE side (`airconv_thunks.h` `unix_dxso_*`, `WINE_UNIX_CALL(150)` → 155); rerun `gen_remote_guard.py` and `gen_api_names.py`; `pp slots` clean. Madeira's 35a4db1 include layout in `dxmt-base.sh` and dxmt 0004. D3D9 (`d3d9`, `d3d9shim`, `dxmt_madeira_native`) not built or staged. **dxmt:** resolve 0002, 0003, 0005, 0007, 0008 | 4–6 h |
| 6 | **madeira-unix** on `bbbf8d0`. Drop 0002 (Madeira's 8c81b45), 0014 (Madeira's resolver already keeps madsync behind `inproc-sync = 1`), 0041 (74e5a59; recheck a killed child's parent wait), 0046 (c8abe3b) and the WoW64 set below. Rewrite 0031 as one patch: GStreamer's tables for 64-bit and wow64 callers, Madeira's `winegstreamer_unixlib_ios.c`, `wg_parser_apple_ios.c` and their FFmpeg links not built. Re-port the wine-11.19 replacements again (0020–0025, 0080 against Madeira's new `*_ios.c`; 0022 and 0023 are 11 hunks each). Resolve 0003, 0008, 0018, 0029, 0035, 0043, 0044 (kept: per-PEB alias callbacks). 0070 and 0076–0079 should apply | 1–2 days |
| 7 | **Portal 2 on Madeira's WoW64.** Drop, each only after a Portal 2 run shows Madeira's path covers it: madeira-unix 0049–0057, 0059, 0061–0066, 0068, 0069, 0072–0074; wine-pe 0015, 0016, 0018, 0021, 0022, 0024, 0025, 0027; wine-unix 0008, 0009, 0012, 0013; fex 0015–0018. Re-port on Madeira's `ios_wow.h` and the `ProcessWineIosWowGuestBase` (1010) query: wine-unix 0010, 0011 (winevulkan i386 pointers); madeira-unix 0058, 0060, 0067, 0071, 0075, 0079 if still needed; fex 0019, 0020; wine-pe 0020, 0023; the wow64win gaps Portal 2 finds (the 398-call audit is the checklist). App: `MADEIRA_FASTSYNC=auto` and `FEX_MADEIRA_HOSTPROBE` for every session, `MADEIRA_GDI_SHARED_SECTION=1` for an i386 title's session (launch environment, not an entry point: 0012 holds). Iterate to parity: launch, menu, ≥ 59 FPS at 720p capped, hitches within deps-latest's spread | 1–3 days |
| 8 | `pins.lock`: madeira `bbbf8d0`, wine-port `3a54f56`, fex-port `be778d7`, dxmt-port `8937c08`, rpmalloc-port `812c2b9`; the `upstream/madeira` gitlink. **Licence review:** `LICENSE-MADEIRA.md` in the three forks, dxmt's `COPYING.LIB` (the LGPL D3D9 import), Madeira's `app/Madeira/legal/*`; NOTICES.md and LICENSING.md | 2 h |
| 9 | **`build/source-bundle.json`**, the madeira entry: submodule key `research/dxmt` → `dxmt`; add `madeira-dock` (not built, never checked out); replace the `build/*-tests/*.exe` drop with `tests/*/*.exe` (15 prebuilt PEs) and `tests/dxmt/out-x64/cube/*`; drop `madeira-d3d12/*` (not built; prebuilt `.dxil`/`.metallib` blobs) and `build/ffmpeg/*` (not built); keep `build/tftrace/*.dll` and `research/remote-metal` | 1 h |
| 10 | `pp build --clean`, `pp verify` (both variants), `pp slots`, `pp test`, `pp names`, `pp secrets`; check every rewritten series' `index` lines (a clean patch `pp rebase --write` keeps as it is keeps its old base's preimage); commit the build records | 1 h + build |
| 11 | **Device gates** (one locked session): Hollow Knight `first-frame+10` and `pp perf` with `hk-new-game` (the cinematic plays); Portal 2 launch, intros, menu, a chamber, `pp perf` with `p2-walk` against deps-latest; Portal 2 lifecycle (pause, save/load, quit to menu, quit, the 0029 restart); **fastsync on and off on both titles** (`pp perf` frame and GPU ms, `srv/f`, hitches): it stays on unless a title regresses with it; `s1-host.log`: `[madsync] off`, the fastsync policy line, `[apc-*]`, `[wow-window]`, `[gdi-shared]`, `[unixlib] winegstreamer`, DXVK's `d3d9.dll` for Portal 2; a release-variant HK play | 2–3 h |
| 12 | Evidence `docs/evidence/<date>-madeira-bbbf8d0.md`: IPA sha256s, per-patch verdicts (dropped, re-ported, resolved), the slot table, the fastsync on/off numbers. One commit for pins, series and records (UPSTREAM-SYNC.md) | 1 h |

**Defaults that come with the move,** each gated by the plays above:
- inert unless the app sets them: the swap tier (`MADEIRA_SWAP_FILE`), held
  releases, `MADEIRA_WG_64BIT`, the HID pad;
- on in 64-bit sessions: one child boot at a time (023b158, at most 10 s),
  fixed-base images below 4 GB (53d46cb), the IAT-sync changes (aa70ae1,
  ed332b6), the RtlPcToFileHeader pool alias (030c7e0), TEB access emulation
  (d2d5e38), fresh `.data` on a DLL reload (1ef7df3), the shared-data clock
  (da896cd), in-process NSI tables (dd53cc3, 9307a5d), the dnsapi unix side
  (73b8cfe), the registry-loaded signal (cc20bab), audio ring-fill and 7.1.4
  fold (fd8e1eb, 95c70c1);
- in Madeira's dxmt-port, on for 64-bit: cached CPU mappings (4f025e0), the
  staging budget wait (51e74fe), submit before present (4443a2e), the 1536 MB
  reserve (bb18171), the new pacing modes.

**Total (inference):** 4–7 working days, about half of it step 7. 0052's
fallback applies if Portal 2 is not at parity within two work sessions.
