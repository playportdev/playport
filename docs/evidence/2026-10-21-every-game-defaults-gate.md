# Every game's defaults (decision 0153): the gate on Hollow Knight and RDR2 (PLA-364, PLA-413)

**Linear:** PLA-364, PLA-413. **Decision:** [0153](../decisions/0153-rdr2s-settings-are-every-games-defaults.md).
The phone was on its charger at 80 %, with 6.1–6.3 GB free. Only two titles are installed on it: Hollow
Knight and Red Dead Redemption 2 (Library › Installed · 2, run `.work/ui-runs/20261021T154744`).

## IPAs

| IPA | Commit | What |
| --- | --- | --- |
| dev `ae8dbb17c2498bbc07ac2245f6d4f458d60fed5a4143083509dea8d89870d836` | 7e8be0c | before: decision 0152's RDR2 default |
| dev `d4ff7de2b3d6db261868bcad4774a4255f7dc955d68c06f317855b76e4bbb199` | (uncommitted tree) | every RDR2 setting global, `env.FEX_HOSTFEATURES=disableafp` included |
| dev `55b643b6e9f1ea2bff5118fd91dd77ea8ffe8a3158b9f78d1681bb8040ad00f7` | (uncommitted tree) | `disableafp` stays RDR2's; everyGame's keys merged into the title's runtime keys |
| dev `d95adbbd6b9c9792da9e78af2338e35fe44ea0d9cb36394666d4645355cd131b` | this commit | as 55b643b6, with everyGame's keys moved under a cohort title's madeira.cfg keys (`Effective.config`), so The Witcher 3 keeps `jumbo-mb=32768`; the same keys for HK and RDR2 |
| release `82a20c1426d892c3dda68d62aa137cbed502e762ededbb16f3212eedc313acd2` (signed), `8260278b54e826935e6583970f9b72bb8bc2ee1d8f35362760268bf57f655d2e` (unsigned) | this commit | the owner's to install and play (decision 0068): `.work/out/20261021-161634-release-82a20c14/`, `.work/out/20261021-161706-release-unsigned-8260278b/` |

- **Both variants verified.** `pp verify` of the release IPA checks the new item "the donor pool is linked
  (decision 0153)" (`pp_guest_pool_install`, `playport_guest_memory_backing`), along with no dev code, no
  driver names and the quiet-runtime switch.
- **Signing.** Signing failed first with Apple's 409 "no current IOS devices": `xtool ds devices` listed
  none. DEVICE.md's recipe registered the phone again. The unsigned release IPA (6f3a40f5, this tree before
  the AFP change) was installed in place with `xtool install --network`, and the dev IPA after it. That
  release app was only installed, never launched by a driver.

## Hollow Knight (app-367520), first frame +10

| Run | IPA | Backend, loader | JIT pool (room at first frame) | Donor pool | services.exe | steam_api | First frame | Footprint before / after first frame | Peak | Screen |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `…T140859` | ae8dbb17 | vulkan, Wine's | 512 MiB (305) | none | no | emulated | +10.43 s | 2158 / 2320 MB | 2542 MB | menu |
| `…T154653` | d4ff7de2 | vulkan, Khronos | 896 MiB (632) | 4096 MiB in 0.69 s | yes | client | +10.91 s | 2455 / 3128 MB | 3257 MB | **black** |
| `…T154858` (+25) | d4ff7de2 | the same | | | | | | | | **black** |
| `…T155826` | 55b643b6 | vulkan, Khronos | 896 MiB (632) | 4096 MiB | yes | client | +11.60 s | 2954 / 3125 MB | 3242 MB | menu |
| `…T161809` | d95adbbd | the same | 896 MiB (632) | 4096 MiB | yes | client | +12.18 s | 3010 / 3137 MB | 3257 MB | black at +10 |
| `…T161924` (+40) | d95adbbd | the same | 896 MiB (632) | 4096 MiB | yes | client | +11.38 s | 2999 / 3132 MB | 3239 MB | menu |

