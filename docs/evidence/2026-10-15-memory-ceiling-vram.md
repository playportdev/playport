# Memory ceiling with the donor pool, and Kingdom Come's video memory figure

**Date:** 2026-10-15 (08:30–10:08). **Branch:** `research/extended-memory`.
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216) (donor pool),
[PLA-355](https://linear.app/playportdev/issue/PLA-355) (the memory settings),
[PLA-352](https://linear.app/playportdev/issue/PLA-352) (the memory plan); the title is PLA-49
(Kingdom Come: Deliverance, app-379430).
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md).

The owner asked two questions:

1. What is the real memory ceiling for a game with the donor pool? Can the guest be told about
   9 GB of RAM?
2. How does Kingdom Come behave when the video memory figure goes from 1,536 to 2,048 and then
   3,072 MiB?

## Setup

- iPhone18,4, iOS 27.0.1, 11,734 MiB of RAM, on the charger (93 → 80 %), unattended mode on.
- Dev IPA SHA256 `efd4f8e653f397169ed80c68608ad66a5c548ef8adbecc09e8ada7ec43fe42de`
  (commit `4e3ea9e`), already installed. Nothing was built or changed for this measurement.
- One locked session, `ceiling-session.sh`. Its log and runs are under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/ceiling/`.
- **Each run:**
  - `pp perf --no-hud --secs 600 --cool 10 --cool-max 20 --syslog-all`, from the first frame;
  - the Continue flow from earlier KCD runs: the wait-text menu, the `--highlight-above`
    Continue check, `kcd-continue`, then `kcd-walk`;
  - screenshots at first frame +300 and +590 s.
  - All five runs read the menu and Continue and walked in Rattay. No save was made.
- **The same launch settings in every run:** screen 720 and a 60 FPS limit. Only two things
  changed between runs:
  - the pool setting: `set:donorPoolMB=auto`, which gives 4,096 MiB on this phone, or `0`;
  - the title's Runtime keys, which became its madeira.cfg keys.
- **How the values were set:** the named per-title path, the game page's Developer › Runtime
  keys (`LaunchSettings.runtime`).
  - `pp perf --settings '{"screen":"720","frameLimit":60,"runtime":"totalphys=9216 vram-mb=2048"}'`
    saves them for that one run, through the UI, as the page does.
  - `TitleConfig` writes them after the title's own keys.
  - The memory plan reads the effective `totalphys` and `vram-mb` and does not override them.
  - No code change and no file push was needed.
- The owner corrected the pool size before the session: Auto, not 6,144. No run used 6,144.

## Effective values (from each run's log)

| Run | `memory plan:` | ml992 / ml993 | ml1042 | KCD's own log |
| --- | --- | --- | --- | --- |
| R1 | `pool_mb=4096 guest_ram_mb=8192 video_mb=1536 override=none` | `MADEIRA_TOTAL_PHYS_MB=8192` | 1536 MB, from the memory plan | 8192 MB installed; dedicated video 1536 MB; machine class 1 |
| R2 | `guest_ram_mb=9216 video_mb=1536 override=totalphys=9216` | `ml993: totalphys -> 9216 MB (madeira.cfg)` | 1536, plan | 9216 MB installed; video 1536; class 1 |
| R3 | `guest_ram_mb=9216 video_mb=2048 override=totalphys=9216,vram-mb=2048` | 9216, madeira.cfg | 2048, madeira.cfg `vram-mb` | 9216; video 2048; **class 2** |
| R4 | `guest_ram_mb=9216 video_mb=3072 override=totalphys=9216,vram-mb=3072` | 9216, madeira.cfg | 3072, madeira.cfg | 9216; video 3072; class 2 |
| R5 | `pool_mb=0 guest_ram_mb=8192 video_mb=3072 override=vram-mb=3072` | 8192, plan | 3072, madeira.cfg | 8192; video 3072; class 2 |

- **Every pool run's Auto line was the same:**
  `donor-pool: auto L_mb=8191 budget_mb=8278 app_part_mb=4096 … target_mb=4096`, then
  `installed granted_mb=4096 objects=16 donors=1`.
  - Only the level at Play differed: 48, 31, 56 and 41 %.
- **KCD read the figures once.** ml1075 logged one query in each run, so the budget never
  moved.
- **KCD sees both figures:**
  - its startup log prints "N MB physical memory installed" and the adapter's "Dedicated video
    memory: N MB";
  - at 2,048 MiB and over, its machine-spec auto-detect rates the phone class 2 instead of 1.
- **KCD's own settings did not change.** `attributes.xml` was read before and after the session
  and is identical. It has every `sys_spec_*` at 1 (low) and HD textures off.
- KCD's `kcd.log` has no texture-streaming or pool line. What machine class 2 changes beyond
  those explicit settings is not visible.

## Results

| | R1 | R2 | R3 | R4 | R5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pool / guest RAM / video (MiB) | Auto 4096 / 8192 / 1536 | Auto / **9216** / 1536 | Auto / 9216 / **2048** | Auto / 9216 / **3072** | **off** / 8192 / **3072** |
| Peak `fpMB` (at) | 3,998 (+610 s) | 4,256 (+522) | 4,341 (+603) | 4,201 (+474) | **7,931** (+593) |
| `fpMB` at +300 / +590 | 3,740 / 3,874 | 4,053 / 4,135 | 4,194 / 4,297 | 3,910 / 4,042 | 7,815 / 7,814 |
| Graphics ledger, max / last 20 (MB) | 1,685 / 1,590 | 1,691 / 1,622 | 1,663 / 1,579 | 1,784 / 1,650 | 1,700 / 1,637 |
| App `internal` / `compressed`, last 20 (MB) | 4,948 / 1,337 | 4,654 / 1,623 | 5,137 / 1,532 | 4,658 / 1,661 | 4,512 / 1,887 |
| Pool live, max / at end (MiB) | 4,000 / 4,000 | 3,754 / 3,754 | 4,014 / 4,014 | 3,930 / 3,930 | – |
| Pool resident / compressed at end (MiB) | 3,371 / 467 | 2,965 / 636 | 3,126 / 724 | 2,999 / 755 | – |
| Pool granted / refused (all while growth was stopped) | 4096 / 54,219 | 4096 / 44,868 | 4096 / 51,588 | 4096 / 55,358 | – |
| `donor-pool: pressure` growth stop | +145 s, level 14 % | +129 s, 14 % | +149 s, 14 % | +167 s, 13 % | – |
| Kernel available, 0–600 s, min / median (MiB) | 1,547 / 1,820 | **1,137** / 2,335 (after +120 s: median 1,393) | 1,373 / 1,637 | 1,255 / 1,721 | 1,331 / 2,344 |
| KCD jetsam | none | none | none | none | **none** |
| Other kills (besides idle `long-idle-exit`, 83–192 per run) | – | highwater 2, per-process-limit 1 (`appinstallationmetricsd`) | highwater 2 (`callhistoryd`) | highwater 2, per-process-limit 1 (`musicd`) | highwater 1 |
| FPS mean / median / p10 | 24.4 / 17.9 / 14.0 | 24.6 / 17.8 / 13.4 | 22.3 / 16.1 / 11.6 | 23.5 / 14.0 / 10.5 | 23.3 / 13.4 / 10.5 |
| Thermal | nominal → fair → serious | same | same | same | same |

- **Footprint per class.** The figures come from the `[footprint]` census lines after
  +60 s: `phys`, `internal`, `compressed` and the graphics ledger. The pool's figures come
  from its stats lines.
- **Kernel available memory** is `memorystatus_available_pages` (16 KiB pages) from the
  kernel's kill lines in the device syslog, 0–600 s after the first frame (122–235 samples a
  run).
- **`memorystatus_level`** was read only by the pool: at Play (above) and at the growth stop
  (13–14 %). R5 has no reading.
- **The syslog shows no pressure kill in any run.** The kernel ended:
  - idle processes for `long-idle-exit`;
  - a few daemons over their own high-water mark (`highwater`);
  - two daemons over their own limit (`per-process-limit`).
  - It never named the app.
- **FPS** is over the whole run, including about 90 s of menu and load at 60 FPS. All five
  runs reached serious thermal state with a 404 mW budget. The runs came one after another
  with a 10-minute cool-down; R1 started from a cool phone after 1 minute.
- **Screenshots** (in the run directories, not published):
  - All runs show Henry in Rattay's square or streets in daylight: the church, half-timbered
    houses, the stocks, a horse.
  - The walk did not land at the same spot in each run, so no frame pairs exactly.
  - Texture detail looks the same in every run, the low spec's: close wooden surfaces are soft,
    and distant houses are clean.
  - No run shows corruption, missing textures or pop-in that differs with the video figure.
    R5's +300 shot faces a timber wall up close.

## Verdict

**1. The memory ceiling with the pool.**

- **Telling the guest 9,216 MiB worked for KCD.** KCD saw 9,216 MB installed and ran 600 s
  without a jetsam. Its app footprint peaked 258 MiB higher (4,256 against 3,998). The pool
  filled to the same 4 GiB.
- **But it bought nothing for KCD**, which used no more memory than it does when told 8,192.
- **It brought the phone's free memory to its lowest of the day:** 1,137 MiB available,
  median 1,393 after +120 s. That is under the 1,408 MiB spare floor the pool's growth stop
  uses.
- **On 12 GB the real ceiling is physical RAM, not the number the guest is told:**
  - with the pool, the game's whole set, app and pool together, was 7.9–8.3 GiB;
  - the kernel's available memory then sits at 1.1–1.5 GiB in every run, close to the floor.
- **A game that really used 9 GiB would have about 1 GiB less to stand on**, and nothing
  measured here shows that margin exists.
- **Plain answer:** on the 12 GB phone, the guest can safely be told what the plan tells it
  now, 8,192 MiB (the limit; the pool's raise is 0 because the game's budget, 8,278 MiB, is only
  86 MiB over it). 9,216 survived one run as a per-title override for a title like KCD that does
  not fill it; it is not a default.

**2. The video memory figure.**

- **KCD's graphics memory did not follow the figure.** The graphics ledger stayed at
  1.58–1.65 GB on average and 1.66–1.78 GB at its maximum at 1,536, 2,048 and 3,072. The pool
  runs' footprints differ by less than run-to-run noise.
- KCD's explicit low settings (`sys_spec_* = 1`) hold whatever it is told. The only change it
  shows is the machine class: class 2 from 2,048 on.
- **The median FPS was 2–4 lower in the class-2 runs:** 16.1, 14.0 and 13.4 against 17.9 and
  17.8. This is one run each, under serious thermal state, so it is not shown to be the
  figure's effect.
- **With the pool, 2 and 3 GB were safe for KCD:** no jetsam, and the peak stayed within
  4.2–4.3 GB.
- **Without the pool, 3 GB survived too:** no jetsam, peak 7,931 MiB, 261 MiB under the
  8,192 limit.
  - That is the same place earlier pool-off runs at 1,536 reached (7,682–7,914), because KCD's
    graphics use did not grow.
  - So this run does not show why the cap exists. A title that does fill a 3 GiB budget would
    add up to about 1.5 GB of graphics memory to a footprint that already sits about 260 MiB
    from the limit.
  - The cap stays justified by the arithmetic and by the earlier RDR2 runs (ml1042 / ml1103),
    not by this one.

## What it suggests for the memory plan's constants (not changed)

- **iOS reserve 2,048 and spare floor `max(768, 12 %)` = 1,408: keep.**
  - With the pool, available memory bottomed at 1.1–1.5 GiB in every run, and the level fell to
    13–14 % within 130–170 s.
  - The reserve and floor describe where iOS actually runs; lowering either would plan memory
    that is not there.
- **App part 4,096: keep for the default plan, and raise it if the guest is told more.**
  - The pool runs' app footprint peaked at 4.0–4.34 GB, already over 4,096 in R2–R4.
  - Telling the guest more raised the app's own footprint (+258 MiB, R2).
  - If the plan ever tells the guest more than L, Auto's app part should grow with it, to about
    4,352 to 4,608.
- **Overhead 2,048 and margin 512: keep.**
  - Without the pool, KCD's peak left 261 MiB, under the 512 margin, with either video figure.
  - So the margin is already consumed by KCD's guest heap. There is no room to lower it, or to
    raise the default video budget without the pool.
- **Video budget (L − min(G, 4,096) − 2,048 − 512 = 1,536): keep the default.**
  - A title-level `vram-mb` of 2,048–3,072 with the pool was safe for KCD.
  - A default above 1,536 would need a title that actually uses the extra, measured with the
    pool on and off.
- **Pool raise of guest RAM (≤ budget − L, so 0 here): keep.** R2 shows that 1 GiB more is
  survivable for a light title, but it pushes the system under the floor.

## Not shown

- A title that really fills 9 GiB of guest RAM or a 3 GiB video budget. KCD at low spec does
  neither.
- Whether KCD's machine class 2 changes rendering or cost beyond its explicit settings.
- More than one run per setting, or runs longer than 600 s.
- Any phone but the 12 GB reference phone.

## Games

- Kingdom Come: Deliverance (app-379430): **Works.** Five 600 s runs in Rattay through
  Continue:
  - with Auto pool and guest RAM 8,192 or 9,216, video 1,536, 2,048 and 3,072;
  - with the pool off and video 3,072.
  - No crash and no jetsam. FPS median 13–18, thermal serious.
