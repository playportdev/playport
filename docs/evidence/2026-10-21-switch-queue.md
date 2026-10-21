# The untested-switch queue on decision 0153's defaults (PLA-364, PLA-413)

**Linear:** PLA-364, PLA-413. **Decision:** none. No switch beat the defaults, so
[0153](../decisions/0153-rdr2s-settings-are-every-games-defaults.md) stands as it is.

Every RDR2 run used dev IPA `d95adbbd6b9c9792da9e78af2338e35fe44ea0d9cb36394666d4645355cd131b` (0153's tree). The
runner was `.work/agent-notes/pla413e/qarm.sh NAME 'RUNTIME KEYS'`: Story, aspect 16:9, the switch's keys over
the defaults, and no stick input except in qe2b. The phone stayed on its charger at 80 %, with 4.7–4.9 GB free.
The runs went back to back with no cooling.

## How to read the numbers

- **`thermal: serious at launch`.** This is the app's first thermal reading at launch, already `serious`
  because the previous run had just heated the phone. Such a run is at `serious` for its whole length, with
  the E cores at 1.2–1.4 GHz against 1.5–1.6 GHz in a run that starts cool. g1, qa1, qb3 and qe2d started
  nominal and reached `serious` before their windows (qa1 16:28:15, qb3 17:16:25).
- **fps per E-GHz** is fps divided by the E cores' clock (`arm.py`: `[kk-gpu]` medians and the `[xp]` census
  over the window). It only roughly corrects for heat. A hotter, slower-clocked run tends to score a little
  higher, so each arm is compared with a control from the same scene and, where possible, the same heat.
