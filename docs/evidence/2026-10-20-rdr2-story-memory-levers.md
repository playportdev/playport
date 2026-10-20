# 2026-10-20: RDR2's own graphics settings at their lowest get the Story load to its first 3D frames; the load still ends at the 8,192 MB limit. A smaller `totalphys` or video budget changes nothing, and ending the game's own Social Club frees about 480 MB that the load takes back

**Linear:** PLA-413 (and PLA-364). **Plan:** `.work/plans/rdr2-story-memory.md`. **Decision:**
[0133](../decisions/0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md).
**Follows:** [rdr2-landing-capture](2026-10-20-rdr2-landing-capture.md), section 6.

The phone was unattended (owner away). Battery 80 % on external power throughout, free space
5.1–5.6 GB. Every run used `--pad --action set:donorPoolMB=auto`; PlayRDR2's "Unable to launch game"
box was closed by one pad A (decision 0076). Nothing in the Online tab was opened, and no legal
page was shown or answered. Screenshots, run directories and logs stay under `$PLAYPORT_BUILD`
(`agent-notes/pla413c/`, `ui-runs/`).

## Builds and runs

| IPA sha256 | What | Hollow Knight first frame | RDR2 runs (`$PLAYPORT_BUILD/ui-runs/…`) |
| --- | --- | --- | --- |
| `f03e22d3b26794928aabaa5bbdd2b31ff8cc099eb75ad215fdc493f6fc6be418` | HEAD `05ee986` (mesa 0044, 0045) | gated on 2026-10-20 (`ui-runs/20261020T021101`) | `20261020T023856-rdr2-settings`, `…T025750-rdr2-low1`, `…T030757-rdr2-phys6144`, `…T032027-rdr2-vram2048` |
| `05f48361839a0d2bba49318f4dc616ac012f4adfc9359a7b93fa3c617d37ea95` | 0133's control, sent at the sign-in | +10.43 s (`ui-runs/20261020T033205`) | `…T033304-rdr2-sc1` |
| `bbec2796cccd5f55ce9ac98da321a7c062031a1889a8ce2e21755578372acaeb` | 0133's control, sent near the limit | +10.36 s (`ui-runs/20261020T034153`) | `…T034248-rdr2-sc2`, `…T035333-rdr2-adv` |
| `b0d9e784f262ba761258f2e5238b1a2d9ce3b8c1e1f5e97f03ed28a0078331cf` | 0133 as committed: restarts ended once more | +9.29 s (`ui-runs/20261020T042007`) | `…T042101-rdr2-sc3`, `…T043106-rdr2-sc4` |

Every RDR2 run ended with the app killed by jetsam at its limit. The device log has
`memorystatus: S1Probe [...] exceeded mem limit: ActiveHard 8192 MB (fatal)` where the log capture
ran: low1, sc2, adv and sc3. phys6144 and vram2048 ended the same way, with the last fast
`[footprint]` line at 8,175 and 8,080 MB.

## 1. The game's own graphics settings, with the pad

The landing page's Settings (LS) › Graphics opens a readable page. Its meter is "Video Memory
X / 8192 MB", split into "RDR2" and "Other Apps".

| Step | Video Memory (RDR2 / other) |
| --- | --- |
| as the game's Safe preset left it: 1280×720, Texture Quality Ultra, the rest Low, SSAO Medium, TAA Medium | 4,527 (2,889 / 1,638) |
| Texture Quality Low | 3,261 (1,623 / 1,638) |
| SSAO Off, TAA Off | 3,250 (1,612 / 1,638) |
| Advanced Settings unlocked, Resolution Scale 1/2 (×0.5), Fur Quality Medium (its lowest) | 3,182 (1,544 / 1,638) |

- **Already at their lowest:** resolution (1280×720 is the lowest the game offers), MSAA,
  reflection MSAA, volumetrics, shadows, the grass and geometry level of detail, and tree quality.
  The pad's left and right wrap around the values.
- **Apply Changes needs a second A on its Confirm page.** The page reads "Do you want to keep
  these settings? Some of the modified settings will not be applied until Red Dead Redemption 2 is
  restarted", with a countdown. The first try missed the countdown and the settings went back.
- **The game writes `system.xml` when Settings is left**, not at Apply (pulled with
  `pp phone pull` before and after). The result, against the earlier pull:
  - `textureQuality` Low, `ssao` Low, `taa` Low;
  - `advancedGraphics/locked` false;
  - `scalingMode` `kSettingScale_Mode1o2`;
  - `furDisplayQuality` Medium;
  - HDR stays `true`.
