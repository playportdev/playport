# RDR2: a self-exited Social Club renderer's FEX band is emptied (madeira-unix 0203)

**IPA:** dev `ee38ddeb084146c69a30591e04c84ad5db995b9a97360aa8b43111b240c48ddd`
(`.work/out/20261020-193342-ee38ddeb/`, commit f75aaaa). **Decision:**
[0143](../decisions/0143-release-a-self-exited-childs-fex-band-as-a-killed-childs.md).
**Linear:** PLA-413, PLA-364.

## Gate

Hollow Knight first frame+10 on `ee38ddeb`: passed (run `.work/ui-runs/20261020T211020`, first frame
at +10.15 s), installed in place in the same lock session.

## Scripted Story runs

Session settings `donorPoolMB=auto`, `endGameSocialClubAfterSignIn=true`,
`refuseGameSocialClubRestart=true`, aspect 16:9, today's RDR2 compatibility defaults; the landing page
script pressed A on the Story tab. The phone was on battery (80 % to 64 %), with 3.1 to 3.9 GB free,
under the session's 2.5 GB stop as the owner allowed.

| Run | Directory | Renderers' end | Result |
| --- | --- | --- | --- |
| n1 | `.work/ui-runs/20261020T211148-rdr2-n1` | both ended themselves | RDR2.exe ended with `0xc0000005` at +141 s, right after the PlayRDR2 box was closed, before the Story press |
| n2 | `.work/ui-runs/20261020T211703-rdr2-n2` (host log in `.work/agent-notes/pla413e/n2/host/`) | one ended itself, one killed | Story pressed at 21:19:50; gameplay from about 21:22 (Arthur in the cabin, HUD and minimap); alive until the run's end at first frame+1500 (21:44), 15 stick cycles, no jetsam |

- **The self-exit path now empties the band.** Fixed log text:
  - n1: `[view-owner] peb=0x14dec4000 exited: freed image=284 private=2762 spans=0 callret=0 l1=34
    band_other=0 MB, emptied=617 MB, kept 674 MB (1 view(s) a parked register points into); 17
    finished, 1 parked thread(s); footprint 3854->3690 MB`, and for the second renderer
    `emptied=593 MB … footprint 3684->3423 MB`;
  - n2: `[view-owner] peb=0x14cac8000 exited: … emptied=607 MB, kept 668 MB … footprint 3969->3813 MB`;
    the other renderer `[proc-end] … pid=02d8 killed: … spans=296 callret=64 l1=32 band_other=248
    … emptied=0 MB` (no thread parked, so its band was deleted).

  Each renderer had one thread parked, so the band was emptied in place, not deleted. Before 0203 the
  same line read `kept 559 (680 MB)` (f2).
- **The runtime's FEX row stays low.** `[proc-mem] runtime … fex=` committed/resident/compressed:
  n1 1243/5/0 after both renderers' end; n2 3020/13/10 at the Story press +63 s, which is 23 MB
  resident+compressed, against 39 (s6), 37 (r2) and 365–396 (f2, o1–o4, b1, w1, w2b). The committed
  number is higher because emptied views keep their address range (0132).
- **n2's memory.** Footprint 5,385 MB at Story +63 s, 7,300–7,600 MB through gameplay, one fast
  reading of 8,016 MB at 21:31:18; no jetsam report for the app.
- **No new fault.** No SEGV in FEX's band (0x7c00000000–0x8000000000) in n1 or n2.
- **n1's crash predates 0203.** RDR2.exe's main thread read `0x707b3c0000`
  (`AV READ`, `[fault-rgn] … NO wine view`), 64 KB into its process heap (`0x707b3b0000`), at guest
  `x86=0f b7 04 42 …`, then `NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0xc0000005)`.
  Run r1 on `e5db6774`, without 0203, ended the same way at the same point after the box: the same
  instruction bytes, `0x7078ec0000` 64 KB into its heap `0x7078eb0000`. A separate bug.

## The beard (n2, screenshots in the run's agent-notes directory, not published)

Two gameplay screenshots show Arthur's face in profile in the cabin:
- 21:26:07, in the dim interior by a window: beard and hair dark brown, shaded as expected;
- 21:29:15, by a doorway with brighter light behind: beard and hair speckled pale yellow-white, the
  ear a flat saturated red, the hat's brim with the same speckled pale texture.

So the white beard with red patches still shows, in some lighting and not in other, in the same
minutes. Not fixed.

## CPU or GPU bound (n2)

`[kk-gpu]` per-second lines, medians over 1,218 samples from 21:22:33 to 21:44:26 (gameplay;
`thermal: serious` from 21:20:05; p10–p90 in brackets):

| fps | busy % | gpu/frame | acquire | present-wait | submit |
| --- | --- | --- | --- | --- | --- |
| 15.9 (10.0–19.8) | 34 (23–40) | 21.7 ms (17.1–25.9) | 1.2 ms (0.8–5.5) | 0.0 ms | 144 ms/s (103–206) |

The GPU is idle two thirds of the time and a frame's GPU work (21.7 ms) would allow about 46 frames/s;
nothing waits on present or acquire. At `thermal: serious` RDR2's gameplay is CPU-bound.