- **The scene moved.** The game resumes from its latest save. Up to qb3, Story opened on the cabin porch.
  qe2b, the walk into daylight, opened outdoors. From qc1 on, Story opened inside the cabin, with Arthur on a
  bench by a bright doorway.
  - So two baselines apply. On the porch it is g1 (`.work/ui-runs/20261021T155940-rdr2-g1`, from 0153's gate),
    with qe1 as a hot porch control. In the cabin it is qd1b, a run with no keys.
  - Porch window: from the first porch screenshot +10 s, for 60 s. Cabin window (`cabin.py`): from the first
    cabin screenshot +60 s, for 60 s.
- **Peak** is the largest `[footprint] phys` in the run's `s1-host.log`.
- **Faults.** No run logged `0xc0000005`. Only qb2 ended in jetsam.

## Results

| Run (`.work/ui-runs/…`) | Keys over the defaults | Thermal | Scene, screen | fps | E GHz | fps/E-GHz | GPU ms/frame | CPU mW | Peak MB | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| g1 `T155940` (55b643b6) | none (0153's gate) | serious from 16:02:50 | porch, drawn | 18.1 | 1.55 | **11.7** | 24.4 | 407 | 7498 | baseline |
| qa1 `T162512` | `MADEIRA_X64_ONCE_FASTPATH=1 MADEIRA_FEX_EC_CALLRET_POP=1 MADEIRA_ECO_NATIVE=1` | serious from 16:28:15 | porch, drawn | 18.1 | 1.56 | 11.6 | 24.4 | 408 | 7124 | no gain: dropped |
| qb1 `T163403` | `MESA_KK_BATCH2=1 MESA_KK_BATCH2_SKIP=alloc,map` | serious at launch | porch, drawn | 16.0 | 1.34 | 11.9 | 26.8 | 345 | 7371 | no gain against qe1 |
| qb2 `T164300` | `MESA_KK_BATCH2=1 MESA_KK_BATCH2_SKIP=map` | serious at launch | porch for one shot, then the app ended | – | – | – | – | – | **8154** | jetsam (highwater): `alloc` is the memory item |
| qb3 `T171502` | `MESA_KK_BATCH2=1 MESA_KK_BATCH2_SKIP=alloc` | serious from 17:16:25 | porch, **drawn** | 17.0 | 1.46 | 11.6 | 25.8 | 372 | 7096 | no gain; x8's black porch not reproduced |
| qe1 `T165031` | `MADEIRA_POWER_GOV_MW=2300` | serious at launch | porch, drawn | 15.7 | 1.29 | 12.2 | 27.2 | 329 | 7097 | inert (0 ECO switches): the hot porch control |
| qe2b `T172335` | `MADEIRA_NO_DIAGNOSTICS=1`, the walk started at 17:29:16 | serious at launch | outdoors in snow (a new save), walking | – | – | – | – | – | 7016 | no measurement (other scene, walking, no `[xp]`) |
| qc1 `T173424` | `MESA_KK_SAFE_MATH=1` | serious at launch | cabin, drawn | 15.9 | 1.24 | 12.8 | 28.9 | 295 | 7100 | GPU +21 %, fps −4 %, same hair: dropped |
| qd1 `T174541` | none | serious at launch | "Not signed in" at the landing | – | – | – | – | – | 5600 | run ended at the screen, nothing pressed |
| qd1b `T175004` | none | serious at launch | cabin, drawn | 16.6 | 1.33 | **12.5** | 23.9 | 317 | 7492 | cabin baseline |
| qe3 `T180119` | `cpu-count=4` | serious at launch | cabin, drawn | 14.8 | 1.62 | 9.1 | 22.4 | 346 | 6615 | −27 % per E-GHz, acquire 7.0 ms against 1.3: dropped |
| qe4 `T181047` | `yield-sleep-us=200 yield-streak=64` | serious at launch | cabin, drawn | 17.1 | 1.38 | 12.4 | 23.3 | 329 | 7171 | no gain: dropped |
| qe2c `T182036` | `MADEIRA_NO_DIAGNOSTICS=1` | serious at launch | cabin for one shot, then **a black loading screen** to the end | – | – | – | – | – | 7552 | see below |
| qe2d `T183112` | `MADEIRA_NO_DIAGNOSTICS=1` | serious from mid-run | cabin, drawn | 17.6 | (no `[xp]`) | – | 23.2 | – | 7175 | within the spread; no dev change |

Every run but qd1 signed in, ended the launcher and reached Story (qd1: "Not signed in", run ended).
- **The game's Social Club** was ended between +240 and +344 s in every run except qe3. In qe3 the footprint
  never came within the end's margin: peak 6615 MB.
- **qe1 was the previous worker's last finished run;** that worker's own `qe2` (`T170945`) was cut off
  43 s after the game started, before its first frame, when it timed out.

## Per item

- **KK batch 2 (b).** `alloc` is the memory item: qb2 left it on and was ended by jetsam at 8154 MB (x6 at
  8015 MB).
  - Without `alloc`, the porch was drawn both with `map` (qb3) and without it (qb1). The other four items were
    on in both.
  - So on 0153's defaults no item blackens the porch. x8's black porch (`_SKIP=alloc`, with `MESA_KK_SAFE_MATH`
    and `MADEIRA_ECO_NATIVE` on) did not happen again. Its cause was those keys or chance; no batch-2 item.
  - Neither run beat its control: qb3 11.6 against g1 11.7; qb1 11.9 against the hot qe1 12.2, with GPU per
    frame 26.8 against 27.2 ms.
  - **Verdict: dropped.** The switch stays off and its code (mesa 0091–0095) is kept.
- **Precise math (c).** By the time of qc1 the save had moved into the cabin, so qc1 and qd1b frame Arthur on
  the bench in front of the bright doorway. That is the lighting the item was meant for.
  - The closest matching screenshots are qc1's `shot-018-174326` and qd1b's `shot-021-175915`. Crops of the head
    are in `.work/agent-notes/pla413e/cc/hair-qd1b-vs-qc1.png`.
  - The two show the same thing: a pale, speckled beard, a white hat brim and a red ear. `MESA_KK_SAFE_MATH=1`
    does not change that artefact, and it costs 21 % more GPU time per frame (28.9 against 23.9 ms).
  - **Verdict: dropped.** Code kept (mesa 0082). The artefact is a separate problem.
- **The walk (qe2b).** It was the attempt to put Arthur in daylight. Its porch detection fired on a dark intro
  card, so the stick moved during the window and the run measures nothing. The new save then opened outdoors,
  in snow: Arthur's beard looked dark brown and normal in that flat, overcast light. The walk script
  (`.work/agent-notes/pla413e/walk.sh`) now needs two black shots in a row before it accepts the porch.
- **CPU governor (qe1).** At 2300 mW it never engaged: the process drew 0.3–1.3 W, with ECO on 0 % of the time
  and 0 switches in all 34 reports. RDR2's CPU power is far under any target worth setting.
  - **Verdict: dropped at that target.** Code kept (madeira-unix 0202). A target below ~0.3 W was not run.
- **`MADEIRA_NO_DIAGNOSTICS=1`.** It removes the `[xp]` census, so there is no E clock to normalise by. Frame
  rate is taken from `[kk-gpu]`, timed backwards from the log's end (`nodiag.py`; checked against qd1b's `[xp]`
  times, the same medians).
  - qe2d held the cabin at 17.6 fps against qd1b's 16.6. qd1b's own later minutes were 16.9–17.4 and qe4's
    window 17.1, so this is inside the run-to-run spread.
  - qe2c showed the cabin, then went to a black screen with the loading icon 40 s after the game's Social Club
    was ended. It stayed there to the run's end: 60 fps at 0.6 ms of GPU a frame. xs1
    ([sc-single-with-end](2026-10-21-rdr2-sc-single-with-end.md)) did the same 48 s after the end.
  - One in two is too few to blame the switch. The release build already sets it, and dev needs the census to
    measure.
  - **Verdict:** no change. It stays release-only, and dev keeps its diagnostics.
- **`cpu-count=4` (qe3).** 9.1 fps per E-GHz against 12.5. The P cores went unused (P 1 %), acquire went up to
  7.0 ms a frame against 1.3, and the game's Social Club end never triggered.
  - **Verdict: dropped (harmful).**
- **`yield-sleep-us=200 yield-streak=64` (qe4).** 12.4 against 12.5: no effect.
  - **Verdict: dropped.**
- **`MADEIRA_X64_ONCE_FASTPATH=1`, `MADEIRA_FEX_EC_CALLRET_POP=1`, `MADEIRA_ECO_NATIVE=1` together (qa1).**
  11.6 against g1's 11.7 in the same thermal history, with the same CPU power.
  - **Verdict: all three dropped.** Code kept.
- **The dev log cap and its rotation (f)** are now forced on the host. The switch at the cap moved into
  `log_cap.c` (`log_cap_divert`, `log_cap_drain`), and the launch rotation moved into `host_log.c`
  (`host_log_rotate`).
  - `app/tests/log_cap_test.c` runs the switch on a real file with a 4 KiB cap:
    - under the cap, nothing changes;
    - at the cap, the "reached" line is written and stderr's stand-in becomes the pipe;
    - 200 runtime lines are then counted into one report, and none are written.
  - `app/tests/host_log_test.c` checks the rotation:
    - a log over the size becomes the previous log, replacing an older one;
    - a log at the size stays;
    - with no log, nothing happens.
  - Dev IPA `bd2f3384400a987948a07d5e20a910456a00a3b610ce773487a46720a0602421` passed the Hollow Knight first
    frame+10 check to the menu (`.work/ui-runs/20261021T184607`). It was not run with RDR2.

## Not run

- QPC (`MADEIRA_X64_QPC_FASTPATH`) and anything that changes AFP or FPCR were left to a separate worker, with
  the FEX disk-cache-key fix.
- `MADEIRA_POWER_GOV_MW` at a target under ~0.3 W.

Run directories: `.work/agent-notes/pla413e/<run>/`, which holds the screenshots, `press.log`, `walk.log` and
`play/`, plus the `pp ui` run directories above. Each run's summary comes from `xs1-cmp.py`, `arm.py`,
`cabin.py` and `nodiag.py` in `.work/agent-notes/pla413e/`.