- **Texture Quality takes effect at the game's next start.** With Story started in the same run
  as the change (`…T023856-rdr2-settings`), the graphics ledger reached 3,279 MB, as on Ultra.
  After a restart (`…T025750-rdr2-low1`) it was 2,787 MB at the kill.

## 2. The Story load with each lever

A at first frame +83 s, on the Story tab. The last full `[footprint]` line before the kill (MB):

| Run | Lever | phys | graphics | compressed | How far it got |
| --- | --- | ---: | ---: | ---: | --- |
| `…T022900` (2026-10-20 evidence) | none, Texture Ultra | 8,055 | 3,268 | 4,644 | loading screens |
| low1 | Texture Low and the rest above, after a restart | 7,759 | 2,787 | 4,495 | the intro's first title card ("1899, the age of outlaws and gunslingers was at an end") |
| phys6144 | as low1, plus runtime key `totalphys=6144` | 7,738 | 2,742 | 4,866 | loading screens |
| vram2048 | as low1, plus `vram-mb=2048` (`[kk-memory] … budget capped at 2048 MiB`) | 7,895 | 2,947 | 4,986 | loading screens |
| sc2 | as low1, plus 0133's control near the limit | 7,879 | 2,875 | 4,771 | the second title card ("America was becoming a land of laws…") |
| adv | as sc2, plus Resolution Scale 1/2 and Fur Medium | 7,933 | 2,888 | 4,959 | **3D frames:** an interior (wooden walls, a hat and coat on hooks), about 2.5 min after A, for about 40 s |
| sc3 | as adv, plus the restarts ended once more | 8,007 | 3,167 | 4,597 | loading screens |
| sc4 | as sc3 | 8,147 | 2,983 | 5,027 | the intro's title cards, to "ROCKSTAR GAMES PRESENTS" (section 5) |

- **A smaller `totalphys` does not help.** At 6,144 the game shows its own box before its first
  frame: "Minimum Recommended Hardware Check Failure: Your computer does not meet the minimum
  recommended Memory (RAM) specification". It was closed with one pad A (OK). The first frame came
  279 s after the launch instead of about 100 s, and the footprint and graphics were as without
  the key.
- **A smaller video budget does not help.** The ledger went past the 2,048 MiB budget as it had
  gone past 3,072.
- **The lowest settings got further than any run before:**
  - low1 reached the intro's first title card;
  - adv reached rendered 3D frames. They are at half resolution with TAA off, so dithered
    transparency shows as a stipple. Textures and lighting are there, and the left edge is
    smeared.

  The load still grew past the limit in each run, at about 35 MB/s, and the end of the load varies
  from run to run: sc3, with the same settings as adv, ended on the loading screens.

## 3. Ending the game's own Social Club (decision 0133)

- **At the sign-in there is nothing to end** (sc1). The game starts its own `SocialClubHelper.exe`
  1.0 s after its `Signed in online` line, and the renderer 4.9 s after that:
  `[game-sc] done: 0 ended of 3 processes in the job`.
- **Near the limit it ends two processes** (sc2, adv, sc3). The control is sent at the first
  reading at or over 6,992 MB after the sign-in: 7,014, 7,392 and 7,488 MB, since the footprint
  jumps. In adv, `[proc-end]` shows what went:
  - the browser (`pid=0600`): footprint 7,385→7,074 MB, emptied 643 MB, kept 789 MB (9 views a
    parked register points into);
  - the renderer (`pid=06c8`): footprint 7,074→6,903 MB.

  That is **482 MB** freed in about a second.
- **The game starts a new browser 0.6–1.1 s later** (`[game-sc] after the end: SocialClubHelper.exe
  pid … (parent 1044)`). In sc2 that browser reached about 430 MB (`[proc-mem] pid=0744`
  image 123+27, private 24+3, fex 166+87 resident+compressed), and in adv its renderer followed
  21.5 s later.
- **Ending the restart too** (sc3, IPA `b0d9e784`): the one restart was ended 914 ms after the end
  (`ended once more (restart 1 of 8)`), and no further restart came before the kill, 70 s later.
- **What the game showed:** in no run did it show a Social Club error box. Whether it would show
  one, or stop, is not known: every run ended at the limit within 70–100 s of the end.
- **The saves.** The profile's save files were backed up before the first run with the control
  (`agent-notes/pla413c/save-backup-0`, hashes in `save-backup-0.sha256`) and compared after sc1,
  sc2 and adv. The slots (`SRDR30000`, `SRDR30015`) and `Player` are unchanged. `cfg.dat` changes
  every run, also in sc1, where nothing was ended. After adv, `ProfileSettings` and
  `cloudsavedata.dat` changed too, at their old sizes (2,840 and 9,964 bytes). No file is
  truncated.

