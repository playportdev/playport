# Kingdom Come at medium spec: the video memory figure and the render resolution

**Date:** 2026-10-15 (10:50–12:56). **Branch:** `research/extended-memory`.
**Linear:** [PLA-355](https://linear.app/playportdev/issue/PLA-355) (the memory settings),
[PLA-216](https://linear.app/playportdev/issue/PLA-216) (donor pool),
[PLA-352](https://linear.app/playportdev/issue/PLA-352) (the memory plan); the title is PLA-49
(Kingdom Come: Deliverance, app-379430).
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md). Follows
[the low-spec runs](2026-10-15-memory-ceiling-vram.md) (`940d2a9`).

The owner asked whether Kingdom Come uses more graphics memory when told it has more video
memory, now with its in-game graphics at **medium** instead of low, first at Playport's 720 and
then at the highest resolution the app offers.

## Setup

- iPhone18,4 (2736×1260 panel), iOS 27.0.1, 11,734 MiB of RAM, on the charger at 80 % all
  session, unattended mode on.
- Dev IPA SHA256 `efd4f8e653f397169ed80c68608ad66a5c548ef8adbecc09e8ada7ec43fe42de`
  (commit `4e3ea9e`), already installed. Nothing was built or changed for this measurement.
- Sessions: `vram-medium-session.sh` (phases A and B), `vram-medium-readcfg.sh` and
  `vram-medium-menu-native.sh`, each run as one `pp phone lock`. Logs and runs are under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/` (`vram-medium/`).
- **Every run:** pool `set:donorPoolMB=auto` (4,096 MiB granted), guest RAM 8,192 (the default),
  `pp perf --no-hud --secs 600 --cool 10 --cool-max 20 --syslog-all`, a 60 FPS limit, the video
  figure through the title's Runtime keys (`"runtime":"vram-mb=N"`), and the earlier KCD flow:
  wait-text menu, the `--highlight-above` Continue check, `kcd-continue`, `kcd-walk`; shots at
  first frame +300 and +590 s. Every counted run read Continue and walked in Rattay. No save was
  made and no in-game setting was changed by the session.
- **Resolution.** Playport's `screen` values are `native`, 1080, 900, 720 and 540
  (`LaunchSettings.screenPresets`). Phase A used 720 (desktop 1564×720), phase B `native`
  (desktop 2736×1260), the highest.
- **KCD's settings** (`attributes.xml`, read before and after each phase):
  - Phase A: every `sys_spec_*` 2 (medium), `wh_r_HDTextures` false, `res_x`/`res_y`
    1564×720, `res_fs` 1, `res_quality` 2.
  - Before phase B's counted runs the owner set KCD's display to fullscreen at native
    in the game. The file then read `res_x`/`res_y` 2736×1260 and `gamma` 0 (was −1); `res_fs`
    stayed 1, and every `sys_spec_*` stayed 2 with HD textures off. It was the same after B.

## What was lost

- **A2** (`vram-mb=3072` at 720) was cut by a power outage before KCD started;
  `vram-medium/a2-3072-720*` is a dead partial. The owner skipped it.
- **The first B1** (`vram-medium/b1-3072-native*`) is a dead partial. KCD's profile still
  asked 1564×720 under the 2736×1260 desktop: the menu shot shows a smaller, centred picture
  with black bars at both sides. The Continue check found no Continue there, so the session pressed
  nothing, and the run was stopped. After the owner's fullscreen-at-native change, one look at
  the menu at native (`menu-native`, nothing pressed but the wait-text's intro skips) passed the
  unchanged Continue check, so the counted runs are `b1f-3072-native` and `b2f-1536-native`.

## The render size

- `kcd.log` prints only KCD's first window: "Creating window … (1042x586)" at 720 in every
  earlier run, low and medium, and "(1280x720)" at native.
- The host log shows that this is not what KCD rendered. A few seconds later the game window
  (`hwnd=0x60044`) is resized to the full desktop and Playport shows it whole:
  - `[win-pos] … vis={0,0,1564,720}` and `[guest-window] hwnd=0x60044 shown: 1564x720 at (0,0)` in every
    720 run, low (r1, r3, r4, r5) and medium (A0, A1);
  - `shown: 2736x1260 at (0,0)` in B1 and B2.
  - The menu and play screenshots of those runs fill the screen with no bars.
- So the earlier runs rendered at **1564×720** and phase B at **2736×1260**, 3.06 times the pixels.
  The 1042×586 figure in `kcd.log` is only the first window's size.

## Results

Graphics ledger and phys are the `[footprint]` census lines after +60 s (MB); pool figures are
its stats lines (MiB). Kernel available is `memorystatus_available_pages` from the device
syslog after the first frame. The syslog capture ended early in this session's runs (A0 +186 s,
A1 +565 s, B1 +185 s, B2 +125 s), so those figures cover only that window.

| Run | Spec | Render | Video (`ml1042` / KCD) | KCD class | Graphics ledger max / last 20 | Peak phys | Pool live / compressed at end | Kernel avail min / median (MiB) | FPS mean / median / p10 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| r1 | low | 1564×720 | 1,536 | 1 | 1,685 / 1,590 | 3,978 | 4,000 / 467 | 1,547 / 1,820 | 24.4 / 17.9 / 14.0 |
| r3 (guest 9,216) | low | 1564×720 | 2,048 | 2 | 1,663 / 1,579 | 4,313 | 4,014 / 724 | 1,373 / 1,637 | 22.3 / 16.1 / 11.6 |
| r4 (guest 9,216) | low | 1564×720 | 3,072 | 2 | 1,784 / 1,650 | 4,203 | 3,930 / 755 | 1,255 / 1,721 | 23.5 / 14.0 / 10.5 |
| r5 (pool off) | low | 1564×720 | 3,072 | 2 | 1,700 / 1,637 | 7,911 | – | 1,331 / 2,344 | 23.3 / 13.4 / 10.5 |
| A0 | medium | 1564×720 | 1,536 | 1 | 1,973 / 1,896 | 4,559 | 4,095 / 1,265 | 1,130 / 2,529 | 23.1 / 16.6 / 13.0 |
| A1 | medium | 1564×720 | 2,048 | 2 | 1,992 / 1,879 | 4,833 | 4,095 / 1,009 | 1,217 / 1,313 | 20.9 / 13.3 / 10.1 |
| B1 | medium | 2736×1260 | 3,072 | 2 | 2,615 / 2,495 | 6,261 | 3,327 / 1,817 | 924 / 1,475 | 20.9 / 10.0 / 8.9 |
| B2 | medium | 2736×1260 | 1,536 | 1 | 2,611 / 2,490 | 6,002 | 3,327 / 1,930 | 1,682 / 2,038 | 19.1 / 10.3 / 8.9 |

- **Effective values.** In every run `ml1042` logged the figure from madeira.cfg `vram-mb`, and
  KCD's log showed it as "Dedicated video memory" with 8,192 MB installed. ml1075 logged
  one query. The memory plan line was `pool_mb=4096 guest_ram_mb=8192 video_mb=N override=vram-mb=N`.
- **`donor-pool: pressure`** (one line a run, growth stopped, floor 1,408):
  - A0 +135 s at level 14 %, A1 +136 s at 12 %;
  - B1 +81 s at 12 %, B2 +78 s at 14 %.
  - At native, growth stopped about 55 s sooner. The pool's live set then peaked at 3,327 MiB,
    not 4,095, and the guest memory it refused (about 50,000 requests a run) went to the app's
    own footprint.
- **Jetsam: none.** No run named the app in a kill line, and every `pp perf` ended `ok` with
  census lines to +607 s. The kernel ended idle processes (`idle-exit`, `long-idle-exit`) and one
  daemon a run over its own high-water mark (A0 `wirelessinsightsd`, A1 `profiled`, B1 `dasd`;
  none in B2). No per-process-limit kill.
- **Thermal:** nominal → fair → serious in all four medium runs; max pressure 10 (A0) and 20
  (A1, B1, B2). The FPS figures cover the whole run, about 90 s of menu and load included.
- **Screenshots** (in the run directories, not published): all show Henry in Rattay in
  daylight with the HUD. A0 +300 is the churchyard wall and the church, A1 +590 the square by
  the church. B1 +300 is the timber-framed house with the bull sign, and B1 +590 the street of
  thatched and shingled houses with townsfolk. B2 +300 is the wooden platform and the stairs by
  the square, and B2 +590 faces a timber wall up close.
  - The native shots are visibly sharper at distance (shingles, smoke, far trees) than the 720
    shots. No shot shows corruption, missing textures or a difference between the two video
    figures.

## Verdict

- **Kingdom Come does not use more graphics memory when told it has more video memory, at medium as at
  low.**
  - At 720: 1,536 against 2,048 is a ledger of 1,973 / 1,896 against 1,992 / 1,879.
  - At native: 3,072 against 1,536 is 2,615 / 2,495 against 2,611 / 2,490, within 5 MB.
  - The only effect is the machine class: 1 at 1,536, 2 at 2,048 and over.
  - B1 and B2 differ by far less than 150 MB, so no 2,048 run at native was made.
- **Medium costs about 250–300 MB of graphics memory more than low** at 1564×720: a ledger of
  1,973 / 1,896 against r1's 1,685 / 1,590.
- **Resolution costs about 600–640 MB more at medium.** From 1564×720 to 2736×1260, the ledger
  goes from about 1,980 / 1,890 to 2,613 / 2,493. The phone's app footprint peaked at 6.0–6.3 GB
  with the pool, against 4.6–4.8 GB at 720. Median FPS fell from 13–17 to about 10.
- **The phone's free memory was lowest at native with 3,072:** 924 MiB available in B1's first
  +185 s, under the 1,408 floor. This is one run with partial syslog coverage, and B2 (1,536)
  read 1,682 over its shorter window.

## Gap to the 8 GB limit without the pool (estimate)

Neither medium setup was run with the pool off. Two estimates, both **not measured**:

- **The pool-off footprint plus the graphics delta.** Take r5 (pool off, low, 720): a peak of 7,911
  with a ledger of 1,700 / 1,637. Add the graphics growth:
  - **medium at 720:** +273 to +292 (max) or +242 to +259 (last 20), so about **8,150–8,200**,
    at the 8,192 limit;
  - **medium at 2736×1260:** +911 to +915 or +853 to +858, so about **8,760–8,830**, roughly
    **600 MB over the limit**.
- **App plus pool** (peak phys + pool live at the end). For low, r1's 3,978 + 4,000 = 7,978
  matches r5's measured 7,911 within 70.
  - **Medium at 720** gives 8,654 (A0) to 8,928 (A1).
  - **Medium at 2736×1260** gives 9,329 (B2) to 9,588 (B1).
  - By this measure medium adds non-graphics memory too, and the gap is larger: about
    0.5–0.7 GB over the limit at 720 and 1.1–1.4 GB at native.
- **Either way:** without the pool, KCD at medium sits at or past the limit at 720 and well past it
  at the phone's native resolution. With the pool, all four medium runs survived 600 s.

## Recommendation (no default changed)

- **Keep the default video figure, 1,536.** KCD's graphics use follows its spec and resolution, not
  the figure. A higher figure only flips its machine class.
- **Keep Auto pool on for heavy titles at native.**
  - By both estimates KCD at medium/native needs more than 8 GiB without it.
  - At native the pool's growth stop came at +80 s with 3,327 MiB live.
  - The phone's available memory then fell to 924 MiB in one run.
  - So the floor and the reserve are not too strict.
- **If the owner wants either estimate confirmed,** the next run is medium at native with the pool off
  (`set:donorPoolMB=0`, `vram-mb=1536`). It is expected to jetsam, which is itself a result.

## Not shown

- One run per setting, 600 s each; the syslog windows were partial.
- A pool-off run at medium (the gap above is an estimate).
- High or ultra spec, HD textures, 1080 or 900.
- Any phone but the 12 GB reference phone.

## Games

- Kingdom Come: Deliverance (app-379430): **Works.**
  - Four counted 600 s runs at medium in Rattay through Continue, with the Auto pool: at 720 with
    video 1,536 and 2,048, and at native 2736×1260 with 3,072 and 1,536.
  - No crash and no jetsam. FPS median 13–17 at 720 and about 10 at native, thermal serious.
