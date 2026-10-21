# ppsync on the phone: Hollow Knight and RDR2's launcher (PLA-427)

**Linear:** [PLA-427](https://linear.app/playportdev/issue/PLA-427), PLA-364 (RDR2), PLA-42 (Hollow Knight).
**Decision:** [0157](../decisions/0157-ppsync.md) (proposed). **Plan:** [ppsync](../plans/2026-10-21-ppsync.md).
**Patches:** `patches/wine-unix` 0045, `patches/madeira-unix` 0220, `build/ppsync`.

The runs are in `$PLAYPORT_BUILD/ui-runs/<run>`. Every run used the defaults of decision 0153.
RDR2 also used `--pad --action set:donorPoolMB=auto` with an empty runtime string. It played the
Steam copy in Story mode.

## IPAs (dev)

- `87e05252eb07e97677b1e640dae715a143073a1b4cf9ad9e336a0a4e771e36e0`: ppsync as first merged onto
  `c2ed344`, with the hand-off keyed by process id.
- `539acc1db2b9fe4fe1a1b6d8b159be25cf080191d30631b1e7b4a7b008b971e0`: as above, plus replacing and
  evicting untaken hand-off entries, with each one logged.
- `f8a0653e4c01e1095c20b0d1e96b2531d6e0988df4832c62ba63db5e4e5fc0ed` (commit `b39972b`): the hand-off keyed by the Wine thread id.

## Results

| Run | IPA | Title | Result |
| --- | --- | --- | --- |
| `20261021T235902` | `87e05252` | Hollow Knight | first frame +11.67 s; black at +10, rendering at 60 fps |
| `20261022T000044` | `87e05252` | Hollow Knight | title menu at first frame +20 |
| `20261022T000210`, `001107`, `001437` | `87e05252` | RDR2 | "Unable to launch game" after the first frame (3 of 3) |
| `20261022T000624` | `87e05252`, `inproc-sync=0` | RDR2 | launcher ended with code 0 at sign-in (+100.2 s), the game ran |
| `20261022T003947` | `539acc1d` | RDR2 | launcher ended with code 0 at sign-in (+118 s); the owner saw the game's menu |
| `20261022T004932` | `f8a0653e` | Hollow Knight | title menu at first frame +10 (first frame +11.47 s) |
| `20261022T005023` | `f8a0653e` | RDR2 | landing with Story selected; Launcher.exe ended with code 0; no box |

Hollow Knight on `87e05252` made about 580 server requests a second, with no event or semaphore
requests. Main's IPA `41431327` made about 1,500 a second in run `20261021T220729`. The
`[kk-gpu]` load was the same in both, at 60 fps. Frame rate and power were not compared; PLA-427
covers that.

## The RDR2 failure on `87e05252`

The sequence in each failing run was:

1. About a second before the game's sign-in (+99.4 s; the passing run signed in at +100.2 s),
   the launcher's Social Club browser and its renderer stopped with `0x80000003`. The game's own
   Social Club helper did the same.
2. The breakpoint is at `libcef.dll`+0x59ea82e. With the low-VA build's PDB that is
   `base::WaitableEvent::TimedWaitImpl`, `base/synchronization/waitable_event_win.cc:119`. That
   line is the `NOTREACHED()` after `WaitForSingleObject` returns `WAIT_FAILED`.
3. Launcher.exe then exited non-zero. PlayRDR2 showed "Unable to launch game", and its OK ended
   the play.

Each failing log has one `[ppsync] hand-off table full; pid 0254 handle 0x20c dropped`. The take
found nothing, the wait failed with an invalid handle, and that is the crash.

The logging run (`003947`) showed where the entries came from. A thread whose TEB gives pid
`0x20` asked for descriptors that the server posted under pid `0x3e4` (`hand-off missed: pid
0020` next to `hand-off replaced: pid 03e4`, more than 513 times). Each miss left one entry in the
1,024-slot table. The thread's request went back to the server each time, so nothing showed until
the table was full.

The server's `current->id` and the client's `thread_data` tid both come from `init_thread`'s
reply, so they always agree. On `f8a0653e` the hand-off is keyed by that thread id and no take
missed. Untaken entries are still replaced or evicted, and logged, so they cannot fill the table
again.

## Not shown

- The Witcher 3 and the rest of the cohort were not run.
- No `pp perf` comparison against fastsync was made (PLA-427).
- The owner has not played on `f8a0653e` and signed off (PLA-427).