## 4. What fills the limit at the kill (sc2, the last `[proc-mem]` and `[phys-map]` lines)

`[proc-mem]` columns are committed / resident / compressed MiB; pool-backed pages are in them but
not in the footprint. `[phys-map] bands` is dirty / resident MB.

| Part | MB | Source |
| --- | ---: | --- |
| Graphics ledger (KosmicKrisp, Metal) | 2,875 | `[footprint]` |
| RDR2.exe (`pid=0414`) private | 3,325 / 271 / 2,609 | `[proc-mem]` |
| RDR2.exe in FEX's band | 1,418 / 84 / 267 | same |
| RDR2.exe images | 70 / 12 / 37 | same |
| the game's restarted Social Club browser (`pid=0744`) | image 312 / 123 / 27, private 69 / 24 / 3, fex 787 / 166 / 87 | same |
| crashpad (`pid=0424`), the session root, the other small rows | about 130 resident+compressed | same |
| JIT pool (RX = RW, one object) | 896 / 817 | `[phys-map]` |
| host-low (the runtime's host memory) | 507 / 505 | same |
| FEX band (all processes) | 926 / 331 | same |
| host malloc (`DefaultMallocZone`) | used 1,110 / allocated 1,622 | `[malloc-zones]` |
| donor pool, live (outside the footprint) | 2,694 (resident 180, compressed 2,054) | `donor-pool: stats` |

- **Host malloc jumps when the game warms its pipelines.** It rose from 67 to 854 MB used (1,359
  allocated) between first window and landing. Over the same stretch, KosmicKrisp deserialized
  the game's pipeline cache (`[kk-compile] totals … deserialized=3136`, from the game's 465 MB
  `sga_vulkan_final_init.vkPipelineCacheWindows`). The graphics ledger is 1.5 GB at the landing
  page, which draws no 3D scene.
  - That this memory is the pipeline cache's import and the 3,136 shaders' MSL and Metal objects
    is an inference, not measured.
  - The gap between used and allocated (about 500 MB) is malloc's.
- **The emptied band does not show as freed footprint while a parked thread's views stay.** The
  Social Club browser's end kept 789 MB of views.
- **The phone as a whole is out of memory.** The donor pool stops growing on low memory
  (`refused` 5,721 in low1), and the app's compressed share is 4.5–5.0 GB at every kill.

## 5. sc4 (`…T043106-rdr2-sc4`)

The same as sc3, plus the left stick held forward (`pp pad send "10000 LY=1" "200 -"`) every 30 s
from 150 s after A, to see the character move if gameplay came.

- **How far it got:** past the loading screens into the intro, whose title cards render:
  - "1899, the age of outlaws and gunslingers was at an end";
  - "A few gangs still roamed but they were being hunted down and destroyed";
  - "ROCKSTAR GAMES PRESENTS".

  Then the app was killed at the limit: the last full line is phys 8,147 MB, graphics 2,983 MB,
  compressed 5,027 MB.
- **The stick:** it was held forward twice (04:36:59 and 04:37:40), during the title cards. A
  card cannot show movement, so nothing moved.
- **The Social Club end:** at +292 s and 7,040 MB it ended the browser and its renderer. The
  game's new browser (pid 1860) was not caught: it is not in the `[game-sc]` lines. Two of its
  children were ended once more, 17.3 and 18.4 s after the end. Most likely the job reported
  1860 before the root's process list had it, so the root could not name it (inference).
- **Frame rate:** 49–59 fps on the loading screens, 16–23 fps during the intro cards.

## 6. Performance

- **Landing page and loading screens:** 50–56 fps (`[frames]`).
- **The 3D frames (adv):** 9–14 fps from about 2 min after A until the kill, over 35–50 s windows.
  - Over the same time KosmicKrisp translated 24 new shaders: `translated=24 (39,498 ms)`, with
    `metal=40,309 ms` of Metal library and pipeline builds. That is about 3.3 s per new shader,
    and it stutters the frame.
  - The `[xp]` lines show 1.31 GHz on the P cores.
- **Thermal:** every run's log reaches `thermal: serious` by the landing page (`nominal` at the
  launch, then `fair`).

## Not shown

- Gameplay that runs: the character moving with the left stick (see section 5).
- Whether the game, given room, goes on without its Social Club, or shows an error.
- How much of host malloc and of the graphics ledger is the pipeline cache's import and the
  deserialized shaders (inference above; a KosmicKrisp allocation log would show it).
