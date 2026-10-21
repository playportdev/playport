# RDR2: single-process Social Club with the game's Social Club ended after its sign-in (PLA-364, PLA-413)

**Linear:** PLA-364, PLA-413. Follows [the combined arms](2026-10-21-rdr2-combined-arms.md), whose single-process
runs (scA1, x3, x4) had the workarounds off. This is the arm that page left untried: `env.PLAYPORT_SC_SINGLE=1` with
`endGameSocialClubAfterSignIn=true` and `refuseGameSocialClubRestart=true`. One run, owner-approved.

## Run

- **IPA (dev):** `ae8dbb17c2498bbc07ac2245f6d4f458d60fed5a4143083509dea8d89870d836` (decision 0152's default),
  installed at the start; phone on its charger at 80 %.
- **Run:** xs1 (`.work/ui-runs/20261021T151236-rdr2-xs1`; scripts `.work/agent-notes/pla413e/xs1.sh` and
  `story.sh`, comparison `xs1-cmp.py`).
- **Settings:** session `donorPoolMB=auto`, `endGameSocialClubAfterSignIn=true`, `refuseGameSocialClubRestart=true`,
  aspect 16:9. The runtime keys were RDR2's whole compatibility-default string plus `env.PLAYPORT_SC_SINGLE=1`. The
  log's `config: environment` lines show all seven variables, and `ui: settings` shows the merged keys (decision 0091
  merges a person's keys over the default's by key, so repeating the default's keys changed nothing).
- **Pad:** Story only, pressed by `landing.py`; no stick input. Run to first frame+420.
- **Thermal.** The phone had rested during the analysis before the run, so the state was `nominal` at launch and
  `fair` later. `serious` never came. The porch numbers below are therefore not comparable with the `serious`
  windows of d2–d5 and nd1.

## Results

Footprints are the `[xp]` `fpMB` samples (for every run alike: the first sample at or after the time; peak = the run's
maximum). Sign-in is the title's `the game signed in` / `ending the launcher at` line, from the Play.

| Run | IPA | SC | first frame | signed in (fp MB) | Story press / +60 s (fp MB) | peak MB | game's SC ended | SC helpers spawned | processes spawned | 0205 ownership changes | thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| d2 | 6ab8471c | multi, workarounds on | +105.2 s | +139.0 s (5604) | 5210 / 5208 | 7581 | +314.6 s | 7 | 16 | 1 | serious at launch |
| d3 | 7910e2a3 | the same | +115.4 s | +145.9 s (5884) | 5471 / 5139 | 7026 | +318.7 s | 7 | 16 | 1 | serious at launch |
| d4 | 7910e2a3 | the same | +103.4 s | +132.0 s (5675) | 5228 / 5191 | 7081 | +303.1 s | 7 | 16 | 1 | serious at launch |
| d5 | 7910e2a3 | the same | +124.7 s | +150.2 s (5631) | 5213 / 5154 | 7032 | +327.7 s | 7 | 16 | 1 | serious at launch |
| nd1 | ae8dbb17 | the same | +102.2 s | +128.9 s (5480) | 5210 / 5232 | 7738 | +290.1 s | 7 | 16 | 1 | serious |
| x4 | 6ab8471c | single, workarounds off | +33.6 s | +95.2 s (6006) | 5481 / 5223 | 8120, **jetsam** | — | 2 | 10 | 4 | serious |
| **xs1** | ae8dbb17 | **single, workarounds on** | +33.6 s | **+92.5 s (5673)** | 5222 / 5426 | **7343** | **+225.0 s** | **2** | **11** | 4 | nominal → fair |

- **Gate counts (xs1).** `[sc-single] preflight` 2 and `verified browser` 2 (the launcher's helper and the game's),
  `[sc-rph]` 2. There was no race and no fallback line, and no `exit_code=0xc0000005`. The single crash reporter
  was spawned once, as in every run (`PLAYPORT_SC_BLOCK_CRASHPAD` off).
- **The game's helper.**
  - It was ended at +225.0 s, 132 s after the sign-in, when the footprint reached 7168 MB (decision 0141's
    threshold), at 15:17:03.
  - After that the game tried to start it again 47 times; 0138 refused each (`[game-sc] refused … start 40` is the
    last logged).
  - Spawned SocialClubHelper processes: 2, against 7 in every defaults run.
- **Time.** The launcher drew its first frame at +33.6 s, against +102–125 s, and the game signed in at +92.5 s,
  against +128.9–150.2 s. That is 36–58 s sooner.
  - The PlayRDR2 box came 64.6 s after the first frame (defaults: 25–37 s). The earlier page's "launcher 35–85 s
    slower" measured from the first frame; from the Play, single-process is faster.
- **Memory.**
  - Footprint at the sign-in: 5673 MB, inside the defaults' 5480–5884. Story +60 s: 5426 MB, against 5139–5232.
  - Peak: 7343 MB, inside the defaults' 7026–7738. No jetsam (the syslog has no S1Probe jetsam line).
  - x4, with the helper alive, peaked at 8120 MB and was killed. Ending the helper is what keeps single-process
    under the limit.
- **No flashing.** There were 4 `[vk-shown]` ownership changes (first window, foreground twice, then
  `0x100b8`: "the owner is gone or hidden; this window presents"), as in x4. After that the owner was stable.
- **The porch, then a black screen.**
  - The porch view showed at 15:17:04–15:17:35 (screenshots 010–012).
  - From 15:17:51 to the end (15:20:51) the screen was black, with the game's orange spinner.
  - During it: `[kk-gpu]` 60 fps at 0.6 ms of GPU a frame, acquire ~930 ms/s, CPU 0.73 cores, and the footprint
    steady at ~7310 MB. This is the same state as x8 and qp1.
  - The black came 48 s after the game's helper was ended. In the defaults runs the end came at a similar point
    (nd1: +290 s, just before the porch), and the porch held.
  - One run does not show the cause.
- **fps.** The porch's 26 s (15:17:14–15:17:40) gave 19.0 fps, GPU busy 47 %, 24.9 ms a frame, E 1.67 GHz:
  11.4 fps/E-GHz. That is at `nominal`/`fair`, not `serious`, and not a 60 s window, so it is not comparable with
  10.4–11.0 in d2–d5 and nd1.

## Verdict

Not clearly no worse than the defaults, so the defaults are unchanged.

- **What is better.** Single-process with the end and the refusal signs in 36–58 s sooner, spawns 11 processes
  against 16 (2 Social Club helpers against 7), and stays inside the defaults' memory: sign-in 5673 MB, peak
  7343 MB, no jetsam. It also clears x4's jetsam.
- **What is worse.** The porch was lost to a black loading screen 48 s after the game's helper was ended, which
  no defaults run showed.
- **Not measured.** With thermal never at `serious`, fps per E-GHz was not measured comparably.
- **Next.** Another run is needed to tell whether the black screen follows the helper's end under single-process,
  for example with the end delayed past the porch load.
