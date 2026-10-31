# Social Club on Rockstar's own CEF: single-process in both builds, no Playport CEF build

**Linear:** [PLA-476](https://linear.app/playportdev/issue/PLA-476). Related:
[PLA-364](https://linear.app/playportdev/issue/PLA-364) (RDR2),
[PLA-475](https://linear.app/playportdev/issue/PLA-475) (0.5.0, held for this),
[PLA-372](https://linear.app/playportdev/issue/PLA-372) (CEF payload distribution, to be cancelled),
[PLA-254](https://linear.app/playportdev/issue/PLA-254) (publisher launchers). Sub-issues:
[PLA-602](https://linear.app/playportdev/issue/PLA-602) (chunk 4: on by default),
[PLA-603](https://linear.app/playportdev/issue/PLA-603) (chunk 4: Playport's CEF removed),
[PLA-604](https://linear.app/playportdev/issue/PLA-604) (chunk 5: docs),
[PLA-605](https://linear.app/playportdev/issue/PLA-605) (chunk 6: gates).

**Status** (resume here; run log is in a PLA-476 Linear comment):

- Branch `dev/pla-476-sc-stock-cef`, unmerged and unpushed (HEAD: see `git log`).
- **Chunk 4 built, 2026-10-31, host checks only** (no phone run): PLA-602 (`d1aff807`: single-process on by
  default in both builds, a dev `PLAYPORT_SC_SINGLE=0` turns it off; `1424a0ac`: `PublisherLauncher.rockstar`'s
  runtime carries `env.PLAYPORT_SC_LAYOUT=1` (its `env.PLAYPORT_SC_SINGLE=1` was dropped in review, a no-op
  beside the default), so RDR2's Play and the launcher's Open run the layout in both builds with no keys, other
  titles never, a dev `=0` wins) and PLA-603 (merge `b5814a58`:
  wine-unix 0039, `cef_swap` with the chunk-1 key, the payload, `build/cef`, `patches/cef`, `patches/chromium` and
  their pins removed; `pp verify`'s `cef` check fails any IPA carrying a CEF payload). Chunk 3 skipped: since l7 the
  game's helper takes its own slots, so no libcef refusal is needed. Chunk 5's docs done (PLA-604). Main-checkout
  builds (records commit `ca8805e1`): dev IPA `92e7ba96568da1541384341c11ce91725b6bfa32edf6999ca18d9bb69587c5a0`
  (`.work/out/20261031-193743-92e7ba96/`, `pp verify` 90 checks incl. `cef`), release IPA
  `84bd7a16f23752055dc883c54c616b842910c6b8b25f2b70cda07e2df1fa0281` (`.work/out/20261031-194039-release-84bd7a16/`,
  95 checks). Both predate the review fix that dropped the launcher's `PLAYPORT_SC_SINGLE` key; a rebuild
  follows. Open for the owner: in a release build, Settings › Graphics' "End a game's own Social Club" and
  "Refuse its restarts" switches still show On but do nothing for a Rockstar Play (it runs the layout, and a
  release build ignores the stored switch there). Next: chunk 6, the phone gates
  ([PLA-605](https://linear.app/playportdev/issue/PLA-605)).
- Chunks 0 and 1 done. Chunk 2 **not passed** ([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md)):
  0224–0226 give the opt-in layout; wine-pe 0055 (early-image replay,
  [PLA-481](https://linear.app/playportdev/issue/PLA-481), Done) is an accepted increment (HK first-frame+10,
  game helper reaches allocator startup). The launcher helper's retained kind-3 view (l2–l6) is no longer kept:
  [decision 0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md) (owner, 2026-10-30)
  detaches a parked thread's alert wait at teardown and frees a view only that wait named (l7). Kept views are still
  never cleared, freed or overwritten by any other path. A dead owner's freed slot is held in place, never
  unmapped first (madeira-unix 0231, l9), closing l8's kind-2 loss. **Blocker now:** memory: with the game's
  Social Club up, Story's load step crosses the 8192 MB limit (l7, l9).
- **Measured (l5, 2026-10-30, IPA `b5ee00eb…`, `.work/ui-runs/20261030T104925-rdr2-p476l5`):** only kind 3
  (ELF_META) is kept, as its whole 6400 MiB view, pinned by one parked thread's wait address. It has 72.4 MiB
  committed, highest end 170.5 MiB. Kinds 1, 2, 4, 5 and 6 are freed and held again. The game's helper gets
  kind 1 and then fails **only** on the ELF_META refusal (`chrome_elf.dll failed to initialize`). Story stays on a
  black spinner. Peak 6307 MB, no jetsam. l2's kind 1/5 retention did not recur.
- **Owner decision 2026-10-30 (approved):** a disjoint 1 GiB second ELF_META slot, real
  `[0x79c0000000, 0x7a00000000)` (RW-alias cap slack), for a later helper when kind 3 is owned by another PEB.
  It comes with a slot-aware `ppsc_access` (real-range containment wins, a straddle across real ranges is
  refused, possible metadata overflow is logged; PLA-482). Opt-in layout only; 0132/0143 unchanged. The
  lifetime/quiescence proof stays deferred.
- The Risks stop rule is no longer near-triggered for the l3–l5 shape. 0.5.0 stays held.
- Build-records gap found on the way: [PLA-484](https://linear.app/playportdev/issue/PLA-484).
- **Measured (l6, 2026-10-30, IPA `d9612e9c…`, `.work/ui-runs/20261030T113719-rdr2-p476l6`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l6-the-second-metadata-slot)):** the game's helper gets
  `grant kind=7` (ELF_META2) after kind 1, chrome_elf initialises, and libcef gets kinds 2 and 4. libcef then
  commits at `0x7400002000` (A's kept kind-3 view, base `0x7400000000` in its registers), is refused, CHECKs and
  exits; the game shows Social Club error 17. In A the same commits landed in its own kind 3. Kind 7 is now
  ELF_META2; a refused reserve logs `kind=8`.
- **Ordered queue:** (1) review-fix writer chunk **done** in `ad295c7` (0225–0227, `wine_host.c`, 0055 `Class:`
  `ios-port`, [PLA-482](https://linear.app/playportdev/issue/PLA-482) diagnostics, retained-extent §5 diagnostics;
  [PLA-480](https://linear.app/playportdev/issue/PLA-480) smoke on RDR2 dev defaults, Witcher 3 not installed;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#review-fixes)); its host tests for `pp_sc_vm.h` and
  `pp_sc_access.h` were integrated in `29dfb45`, and review-2 fixes landed in `e3334ec` (IPA `fc42b29e…`, HK
  `.work/ui-runs/20261030T112027`); (2) **done** in `6213817`: madeira-unix 0228, the second ELF_META slot and
  slot-aware access, HK first-frame+10 passed (`.work/ui-runs/20261030T113629-hk-p476l6`) and RDR2 l6;
  (3) superseded by decision 0166 and l7 (the game's helper now gets kind 3 itself); it was: find on the workstation where libcef's `0x7400000000` comes from (libcef RVA `0x1ea580b` and
  the code that sets `R14`) before any new slot geometry, then the remaining chunk-2 gates. Chunk-2 gates after
  l6: the game's helper reaches allocator/browser startup — **partly** (chrome_elf initialises, libcef does not);
  Story cabin — **not passed** (SC error 17, no Story tab); no SC/launcher `NO GAP FITS` or soft grant — **not
  passed** (none from the game's helper and no soft grant, but the launcher helper's 26 V8 `NO GAP FITS` remain);
  7343 MB ±10 % — **not comparable** (peak 6328 MB without the cabin); (4) chunks 3–6, all under PLA-476.
  Chunk 3 needs owner approval if required; 0.5.0 held.
- **Measured (l7, 2026-10-30, IPA `5b38a50b…`, `.work/ui-runs/20261030T122917-rdr2-p476l7`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l7-wait-detach-decision-0166)):** decision 0166 in
  `9611a34` (madeira-unix 0229, wine-unix 0202). A's teardown detached tid 0200's wait (`node=unlinked`) and freed
  kind 3; no other parked address named it (the older-thread gap is closed for this run); kinds 1–6 held again. The
  game's helper got kind 3 itself and kinds 1, 2, 4–6, with no refusal; its browser ran; the Story tab came and was
  pressed (+134 s). Story's loading then grew the footprint to the 8192 MB limit and iOS ended the app at +238 s
  (jetsam, no crash). HK first-frame+10 passed (`20261030T122623-hk-p476l7`); The Witcher 2 unchanged
  (`20261030T122712-w2-p476l7`).
- **Measured (l8, 2026-10-30, IPA `2412a515…`, `.work/ui-runs/20261030T132255-rdr2-p476l8`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l8-component-update-off-pool-diagnostics)):** `fe20a23`
  (decision 0150 amended: the stock browser gets `--disable-component-update`; donor-pool `level`/`resume_wait`
  and post-teardown `[proc-mem]` diagnostics) with `7db5c9c`. No BITS activation, `dllhost` or WoW64 `NO GAP FITS`;
  a band view freed of its wait pins took `fate=0`. At A's teardown kind 2 was **not held again** (something
  mapped it, first time in 6 releases); the game's helper then started inside the old kind-2 range, got no grant,
  had its image protections refused and died `c0000005` in init; 0138 refused its restarts. Story was pressed and
  then stayed on a black loading screen to the run's end (peak 6496 MB, no jetsam). The pool stopped at press+66.6
  (level 14 %) and never resumed (`resume_wait="level 9–14% < 20%"`, spare ≈3.9 GB). HK first-frame+10 passed
  (`20261030T132206-hk-p476l8`).
- **Measured (l9, 2026-10-30, IPA `9cdc9635…`, `.work/ui-runs/20261030T135937-rdr2-p476l9`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l9-slots-held-in-place)):** `2df65fe` (madeira-unix
  0231). At A's teardown all six kinds were `held in place` (no re-hold, footprint 6353→5165 MB); the game's helper
  got kinds 1–6 with no refusal and its browser started. Story was pressed (+130.9) and its load step came at
  press+78 (sign-in+107, before 0153's 120 s end could take B off) from 7174 MB; `fast phys` 8106 MB, then jetsam
  (per-process-limit). The pool stopped on the level (13 %) at +93.8, resumed once after the teardowns, stopped
  again at +107.4. HK first-frame+10 passed (`20261030T135842-hk-p476l9`).
- **Measured (d1, 2026-10-30, the same IPA `9cdc9635…`, `.work/ui-runs/20261030T141431-rdr2-p476d1`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#d1-same-ipa-default-baseline)):** the owner's baseline
  before any change to the game-SC end.
  - **Keys:** `env.PLAYPORT_SC_SINGLE=1` only. That is xs1's configuration: Playport's CEF, single-process, no
    layout. The no-key dev default would be multi-process.
  - **Story reached the cabin** (≈+201). The load step came at press+74.6, sign-in+102.7: 6470 → 7689 MB, nearly
    all of it graphics. The step peaked at 7896 MB, +7.5 % against xs1.
  - **The game-SC end** fired after the step, at 7834 MB (−248). The game went back to its title menu. 0155 then
    allowed two restarts, each at ≈7.6–7.8 GB. Jetsam came at +446 (ActiveHard 8192 MB).
  - **l9 against d1:** l9 was **+602 MB** just before the step (7072 against 6470) and +452 at the press:
    - B on stock CEF/layout: +115 (M);
    - JIT pool: +48 (I);
    - donor-backed pages, from l9's pool stopping 45 s sooner: +207 (I);
    - not explained: +120 (I);
    - load growth no sample covers: +200 (M total);
    - shared graphics, process noise, services and drift: −88 (M).

    d1's step rose 1426 MB, so l9 needed ≥306 MB less to fit.
  - **Ranked options at the step** (each needs an owner decision):
    1. In a layout play, end the game's SC at the Story press, or at the threshold without the 120 s wait: ≈−550
       to −580 MB (B 579 resident+compressed; l7's end −550). Amends 0141/0153. It must come with option 2,
       because the end sent d1's game back to its title.
    2. Allow 0155's restart only when footprint plus ≈550 MB fits under the limit: 0 MB at the step, but it removes
       d1's late jetsam. Amends 0155.
    3. A lower threshold alone: 0 MB, because the 120 s wait still lands after the step. Only useful with 1.
    4. A pool resume or stop rule that kept l9's pool growing like d1's: up to ≈−200 MB (I), not enough alone.
       Amends 0105.
    5. Trim B's stock-CEF cost: at most −115 MB, not enough alone.
    6. The unexplained +120 MB and +200 MB need a footprint breakdown at the press and the step first.
- **Owner decisions 2026-10-30, done** (`b94a9eb`, `9289d2e`, `c45af90`):
  - [0155](../decisions/0155-allow-rdr2s-social-club-restart-after-a-re-sign-in.md) amended: an allow needs
    footprint + 600 MB < limit − 400 MB.
  - A dev footprint-jump sampler with a task-ledger reader.
  - [0105](../decisions/0105-memory-defaults-per-phone.md) amended: the pool resumes on spare memory, and the
    level stop then counts from the resume's level.
  - The FEX code-buffer roll before the load was **not** changed. RDR2 asks for 128 MiB at its second generation
    in every run; d1 got 64 MiB only because the tail room was short. A 64 MiB cap for every game (0116's rule)
    or a forced roll is not small; it needs a decision.
- **Measured (l10, 2026-10-30, IPA `c635f8c0…`, `.work/ui-runs/20261030T152516-rdr2-p476l10`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l10-headroom-for-0155-the-footprint-sampler-the-pools-spare-resume)):**
  l9's keys.
  - **The game's helper** got kinds 1–6 with no refusal. Story was pressed (+148.6).
  - **The step** came at press+71.9 from 6985 MB (the step's first move at 7172, as l9's 7174). It reached
    8185 MB, then jetsam (I; the syslog dropped). No cabin.
  - **The sampler.** The ledger reads on iOS (rc=0) and closes phys_footprint to 14 MB. Page tables are 9–11 MB,
    so the layout costs none worth counting. Samples came at step −8.3 and −3.2; none landed inside the step,
    because its walk did not finish before the kill.
  - **The pool** resumed on spare twice without flapping and held 2687 MB live (l9 2587, d1 2809). A resume at
    17 % then made it wait for 17 % for the rest of the run: a flaw in the amended rule, since R should count as
    at most 15 %.
  - **l10 is +473 MB above d1 just before the step** (+515 at the step):
    - FEX row +164 (no third generation; d1 rolled at press+2.1);
    - B's stock CEF +131;
    - pool +105;
    - host-side residual +127, flat from the press;
    - graphics −21, RDR2 private −74, services and the rest +41.

    d1's "+320 not explained" is closed: the load growth is views, not host memory. l10 needed ≥210 MB less to
    fit (l9 ≥306). HK first-frame+10 passed (`20261030T152425-hk-p476l10`).
- **Owner decisions 2026-10-30 after l10, done** (`ab1ab5c`): 0105's amendment corrected (a spare resume's stop
  level is R = min(L, 15 %)); the dev sampler logs its cheap `[fp-sample]` line before its walk, and a jump during
  a walk logs that line alone.
- **Measured (l11, 2026-10-30, IPA `a5f40ebb…`, `.work/ui-runs/20261030T154831-rdr2-p476l11`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l11-the-pools-r-cap-the-samplers-cheap-line-first)):**
  l10's keys.
  - **The game's helper** got kinds 1–6 with no refusal. Story was pressed (+132.0).
  - **The step** came at press+74.8 from 6776 MB and reached 8169 MB, then SIGKILL (I: jetsam). No cabin.
  - **The sampler** logged two cheap lines inside the step (7272, 7587/7738 MB). The step is graphics: +765 of
    +802 MB in 0.43 s, with wired memory following it.
  - **The pool** held 2812 MB live (d1 2809) and resumed on spare twice, both at 13 %; R = min(L, 15) was not
    exercised on the phone.
  - **FEX:** RDR2's second generation got 64 MiB from short tail room, so it rolled at press+2.0, as d1. Its fex
    row was 298 at the step (d1 303, l10 467).
  - **l11 is +306 MB above d1 just before the step** (l10 +515): B's stock CEF +132, the host-side residual +119,
    and the rest across phases (I). On d1's 1426 MB step l11 needed ≥10–30 MB less: a near miss.
    HK first-frame+10 passed (`20261030T154742-hk-p476l11`).
- **Owner decisions 2026-10-30 after l11, done** (`edddbb4`, `5987252`, `49e0bc7`, `79f42d7`, `2209aab`,
  `08021da`, `da73673`):
  - `[proc-mem]` splits resident pages into a file's and anonymous (madeira-unix 0232).
  - [0116](../decisions/0116-tail-room-for-every-process-and-the-launchers-smc-checks.md) amended: a code buffer is
    at most 64 MiB.
  - [0150](../decisions/0150-dev-single-process-social-club.md) amended again: the stock browser also gets
    `--disable-gpu --disable-gpu-compositing`. This widens this plan's "Chromium switches unchanged" scope, by the
    owner.
  - [0142](../decisions/0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md)/[0153](../decisions/0153-rdr2s-settings-are-every-games-defaults.md)
    amended: RDR2 is told 2304 MiB of video memory.
  - New [0168](../decisions/0168-social-clubs-helper-is-told-little-available-memory.md): the helper is told
    300 MB available.
  - New [0167](../decisions/0167-large-x86-64-images-map-from-a-cache-copy.md): large x86-64 images map from a
    re-laid-out cache copy.
- **Measured (l12, 2026-10-30, IPA `f2a0c7b8…`, `.work/ui-runs/20261030T171553-rdr2-p476l12`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l12-image-cache-copies-gpu-off-avail-phys-vram-2304-a-64-mib-code-buffer--story-reaches-the-cabin)):**
  l11's keys.
  - **Story reached the cabin** (+232) and held it to first-frame+600, at 21–22 fps. **Peak 7200 MB** (d1 7896).
    There was no jetsam.
  - **The step** came at press+76.5 from **5872 MB** (d1 6470, l11 6776) and rose 1318. The game-SC end
    (0141/0153) fired inside it at 7185 MB and ended B (−265). The game stayed in the cabin, and 0138 refused 18
    restarts.
  - **Against l11 at step −5:** −888 MB in all:
    - graphics −337 (VRAM 2304);
    - B −264 (its libcef from the copy: image anonymous 293 → 58);
    - the pool −274 (first stop 102 s later, live 3104);
    - RDR2 −29;
    - residual +52.
  - **Social Club rendered and signed in with GPU off.** B still loaded wined3d, dxgi, D3DCompiler_47 and
    libglesv2, but not d3d11.
  - **The image copies:** written once each (libcef 239 MiB in 308 ms), then mapped in A, the game and B.
  - **The 64 MiB code buffer:** RDR2 rolled at press+1.9 and press+67.4. The launcher's helper rolled 24 times and
    B 13 times (I: likely why Story was pressed 21 s later than in l11).
  - **HK:** first-frame+10 passed (`20261030T170711-hk-p476l12`). `pp perf` before/after: 58.7/58.7 fps, compiles
    +30 % from one 64 MiB roll; the after run's hitches were not recorded (Metal HUD off).
- **Measured (l13–l14, 2026-10-30, same IPA `f2a0c7b8…`; no code change;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l13l14-repeat-of-l12-hk-hitches)):** l12's keys, HUD off.
  - **l14 reached the cabin and held it** to first-frame+600 (peak **7058 MB**, step from 5638–5761 MB, 20 fps,
    `.work/ui-runs/20261030T185058-rdr2-p476l14`). **l13 reached it, then the app was killed at +374 s** (peak
    7627 MB, `launch=failed`; `.work/ui-runs/20261030T184300-rdr2-p476l13`): 0155 allowed a re-sign-in's Social Club
    restarts at +314 s and five restarts took the footprint from 6.9 to 7.6 GB (cause of the kill: I).
  - The pool stopped **late** in both repeats (press+98 and +103; l12 +67), so "the margin without the pool's early
    stop" was not tested; the policy terms held (graphics 3316–3471 at the step, B's image anonymous 53–58).
  - **HK `pp perf` with the HUD on:** 58.7 fps both; p99.9 66.7 → 50.0 ms; hitches > 25 ms 203 → 245 (> 50 ms and
    > 100 ms unchanged at 11 and 4); GPU 6.4 → 7.2 ms with the after run on power.
- **Owner decisions 2026-10-30 after l14, done** (`041c135`, `1d30b3d`, `0ffbb97`, `1413ed9`):
  - madeira-unix 0236 refuses the helper's impossible V8 reserves before the map walk. This goes into chunk 5's
    record.
  - madeira-unix 0237 limits avail-phys's log per process (0168 as built).
  - madeira-unix 0238 adds the ctime to the image-cache key and a 16-point sampled check on each use (0167 as built).
  - [0155](../decisions/0155-allow-rdr2s-social-club-restart-after-a-re-sign-in.md) is amended again: one helper
    start per allow (madeira-unix 0239). In l13, each of the five allowed helpers died before it signed in.
- **Measured (l15–l16, 2026-10-30, IPA `b1a239f2…`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l15l16-probe-refusal-avail-phys-per-process-image-cache-v2-one-start-per-allow--neither-run-reaches-story)):**
  l12's keys, with the game-SC end set on explicitly (the owner had played by hand just before).
  - **Neither run reached Story.**
    - l15 (`…/20261030T202106-rdr2-p476l15`): the launcher's helper died before the game's sign-in, in Chromium's
      out-of-memory exit (`request 0x3c0`). A blank launcher card was shown over the game.
    - l16 (`…T202901-rdr2-p476l16`): the game signed in. Its helper then died in the same exit (`request 0`): V8's
      1 GiB code range took an unaligned pick, and its padded 5 GiB fallback found no gap. That is l13's restart
      mechanism. 0138 then refused 60+ restarts, and the game sat on its spinner.
  - **The probe refusal worked:** 0 V8 `NO GAP FITS` lines from A in both runs. The exit lines count 26 (A) and 6
    (l16's B), and the ladder to the cage took 0.3 s.
  - The v2 copies were written once, the v1 copies were deleted, and every map passed its 16 sampled points.
    avail-phys logs B's answers.
  - HK first-frame+10 passed (`20261030T202011-hk-p476l15`). Peaks were 5564 and 5737 MB, with no jetsam.
  - Whether 0236–0238 or the owner's preceding play caused the two helper deaths is not determined (I: neither
    death follows from the refused sizes).
- **Measured (l17–l18, 2026-10-30, the same installed IPA `b1a239f2…`, no hand play before;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l17l18-repeat-on-b1a239f2)):** l12's keys,
  `arm15.sh`.
  - **Both runs reached and held the cabin:** l17 (`…/20261030T204959-rdr2-p476l17`) to first-frame+600, and l18
    (`…T210408-rdr2-p476l18`) to `[xp]` +717. In l18, `pp ui` stopped at +361.5 on a dropped network link (`exited`)
    while the app ran on; a second session pulled the log and ended it.
  - **l15–l16's helper OOM deaths did not repeat:** no `0xE0000008` and no `[chromium-oom]`. Each of the four helpers
    refused 26 impossible probes, and 0 V8 `NO GAP FITS` were logged (the game's 8960 MiB walk is the only line).
  - Each helper's V8 1 GiB code range took `cand guard` (hint offsets 8 or 12 GiB). In l12–l18, only l16's B had an
    offset-0 hint, took `cand plain` and died (I: the trigger). l15's A death remains unexplained.
  - Peaks were 7407 MB to +400 and 7468 / 7645 MB late in the run, with no jetsam. The game-SC end fired at the step
    (7063 / 7170 MB). 0155/0239 were not exercised.
- **Measured (l19, 2026-10-30, IPA `5db127bd…`, HEAD `9d00208`;
  [evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md)):** log-only diagnostics for PLA-364 (mesa 0131
  `[kk-cmd-census]`/`[kk-upload]`, madeira-unix 0240–0242), installed in place. HK first-frame+10 passed
  (`20261030T215237-hk-p476l19`). l12's keys, `arm15.sh` (`…/20261030T215326-rdr2-p476l19`).
  - The game signed in and Story was pressed. A heavy scene (I: the cabin) ran 42 s at 17–20 fps. The game then
    stayed on a black spinner to the end, after `re-sign-in after end: no headroom (7585 MB), restart stays
    refused` (0155; l17/l18 had no re-sign-in). Peak 7631 MB, no jetsam.
  - KosmicKrisp's command memory at the step is held by about 1000–1660 ONE_TIME primaries, submitted once
    (1018 MiB upload, mostly tessellation scratch rounded 1.7×). Allocators keep 751 MiB nothing resets. Reusable
    primaries hold under 1 MiB, so the design's 2A would free nothing.
  - Audio: slot 1 delivered 44–47 % in the scene, every callback short. ReleaseBuffer gaps stayed ≤ 40 ms (no
    stall). RAGE asks TIME_CRITICAL for 17 threads, the main thread among them.
  - `[xp]` sys share 18–19 % → 20.5–21 % at the step: no kernel-time jump.
  - Recommendations (KosmicKrisp retire-serial release of ONE_TIME holds; audio Option A gated on the GetBuffer
    caller) wait for decisions; see the evidence.
- **Owner decisions 2026-10-30 after l19, built, not yet on the phone** (`211070e`, `6bae711`, and the
  decision commit; dev IPA `6b5be569…`, `.work/out/20261030-223218-6b5be569/`, 90 checks):
  - madeira-unix 0243: in Wine's hinted ≥1 GiB retry, the verified helper's 4 GiB-aligned hints try
    `0x7100000000`, `0x7200000000`, `0x7300000000` before the kernel's pick (`[jumbo] cand sc-aligned`;
    option (a) of `.work/agent-notes/pla476/reports/helper-oom.md` §2). l16 B's hole gives `0x7300000000` on
    the host.
  - Under the layout the game's own Social Club helper is not ended: the end is off when never set, a dev
    build's stored switch overrides, release ignores it; 0138's refusal and 0155's watch go with the end
    (`GameSocialClubEndPolicy`). Without the layout the default is unchanged (0153).
  - [Decision 0169](../decisions/0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md) is chunk 5's
    record (amendment notes in 0110, 0133, 0141, 0150, 0153). Chunk 4's implementation (no keys, both
    builds, Playport's CEF removed) is still open.
  - Phone gates next: HK first-frame+10; RDR2 on l12's keys with the game-SC end left unset, to the cabin
    held to first-frame+600, with no game-SC end, no restart refusal, every V8 code range on an aligned base.
- **KosmicKrisp command memory, owner decision 2026-10-30 after l19 (PLA-364), built; phone gate l22–l23 not passed
  (below)**
  (`d64b623`; dev IPA `6f1751c7…`, `.work/out/20261030-230828-6f1751c7/`, 90 checks):
  design 2A (release reusable primaries' holds) is dropped: l19 shows they hold under 1 MiB. The retire path
  is chosen instead: mesa 0132 `MESA_KK_EXPERIMENTAL=cmd_retire` (named only, not in `all`) gives a ONE_TIME
  primary's upload BOs and allocator hold back to its pool when its only commit completes, and resets, seals
  (8 MiB), taints (released uncommitted: destroyed, never reset) or shares allocators at Begin; 0133
  `cmd_bo_classes` adds quarter-octave large-BO classes to 2 MiB. Both are **opt-in**: no game's default changes;
  RDR2 gets them for the gates through its Graphics options row
  (`MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`). Design:
  `.work/agent-notes/pla476/reports/kk-retire-impl.md`; host test `kk-cmd-retire-test.c`. Phone gates next: HK on
  Vulkan with and without the option (first-frame+10 and `pp perf`), then RDR2 on l19's protocol with the option,
  compared with l19's `[kk-cmd-census]`, `[kk-upload]`, `[kk-mem]` and peak.
- **Measured (l22–l23, 2026-10-31, IPA `6f1751c7…` with `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`, against
  l20–l21 on `6b5be569…`; `.work/ui-runs/20261031T002951-rdr2-p476l22`, `…/20261031T003826-rdr2-p476l23`;
  [evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#l22l23-kosmickrisp-cmd_retire-gate)):**
  **not passed.** The option applied and the ONE_TIME buckets hold 0 upload (held upload 1.6–1.8 MiB; command
  BOs at the load step 0.28–0.34 GB, from 0.97–1.0). But allocators grow to 190–252 and **1.2–1.9 GB** in the
  cabin's load step (l20–l21: 45, 0.69–0.77 GB; design 0.1–0.25). Graphics +460–510 MB, peak 7980 / 8084 MB.
  Both runs ended 6–12 s into the step (l22 jetsam per-process-limit; l23 inferred), before the cabin. No GPU fault.
  HK: smoke passed off and on. The gameplay pair has equal fps, −110 MiB and CPU +25 points (guest threads `00fc`
  and `dxvk-cs`, not the completion threads), with one allocator tainted and replaced per frame; a repeat pair is
  needed. The option stays opt-in, with no title default. Bounding allocator growth needs an owner decision.
- **Allocator bound (B2), built; phone gate l24–l25 passed (below)** (dev IPA `d3be12c9…`, `.work/out/20261031-011233-d3be12c9/`,
  90 checks; [cause and fix](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#the-cause-in-the-code-and-mesa-01340135-after-l23)):
  a Metal reset keeps an allocator's heaps, so 0132's sealed allocators re-sealed after each reset and were never
  destroyed; HK's taint was DXVK's spare ONE_TIME buffer, begun in Metal though empty. mesa 0134 (still only with
  `cmd_retire`) begins Metal at the first encoder, destroys idle sealed allocators, keeps four idle and caps a pool at
  eight; 0135 logs `[kk-mem]` within a second (census every 5 s) while command memory grows. Phone gates next: RDR2
  l24 on `arm20.sh` with the option, as l22; an interleaved HK gameplay pair off, on, off, on (window 85:120).
- **Measured (l24–l25, 2026-10-31, IPA `d3be12c9…` with `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`, against
  l20–l21; `.work/ui-runs/20261031T041043-rdr2-p476l24`, `…/20261031T042918-rdr2-p476l25`, `.work/perf/kkb2-hk-*`;
  [evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#l24-kosmickrisp-cmd_retire-with-the-allocator-bound)):**
  both RDR2 runs held the cabin to first-frame+600, peak **7175 / 7250 MB** against 7960 / 8006 (about 0.7–0.8 GB
  more headroom), no jetsam, no `commit done error`; fps within the l20–l21 spread. Allocators capped at 112
  (`pool-max=8`, `over-cap=0`, taints 0) but still about 0.9 GB; the saving is command BOs (81 against 867–888 MiB,
  held upload 69–74 against 848) and rounding (×1.23 against ×1.69). The 5 s census did not run. HK: smoke passed,
  interleaved pairs equal in fps, tail and CPU, `tainted=0`. The option stays opt-in; making it RDR2's per-title
  default needs an owner decision or amendment.
- **Measured (l20–l21, 2026-10-30, IPA `6b5be569…`, `.work/ui-runs/20261030T225818-rdr2-p476l20`,
  `…/20261030T231556-rdr2-p476l21`; [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l20l21-decision-0169-gate)):**
  decision 0169's gate **passed** in both runs. HK first-frame+10 passed (`20261030T225730-hk-p476l20`, +11.33 s).
  `arm20.sh` (l15's keys without the two stored SC switches). Each run logs the 0169 line once; no game-SC end, no
  0138 refusal, no third helper. B lived through Story (≈315 MiB). The cabin held to first-frame+600 (l21 to
  ≈ff+680 by its tail shot after a PLA-540 link drop) at 16–18 fps. Every V8 code range landed on `0x7100000000`
  (l21's B through 0243's `sc-aligned` candidate after the plain ladder failed); helpers 0 `NO GAP FITS`, no
  helper OOM, no re-sign-in, no jetsam. **Headroom is thin:** peak 7960 / 8006 MB of 8192 (l17–l19 had 560–730 MB
  more), since nothing ends B; the KosmicKrisp retire path is the planned offset.
- **Audio, owner decision 2026-10-30 (PLA-364), built; phone gate run 2026-10-31 (below)**
  ([decision 0172](../decisions/0172-audio-producer-runs-real-time-in-its-own-work-interval.md); dev IPA
  `58432f76…`, `.work/out/20261030-235112-58432f76/`, 90 checks, on top of mesa 0132–0133 (opt-in), so it
  serves the KosmicKrisp gates too): madeira-unix 0244 (`getbuf-producer`, ml1065 `caller_switches=`/`producer=`,
  dev only), 0245 (the steady GetBuffer caller of a started stream gets a time-constraint policy and its own work
  interval, CPU guard, `env.MADEIRA_AUDIO_RT=0`), 0246 (C1, `env.MADEIRA_AUDIO_REFILL=0`); every WASAPI title.
  Phone gates next: HK `pp perf` and RDR2's heavy scene with both off against both on, The Witcher 3 `pp perf`.
- **Measured (audio gate, 2026-10-31, IPA `58432f76…`, `.work/ui-runs/20261031T020806-rdr2-p476aud-off`,
  `…/20261031T022731-rdr2-p476aud-on`, `.work/perf/hk-aud-{off1,on1,on2,off2}`;
  [evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#audio-gate-decision-0172)):** HK smoke passed;
  HK's gameplay perf shows no fps or tail change, FMOD's `00f8` promoted, slot 0 at 99–100 % both ways. RDR2's
  heavy scene: slot 1 at **96.9 %** on against 41.4 % off (mean of 10 s windows), steady producer `0428`, no
  `rt refused`, `cycle_errors` 0, fps −4.1 % (on started at thermal serious), peak 7863 / 7787 MB, no jetsam. 9 of
  22 windows dip below 95 % (min 66 %), each with a 0.3–1.5 s whole-process stall. The Witcher 3 not run (not in
  the phone's library). No listening test.
- **Chunk-2 gates after l19:**

  | Gate | l7 | l8 | l9 | l10 | l11 | l12 | l13 | l14 | l15 | l16 | l17 | l18 | l19 |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | HK first-frame+10 | passed | passed | passed | passed | passed | passed | not run (HK `pp perf` ran) | not run (HK `pp perf` ran) | passed (+11.78 s) | not run (same session as l15) | not run (installed IPA, HK passed in l15) | not run | passed (+10.44 s) |
  | The game's helper reaches allocator/browser startup | passed | **not passed** (kind 2 not held again; no grant, refused, died in init) | passed (kinds 1–6, no refusal) | passed (kinds 1–6, no refusal) | passed (kinds 1–6, no refusal) | passed (kinds 1–6, no refusal) | passed | passed | not reached (no sign-in) | passed (kinds 1–6), then died: V8 code range | passed (kinds 1–6) | passed (kinds 1–6) | passed (kinds 1–6) |
  | The game signs in, Story is pressed | passed | passed | passed | passed | passed | passed (GPU off) | passed | passed | **not passed** (the launcher's helper died) | signs in; **Story not pressed** | passed | passed | passed |
  | Story reaches the cabin | **not passed** (jetsam at 8192 MB) | **not passed** (black loading screen without the game's Social Club) | **not passed** (jetsam at 8192 MB in the load step) | **not passed** (8185 MB in the load step, then the app ended) | **not passed** (8169 MB in the load step, then SIGKILL) | **passed** (peak 7200 MB, held to first-frame+600) | **passed** (cabin, then the app was killed at +374 s: 0155 restarts) | **passed** (peak 7058 MB, held to first-frame+600) | **not passed** | **not passed** (spinner) | **passed** (held to first-frame+600) | **passed** (held to `[xp]` +717) | reached (I), **not held** (42 s, then a black spinner after 0155 refused a re-sign-in) |
  | No SC/launcher `NO GAP FITS` or soft grant | **not passed** (26 V8 lines each from A and B, 36 `dllhost.exe`) | **not passed** (26 V8 lines from A; 0 `dllhost.exe`; no soft grant) | **not passed** (26 V8 lines each from A and B; 0 `dllhost.exe`; no soft grant) | **not passed** (26 V8 lines each from A and B; 0 `dllhost.exe`; no soft grant) | **not passed** (26 V8 lines each from A and B; 0 `dllhost.exe`; no soft grant) | **not passed** (26 V8 lines each from A and B; 0 `dllhost.exe`; no soft grant) | **not passed** (103 lines) | **not passed** (53 lines) | A: 0 (26 refused); no soft grant | A: 0 (26 refused); B: 4 (V8's code-range fallback, `0x140000000`) | **passed** (A 0, B 0; 26 refused each) | **passed** (A 0, B 0; 26 refused each) | **passed** (A 0, B 0) |
  | Peak within 7343 MB ±10 % | **not passed** (8192 MB limit) | **not comparable** (6496 MB, no Story step) | **not passed** (≥ 8106 MB, the limit) | **not passed** (8185 MB) | **not passed** (8169 MB) | **passed** (7200 MB) | **passed** by the band (7627 MB after the 0155 restarts, then the app was killed; 6885–7010 at the step) | **passed** (7058 MB) | not comparable (5564 MB, no Story) | not comparable (5737 MB, no Story) | **passed** (7407 MB to +400, 7468 MB at +769) | **passed** (7407 MB to +400, 7645 MB at +669) | **passed** (7631 MB) |

- **Ordered queue now (after l16):** first, find why l15's launcher helper and l16's game helper died in Chromium's
  out-of-memory exit. The V8 1 GiB code range's placement is a candidate (`[jumbo] cand plain`/`guard` by the hint's
  offset, and the window's state). Then repeat to Story on one IPA, with no hand play before it. The queue as it stood
  after l14:
- **Ordered queue after l14:** (1) done in `2df65fe` (slots held in place); (2) Story's load with the game's own Social
  Club running is under the limit in l12 and l14 (7200, 7058 MB); l13 was killed at +374 s after 0155 allowed Social
  Club restarts (7627 MB): the allow path needs a look before Story is called safe. The early-stop case is still
  untested (both repeats stopped late). Open on the way:
  - the 64 MiB cap's cost in the Social Club helpers (24 and 13 rolls); the HK hitch comparison with the HUD on is
    done (above: 25–50 ms hitches +21 %, nothing worse);
  - which libraries B still loads with GPU off.

  Then the V8 probes (the last `NO GAP FITS` gate); (3) chunks 3–6,
  all under PLA-476. Chunk 5's decision is now partly covered by
  [0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md) (the retention part of the layout);
  the rest of chunk 5 stays. 0.5.0 held.
- Phone: no session active. Reports: `.work/agent-notes/pla476/reports/`.

## Why

The 0.5.0 release IPA (`e21a5af8`, from `a124f27`) cannot start Red Dead Redemption 2. Dev IPAs
could. The only difference on that path is Playport's CEF 143.0.14 build
([0110](../decisions/0110-own-cef-build-for-a-clients-cef.md)). Its payload ships in the dev IPA
only (`stage-artifacts.py`, `pp verify --variant release`), because PLA-372 has not been done.

The owner's release run on 2026-10-29 (`.work/rdr2-release-log/playport.log`):

- `[cef-swap] Playport's CEF 143.0.14 is not in this build … every client's CEF is left alone`.
- Rockstar's `libcef.dll` (`0xefbe000`, align `0x1000`) is loaded. The helper's browser asks for
  32 GB reservations, which dev runs never made: there, three 2 GB reservations came from Playport's
  low-VA build.
- `NO GAP FITS size=0x800010000`. The soft-pool fallback "grants" `0x7400000000 +32 GB` and then
  releases it (`[bigres-free] 0x7400000000 +32768MB`). That range held 32 MB of live
  `Launcher.exe` memory.
- The launcher writes into the released range in `vk_common_CreateComputePipelines`
  (`[store-noalias] … NO pool/anon alias`). It exits `-536870904` (`0xE0000008`), and
  PlayRDR2.exe shows "Unable to launch game".

Shipping Playport's CEF build needs PLA-372's source and relinking work, a 4–8 h rebuild for each
Social Club CEF update, and a Chromium with no security fixes. The owner's decision (2026-10-29):
drop it, and run Rockstar's own CEF the way willfaust/Madeira does.

## Scope (owner, 2026-10-29)

**In.**
- Social Club's helper on Rockstar's own CEF, as willfaust/Madeira runs it:
  - single-process with the page bridge: madeira-unix 0190, decision
    [0150](../decisions/0150-dev-single-process-social-club.md), today dev-only and off;
  - the address-space room its PartitionAlloc pools need.
- Removing Playport's CEF build entirely.
- Holding 0.5.0 until a release build signs in and plays.

**Unchanged.** Every other Social Club and launcher policy:
- the launcher's end at the game's sign-in or near the limit (0124, 0130, 0140);
- the game's Social Club end and restart refusal (0133, 0138, 0141), except that under the layout the end
  is off (owner, 2026-10-30, after l19; decision 0169);
- the crash-reporter block (`PLAYPORT_SC_BLOCK_CRASHPAD`);
- the Chromium switches (0109, 0111, 0114);
- 0153's defaults: services, the 896 MiB pool, the Khronos loader, the Steam client,
  `jumbo-mb=8960`.

**Out.**
- Any Madeira knob beyond what this needs.
- Any patch to Rockstar code other than 0150's page bridge. 0150's guard stays: the exact helper
  build, the 48 SHA-256 ranges, and a multi-process fallback on mismatch.

## What upstream does that Playport's port left out

0190 ported upstream's `0f40502`/`fcfb69a`/`293cd39` single-process and page-bridge code. It left
out what upstream relies on for a *stock* CEF
([evidence](../evidence/2026-10-20-sc-single-process.md#left-out-of-the-port-and-why)), because
0110's build made it unnecessary:

1. **PartitionAlloc room** (`env.MADEIRA_SC_PA_POOLS = 1|2`, `virtual_ios.c`). `chrome_elf.dll`
   reserves its core pools as 32 GB on a 32 GB boundary.
   - Layout 1 moves FEX's arena to `0x7d00000000` (12 GB) and keeps `0x7c00000000 +4 GB` free, so
     the reservation lands at `0x7800000000`.
   - Layout 2 also places libcef's pools, its metadata and Oilpan's cage. It moves the JIT pool's
     RW alias to `0x7900000000`.
   - `MADEIRA_RDR2_VA_HOLD` (layout 2 only) holds `[0x75d0000000, 0x7800000000)` from boot for
     RDR2.exe's 8960 MB reservation.
   - Upstream's RDR2 list runs layout 2 with the hold.
2. **No libcef in the game.** A process with `socialclub.dll` that is not the helper gets no
   JIT-pool copy of `libcef.dll`, so its load fails (`ios_sc_cef_refuse`; `MADEIRA_SC_GAME_CEF = 1`
   keeps it). The game's overlay then runs only in the helper.
3. **On by default.** `MADEIRA_SC_CEF` defaults to 1. The single-process run is not opt-in.

At plan opening, none of the single-process A/B runs (scA1, x3, x4, xs1) had run Rockstar's CEF:
every one had `[cef-swap] … matches`. The a2 and l1–l4 probes below now exercise stock CEF; their
results do not yet satisfy chunk 2.

The soft-pool fallback releasing a range other processes still use
([audit](2026-10-06-madeira-audit.md), the `[soft-pool] GRANTED soft` topic) is a separate
runtime bug: [PLA-477](https://linear.app/playportdev/issue/PLA-477). This plan only stops Social Club from reaching it.

## Chunks

Each chunk is committed once its checks pass (AGENTS.md). Phone gates run in the main checkout. Every
runtime change gets a Hollow Knight first frame+10 (`app-367520`).

### 0. Bookkeeping (no build)

**Done 2026-10-29:** PLA-477 filed (the soft-pool bug); PLA-364 and PLA-475 commented, 0.5.0 held.

### 1. Dev probe: single-process on Rockstar's CEF, nothing else changed

- **Goal.** See how far 0190 gets with stock CEF before porting anything else.
- **Change.** A dev-only runtime key, `env.PLAYPORT_CEF_SWAP=0`, that makes
  `playport_cef_swap_path` return NULL. It is removed with the swap in chunk 4.
- **Runs.** Two RDR2 Plays on one dev IPA, with RDR2's defaults and Story via `landing.py`, as xs1:
  - **a1:** `env.PLAYPORT_CEF_SWAP=0` alone (reproduces the release failure in dev; expected
    "Unable to launch game");
  - **a2:** `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1`.
- **Read.**
  - the `[sc-single]`/`[sc-rph]` counts (the table in the 0150 evidence);
  - every `[jumbo#]`, `NO GAP FITS`, `[soft-pool]` and `[bigres-free]` line from a
    `SocialClubHelper.exe` or `Launcher.exe` PEB;
  - whether the launcher's page loads and whether the game signs in;
  - the footprint peak.
- **Outcome.** Evidence record `docs/evidence/2026-10-2x-sc-stock-cef-probe.md`, and the decision
  for chunk 2:
  - If a2 signs in with no `NO GAP FITS` and no soft-pool grant, chunk 2 shrinks to a guard
    (fail a ≥16 GB reservation from a Social Club PEB instead of soft-granting it).
  - Otherwise port the layout.

### 2. PartitionAlloc room for Rockstar's CEF (likely the hard chunk)

**Implementation progress:** madeira-unix 0224 introduces a pure geometry and request-classification
header, with host tests in `tools/tests/test_sc_layout.py`. It allocates nothing and is not yet
connected to the runtime. Tests cover disjoint real ranges, the 8960 MiB game hold, the 15 GiB FEX
arena, overflow-safe bounds, reservation ordering and refusal to give one helper another helper's
remaining slots. madeira-unix 0225 adds the boot holds (all-or-nothing, only with the host's ownership marker and the
RW alias at `0x7900000000`) and 0226 routes the verified helper's reservations into the slots:
chrome_elf.dll's and libcef.dll's PartitionAlloc pools, their metadata, Oilpan's cage and V8's 8 GB
sandbox step (`NtAllocateVirtualMemoryEx`). Any other reservation of 16 GB or more from the helper
fails instead of reaching the soft-pool grant. Commits, protects and frees inside a slot's real range
are allowed only for its owner. A grant is released whole, by its owner or at its owner's exit through
the existing process teardown, and the slot is held again. The helper is told a 2 TB
`HighestUserAddress` (report only) so V8 takes its partial sandbox.

**Accepted bounded startup increment:** wine-pe 0055 replays already-loaded images through ntdll's existing
guarded notification after successful emulator initialisation, bypassing ImageTracker's exclusive code-lock
path. In l3, `kernel32.dll!LoadLibraryExW` (`+0x365e0`) was never registered in the helper's FEX tracker;
the decoder's NOEXEC trampoline caused the reported NULL read. `tools/tests/test_arm64ec_early_images.py`
covers early dependencies, main/ntdll/queued maps, duplicates and failed init. `test_sc_layout.py` also locks
down the existing refusal to reclaim kept or foreign views. Full `pp test` and the dev build passed (IPA
`3fd1145d`, 90 verification checks). On that exact IPA, l4 passes HK first-frame+10 and positively shows the game's
helper (PID `0528`, PEB `0x701af34000`, tracker `0x11a5b4d80`) registering kernel32 intervals covering
`0x73fba465e0`, advancing through TLS into allocator startup, then receiving five metadata refusals and a
guest `0x80000003` breakpoint. No NOEXEC remains. These two bounded startup gates are accepted; this does **not** accept allocator/browser startup or overall chunk 2.

**Slot reuse is blocked, not fixed:** l3's parked tid `0204` waits at `0x740007c3e0` inside the retained metadata
view; l2's tid `0208` waits at `0x74000483e0`; l4 again retains kind 3 with parked tid `0204` waiting at
`0x740002c3e0` inside its real metadata view. Decisions 0132/0143 keep the whole view unchanged, even after its
process exits and teardown takes its view ownership for the runtime. Clearing the slot ledger or overwriting
that range would violate the retention rule. No retention, termination, sign-in or launcher policy was changed;
no alternate geometry was selected. The [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#host-follow-up-early-images-and-the-retained-slot-blocker)
records the design constraints. The overall cabin/7343 MB ±10% gate remains **not passed**.

The host (`wine_host.c`) holds `[0x7000000000, +1.5 GiB)` from exec. In a2's log iOS had already put
a 74 MiB tag-87 region at `0x7000000000` by pool time, so a hold taken then can never get the
address. A layout play keeps the bottom 256 MiB; every other play gets the JIT RW alias mapped fixed
at `0x7000000000`, where Madeira put it and where ntdll's floor formula expects it. This changes every
game's placement slightly (the alias was at `0x7007130000` before), so the Hollow Knight gate covers it.

Opt-in: runtime key `env.PLAYPORT_SC_LAYOUT=1` (with `env.PLAYPORT_SC_SINGLE=1`; the probe key
`env.PLAYPORT_CEF_SWAP=0` until chunk 4).

**Established blocker: subsequent helpers.** The slots serve one helper at a time; a second helper is refused
while the first owns them, including when teardown preserves a referenced view. l4's game's helper now reaches
its pools but cannot acquire metadata; later restarts are refused by existing 0138 policy. Moving the launcher's
end or changing restart/retention policy is not authorised by the startup acceptance. No safe replacement
geometry is established. Reported Chromium ranges overlap intentionally; only owned **real** ranges may be
committed or released. Upstream's diagnostic-only overflow warnings are not sufficient ownership enforcement
for this port.

- Port upstream's layout from `0f40502` (and `e50981f` for the RDR2 hold) as madeira-unix patches,
  each with `Class:`, `Evidence:` and `Offered-upstream:` trailers.
- **It cannot be copied as is.** Playport's map is not upstream's:
  - madeira-unix 0083–0085 removed the CEF-only placement code;
  - the jumbo holdback (`jumbo-mb`, 0126);
  - the donor pool (0153);
  - short reservations (0222);
  - the audit's T10 constants (`0x73ffff0000`, `ios_spill_cap`, `ios_is_arena_addr`).
- Start from the probe's actual reservation list and use the least layout that fits it:
  layout 1 if `chrome_elf`'s 32 GB pool is the only one; layout 2 only for what a2 shows.
- **Keep these out of it:**
  - Hollow Knight and every non-Social-Club title: the layout applies only to a Play whose launcher
    is `PublisherLauncher.rockstar`, or only from the first `SocialClubHelper.exe`, whichever the
    probe shows is enough;
  - RDR2.exe's 8960 MB reservation, held today by `jumbo-mb=8960`, which must still be granted.
- **Host tests.** Port upstream's `check-pool-placement` and `check-sc-grant-growth` to
  `tools/tests`, against Playport's constants.
- **Phone.** HK first frame+10; RDR2 a2 again. The gate: the game signs in, Story reaches the
  cabin, there is no `NO GAP FITS` or soft-pool grant from a Social Club or launcher PEB, and the
  peak is within xs1's 7343 MB ± 10 %.

### 3. The game's libcef (only if chunk 1/2 shows it)

The xs1 log shows `libcef.dll` mapped in the game's process too (with Playport's build). If on
stock CEF the game's own load reserves pools that do not fit, port `ios_sc_cef_refuse`. **Ask the
owner first:** it is a refused DLL load in the game, and 0150 excluded it. Otherwise skip.

**Skipped:** since l7 the game's helper takes its own slots (kinds 1–6), so no refusal is needed.

### 4. Single-process in both builds; remove Playport's CEF

**Built 2026-10-31** (PLA-602, PLA-603; Status above). As built, the layout and single-process come from
`PublisherLauncher.rockstar`'s runtime keys, so every Rockstar Play runs them and no other title does.

- **0190's gate.** `playport_sc_single_enabled` is on by default and in release:
  - `PLAYPORT_SC_SINGLE=0` turns it off (dev runtime key);
  - `app/tests/sc_single_test.c` is changed to match (the release gate test becomes a default-on
    test);
  - the exact-build guard and the multi-process fallback stay.
- **Remove:**
  - `patches/wine-unix/0039` and its series entry;
  - `app/Sources/WineHost/cef_swap.c` and `include/cef_swap.h`;
  - `app/tests/cef_swap_test.c`;
  - `app/Sources/S1Probe/Runtime/cef/`, and the `Runtime/cef` line in `app/xtool.yml`;
  - `build/cef/` and `build/pipeline`'s `stage-payload.py` call;
  - `stage-artifacts.py`'s CEF line;
  - `patches/cef/` and `patches/chromium/`;
  - the `cef` and `chromium` rows in `pins.lock`;
  - the CEF parts of `pp sync`, `pp source`, notices and `verify-ipa.py` (keep a check that fails
    *any* IPA carrying a CEF payload);
  - the chunk-1 key.
- **Keep:**
  - the `[chromium]` switch code (0109, 0111, 0114): it serves Rockstar's CEF too;
  - the PLA-447 heuristic.
- **After it.**
  - `pp test`, `pp names`, `pp secrets`, `pp build` (dev) and `pp build --variant release`, then
    `pp verify` on both.
  - Commit the changed build records.
  - Delete `.work/cef-src` only after chunk 6 passes, and ask first: it is 150–200 GB and the only
    rebuild route.
- **Linear.** Cancel PLA-372 and PLA-382 with a pointer here. Update PLA-426's CEF part.

### 5. Decision record

**Recorded** as [0169](../decisions/0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md) (owner,
2026-10-30), with the code-range placement rule (0243) and no end of the game's helper under the layout.
**Done 2026-10-31** (PLA-604): the doc updates that depended on chunk 4's removal. `LICENSING.md`, `NOTICES.md`
and `DISTRIBUTION.md` name no CEF payload; `BUILDING.md` names `pp verify`'s `cef` check.

A new decision (next free number; 0166 is the last). The retention of a launcher helper's slot view is already
decided by [0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md). It:
- supersedes 0110;
- amends 0150: on by default, in release; the page-bridge exception unchanged;
- amends 0153: what RDR2 runs with in both builds, and the layout from chunk 2;
- records the every-play low hold at `0x7000000000` (+1.5 GiB from exec) and the fixed JIT RW alias there
  ([PLA-480](https://linear.app/playportdev/issue/PLA-480));
- records the helper's impossible-probe refusal (owner, 2026-10-30; madeira-unix 0236). `ppsc_route` refuses
  an unhinted reserve from the verified helper with `STATUS_NO_MEMORY` before any map walk, at both entry
  points and with the same guards, when either holds:
  - (a) it is larger than `PPSC_CEILING − PPSC_FLOOR`;
  - (b) it is 8 GiB or more and the helper already owns kind 6.

  These are V8's sandbox ladder and gin's pool tries, 26 `NO GAP FITS` walks per helper in l10–l12. The
  first two refusals per PEB are logged, and the kind-6 owner-exit line counts them all.

Update `docs/decisions/README.md`, `ARCHITECTURE.md`, `BUILDING.md`, `LICENSING.md`, `NOTICES.md`
and `DISTRIBUTION.md` where they name the CEF payload, and `docs/plans/finished.md` /
`docs/plans/README.md`.

### 6. Gates, then 0.5.0

- **Dev IPA.** HK first frame+10. Three RDR2 runs to Story +60 s (sign-in time, peak, jetsam, the
  `[sc-single]` counts). Compare with xs1 and d2–d5.
- **Release IPA.** `pp build --variant release`; the owner installs it and plays RDR2 to Story
  (decision 0068: no automated release tests). Pull `playport.log` afterwards for the same lines.
- **Records.**
  - evidence record with both IPAs' sha256;
  - PLA-364 **Status:**/**Best known:**;
  - `site/compatibility/games.json` if the status changes;
  - re-read `docs/releases/0.5.0.md`'s RDR2 section (it names Playport's CEF nowhere, but check the
    memory and sign-in numbers).
- **Then.** Rebuild the release draft from the new HEAD (`pp release 0.5.0`) for the owner's
  sign-off (PLA-475).

## Risks

- **Rockstar's CEF single-process may not fit even with the layout.** Upstream's GTA V and RDR2
  runs used a different pool layout (pool-split/mid/low), swap images and other settings Playport
  lacks.
  - If chunk 2 cannot place the pools, stop and report. Keeping Playport's CEF in release (PLA-372)
    is then the fallback, and that is the owner's call.
- **Single-process merges fault domains.** x4 (single-process with the game's helper alive) was
  jetsammed at 8120 MB. The game's Social Club end (0133/0141) is what kept xs1 under the limit. Under the
  layout it is now off (0169): l12's and l14's step began at 5,640–5,870 MB, but the cabin's margin with the helper
  alive is not yet measured.
- **xs1's black spinner after the helper's end** (one run). The defaults never showed it, so chunk 6
  needs three runs, not one.
- **A Social Club update** changes the helper's hashes. 0190 then falls back to multi-process, which
  on stock CEF fails as release does today. Today a CEF update breaks the swap the same way, so this
  is no regression, but it should be visible: the fallback line goes into the launch message's log
  reason.