- **The black screen (d4ff7de2).** The game drew 60 frames/s, with `[kk-gpu]` at 6.6–7.0 ms of GPU a frame
  (ae8dbb17: 6.2–6.6) and the same `[kk-wsi]` chain and `[vk-shown]` owner, but the picture stayed black.
- **The bisect** (`.work/agent-notes/pla413e/hkbis.sh`, first frame+25, overrides on the game page):

  | Run | Overrides | Screen |
  | --- | --- | --- |
  | b1 `…T155031` | Wine's loader, the emulator, no services, pool 512 MiB, donor pool off | black |
  | b2 `…T155158` | `env.FEX_HOSTFEATURES=enableafp env.MADEIRA_FASTSYNC_SEM=0 env.PLAYPORT_VK_HEAP_MB=0` | menu |
  | b3 `…T155324` | `env.FEX_HOSTFEATURES=enableafp` | menu |
  | b4 `…T162110` (d95adbbd, +40) | `env.FEX_HOSTFEATURES=disableafp` | black |

  - **The AFP finding.** With `disableafp` the screen was black in all four runs (+10, +25, +25, +40).
    Without it, the menu showed in four of five, and the fifth (`…T161809`, +10) showed it by +40 in the
    next run.
  - So `FEX_HOSTFEATURES=disableafp` breaks Hollow Knight, and it stays RDR2's own (the supervisor's
    choice for the owner). Why AFP off blackens Hollow Knight is a follow-up.
  - **A late menu.** Separately, with the new defaults Hollow Knight's menu sometimes comes later than
    first frame+10: one run in five, against none on ae8dbb17.
- **Hollow Knight's costs on 55b643b6** (accepted under the owner's rule):
  - first frame +1.2 s, against one run each;
  - footprint at the first frame +300–800 MB, from the 896 MiB JIT pool and the Khronos loader, and from
    `services.exe`, which also starts MountMgr;
  - peak +700 MB;
  - donor pool 0.7 s.

## RDR2 (app-1174180), Story to the porch

Run g1 (`.work/ui-runs/20261021T155940-rdr2-g1`, 55b643b6, `.work/agent-notes/pla413e/g1.sh`).
d95adbbd launches RDR2 with the same keys: neither title has madeira.cfg keys of its own.
- **Settings.** No session overrides: `story.sh`'s `set:donorPoolMB=auto` is now the default anyway. The
  only `--settings` was aspect 16:9.
- **Keys, from the log.** `graphics: vulkan; vulkan loader: Khronos`, the six runtime keys plus RDR2's
  `FEX_HOSTFEATURES=disableafp`, and `steamapi: client`.

| Run | IPA | first frame | signed in (fp MB) | Story press / +60 s (fp MB) | peak MB | game's SC ended | SC helpers / processes spawned | jetsam | porch, 60 s at `serious` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| nd1 | ae8dbb17 | +102.2 s | +128.9 s (5480) | 5210 / 5232 | 7738 | +290.1 s | 7 / 16 | no | 16.5 fps, E 1.50 GHz, 11.0 fps/E-GHz, 376 mW |
| **g1** | 55b643b6 | +87.6 s | **+107.9 s (5790)** | 5465 / 5693 | **7523** | +247.2 s | 7 / **15** | **no** | **18.1 fps, E 1.55 GHz, 11.7 fps/E-GHz, 407 mW** |

- **What happened.**
  - The launcher ended at the sign-in.
  - The game's own Social Club was ended at +247.2 s by the now-default setting: "ending the game's own
    Social Club … (decisions 0133, 0153)"; the session root ended 2 processes.
  - One `[sc-crashpad]` refusal (`RockstarErrorHandler.exe`), so 15 processes against 16.
  - No `0xc0000005`.
- **The porch held** from 16:04:41 to the end (16:06:30). Thermal was `serious` from 16:02:50; the window
  was 16:04:51–16:05:51.
- **Footprint at the Story press was +250–460 MB over nd1, and the peak was inside the defaults' range.**
