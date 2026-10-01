# Hollow Knight at 120 FPS: whole-phone power and the CPMS budgets

Status: measurement and tooling only; no runtime change. Dev IPA sha256
`658973e9c31ca12d1127ea6ce28fe77900e7dc6d8465e4abe8ee6696c1702c7e`
(Wine 11.18, `madeira-unix` 0027, `dxmt` 0008 and 0009), iPhone Air
(`iPhone18,4`), iOS 27.0, on a 15 W charger at the 80 % charge limit. Every run
is `pp perf` on the usual route (`--pad first-frame+25:hk-new-game --pad
first-frame+75:hk-walk`) with the helper threads at `utility` QoS
(`WINE_IOS_THREAD_QOS=UnityGfxDeviceWorker=utility,Job.Worker=utility,Background Job.Worker=utility,dxmt-=utility,Loading.=utility`,
[thread-QoS record](2026-09-25-hk-thread-qos.md)). The run directories are in
`$PLAYPORT_BUILD/perf-runs/` (w1118-qos, w1118-qos-notso, w1118-qos-sys,
w1118-power); they are not committed.

**Result:** King's Pass at 120 FPS at native resolution holds for only 30 to
40 s of play. Then thermal pressure reaches 20, the process loses the P cores
and play settles at 80 to 93 FPS on the E cores with the GPU clocked down (10 ms
GPU time at 94 % busy). The phone as a whole draws about 4.2 to 4.6 W in that
throttled state, and the menu at 120 FPS draws 2.8 to 3.2 W. The process's own
CPU energy is only 1.1 to 1.5 W during 120 FPS play, so most of the power that
has to go is outside the CPU cores: the GPU and memory traffic.

## 1. What `pp perf` could not see, and the fix

- **The budget column was always empty.** iOS 27 no longer logs CPMS
  `Budget Trace` lines. The kernel now logs
  `ApplePPMPolicyCPMS::setDetailedThermalPowerBudget: clientId N, details D,
  Thermal Budget MW` once a second for each client while that budget binds.
  Clients 7 (three details), 9, 10 and 11 appear. `pp perf` now captures both
  forms; the budget column is the lowest in the bucket, and summary.json has
  `budget_first_s` and each client's lowest (`budget_clients`).
- **`--cool BUDGET` could not work.** The budget lines stop within a minute of
  the load ending: a live read about 60 s after a throttled run found none. So
  their absence says nothing about how warm an idle phone is, and the phone
  exposes no temperature (the battery's `Temperature` keys read 0 over
  `diagnostics battery`). `--cool MIN` now waits until MIN minutes have passed
  since the last `pp perf` run ended (`$PLAYPORT_BUILD/perf-last.json`).
- **Whole-phone power.** `diagnostics battery single` has the gauge's
  `PowerTelemetryData`: `SystemLoad` (mW, whatever supplies it),
  `SystemPowerIn` (from the charger), `BatteryPower` and accumulators.
  `pp perf` samples it every 5 s into power.txt (the `sysmW` and `batmA`
  columns). The gauge updates the value only about every 20 s, so it averages
  over four 5 s buckets. tools/tests/test_perf.py covers both new sources.

## 2. Runs

| run | start | 120 FPS play until | pressure 10 / 20 at | then | notes |
| --- | --- | --- | --- | --- | --- |
| w1118-qos (300 s) | 4 min after the previous run | t = 120 | 115 / never (mTLL 1) | 81 to 94 FPS on E cores | P cores lost at t = 125 with pressure still 10 |
| w1118-qos-notso | right after | - | 25 / - | presents stop at t ≈ 35 | `FEX_TSOENABLED=0`: the game hangs entering a new game |
| w1118-qos-sys (180 s, `--syslog-all`) | right after | t = 110 | 90 / 115 | 80 to 90 FPS | budgets from t = 95 |
| w1118-power (200 s) | 3 min after | t = 110 | 90 / 110 | 79 to 90 FPS | first run with power.txt |

`t` counts from the first Metal HUD line; play starts at about t = 85.

## 3. Power (w1118-power)

| phase | FPS | process CPU (`[xp]` mW) | phone `SystemLoad` |
| --- | --- | --- | --- |
| menu, save slots (t = 40 to 75) | 120 | 290 to 480 | 2.8 to 3.2 W |
| loading King's Pass (t = 80) | 80 | 2,260 | ~2 W window |
| King's Pass play (window ending t ≈ 100 to 115) | 120 | 1,020 to 1,520 | 8.7 W (battery also supplying) |
| King's Pass play, pressure 20 (t = 120 to 200) | 80 to 90 | 280 to 360 | 4.2 to 4.6 W |

Budgets during play: client 9 fell from about 2.0 W at pressure 20 to 660 mW,
client 10 from 2.9 W to 1.1 W, client 7 from 3.5 W to 2.5 W; client 11 dipped to
769 mW. Which rail each client budgets is not known.

In the throttled state the process's CPU is 250 % of a core on the E cores at
1.3 to 1.7 GHz; the main thread is 92 to 95 % busy at 21 to 22.5 Mi/f and caps
the frame at 10.5 to 11 ms, while the GPU also needs 10 ms at its lower clock.
To hold 120 FPS in that state both would have to shrink by about a quarter,
or 120 FPS play must fit in the roughly 4.5 W the phone sustains.

## 4. What this rules out and what it points at

- `utility` QoS for the helper threads still leaves the drop at the same
  point: it moves work off the P cores but does not cut enough power.
- Turning FEX's TSO emulation off for the whole process is not usable: Hollow
  Knight hangs entering a new game. Narrower options remain (FEX's
  `VolatileMetadata` and `ExtendedVolatileMetadata` per module).
- Play at 120 FPS draws roughly 5 W more than the menu at 120 FPS, while the
  process's CPU accounts for about 1 W of that difference and the GPU time per
  frame is about the same (6.2 to 6.5 ms). The next step is to find where the
  rest goes: GPU work per frame at the clock the GPU runs, memory bandwidth
  (full-resolution passes, the three blits that split King's Pass into render
  passes: [GPU passes](2026-09-26-hk-gpu-passes.md)), and the CPU-side
  fabric. A per-bucket `SystemLoad` from `AccumulatedSystemLoad` deltas (now
  recorded) will make those comparisons finer than the 20 s gauge value.
