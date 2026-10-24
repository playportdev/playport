# Descriptor sink/append device gate: interrupted

**Date:** 2026-10-24. **Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431),
with a bounded [PLA-440](https://linear.app/playportdev/issue/PLA-440) session note below.
**Conclusion: gate not passed, not failed — interrupted; device-side emission
remains unverified.** This is a host-only recording of the supervisor's completed
attempt, not a new phone session, runtime diagnosis or measurement.

## Provenance and install

- Branch `dev/kk-proton-parity`, recorded run HEAD `1c8534e`, dev IPA
  `.work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa`.
- IPA SHA256: **`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`**.
- Run directory: `.work/ui-runs/descriptor-append-gate-dxvk-on-20261024/`.
  Retain `events.jsonl`, `timeline.txt`, `screen-stop.png`, `pull/s1-host.log`
  and `pull/run-events.jsonl` there, unchanged. No screenshot is published here.
- Supervisor script `.work/agent-notes/kk-parity/gate-session.sh` ran one
  announced, share-free, single-lock session: upgrade in place, then the DXVK
  diagnostic launch. Session `f99ce5c4ed49` ended with wrapper exit **11**
  (the script maps the UI command's nonzero exit to 11); the lock was released.
- Install source: `.work/agent-notes/kk-parity/gate-install.log`:

```text
21:10:23  free-team apps: 2/3; Playport installed; 4006 MB free
21:10:24  IPA .work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa
21:10:24  sha256 31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122; profile valid for 166 h more
21:10:26  closing the running app (pid 33472)
21:10:31  installing (about 300 MB; keep the phone awake and unlocked)
21:11:04  installed in 33 s: upgrade in place, container kept
21:11:04  done: open Playport from the Home Screen (profile valid until 2026-10-31 18:58); log .work/install-runs/20261024-211021
```

## Exact UI invocation and outcome

The following is the historical argv from the script/retained `argv.txt`, not a
retry instruction. Shell continuation and quoting below preserve the arguments:

```sh
./pp ui --action hud:off --action set:cpuProfile=false --action set:passProfile=false \
  --action set:gpuCaptureFrame=0 --action set:runtimeCountersOff=false \
  --settings 'app-367520:{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d11","graphicsOptions":"MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1"}' \
  --play app-367520 --until first-frame+10 --wait 120 --pad --shot \
  --out .work/ui-runs/descriptor-append-gate-dxvk-on-20261024 \
  --expect-ipa .work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa
```

The exact `--settings` string is the single-quoted `app-367520:{...}` argument
above. Settings were session-scoped: no `--keep-settings`, nothing made
persistent. Nothing was played.

Final `event:"result"` line, identical in the notes' `gate-dxvk-on.jsonl` and
run's `events.jsonl`:

```json
{"t": 1792869103.792, "event": "result", "ok": false, "exit": 1, "done": "cancelled: Playport left foreground (inactive/background)", "out": ".work/ui-runs/descriptor-append-gate-dxvk-on-20261024", "until": "first-frame+10", "until_reached": false, "timeline": ["title: +0.79 s surface ready; asking for JIT", "jit: acquire(896 MiB) -> 0 after 3.31 s", "title: +5.47 s runtime started", "title: +6.59 s game started"], "ipa_sha256": "31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122", "selfcheck": {"report": "ok page=16384 tsd=key 296 slot 296 pool=0x10a4b0000+896MiB rw=0x7008d40000", "teb": "key 297 slot 297"}, "pool": {"size_mb": 896, "head_mb": 37, "head_live_mb": 37, "head_free_mb": 0, "tail_mb": 49, "tail_live_mb": 49, "room_mb": 810, "alias": 4, "alias_slots": 4, "alias_cap": 4096, "images": 43, "children": 2, "children_mb": 2, "trimmed_mb": 8, "head_exhausted": 0, "tail_refused": 0, "tail_fatal": 0, "alias_full": 0, "exhausted": "none"}}
```

Last progress marks in `timeline.txt` (no first-frame mark):

```text
title: +0.79 s surface ready; asking for JIT
jit: acquire(896 MiB) -> 0 after 3.31 s
title: +5.47 s runtime started
title: wine_host_session_launch -> 0
title: +6.59 s game started
```

The retained stop screenshot shows Playport's Hollow Knight launch artwork,
“Waiting for JIT…” and the no-controller notice, not a rendered game frame or
menu observation. It does not override the timeline or prove a foreground-loss
cause. The pulled app event file is cumulative; only nonce `afcd7ce0` belongs to
this launch. Its cancellation and startup marks are not earlier first-frame
entries from other launches.

## Phone status and interruption boundary

Supervisor's already-completed status outputs, recovered read-only from its
saved session; selected fields transcribed under
`.work/agent-notes/kk-parity/gate-interrupted/status-excerpts.md`:

| Status time (local, +02:00) | Battery | External power | Charging | App pid | Free space |
| --- | --- | --- | --- | --- | --- |
| Before, 21:10:08 | 30 % | false | false | 33472 | 4.0 GB |
| After, 21:11:55 | 32 % | true | true | null (not running) | 4.1 GB |

The owner reclaimed the phone and plugged it in (supervisor/owner context).
The battery/power change and foreground-loss cancellation are the recorded
observations, not proof of the exact cause or timing of the foreground change.
No causal diagnosis is drawn from them. The batch cancelled, stopped input and
released the lock; there was no automatic relaunch or retry.

## Raw integrity and limits

Whole pulled raw `.work/ui-runs/descriptor-append-gate-dxvk-on-20261024/pull/s1-host.log`:

- Size: **1,590,760 bytes**.
- SHA256: **`9c51f2bf2719ceeccb92c9b64c00b35ea1fe01dc6626822abe53161fda74b330`**.
- Lines containing literal `kk-descriptor`: **0** (whole-file byte-line count,
  not a descriptor measurement or strict-parser acceptance).

The run ended before any draw/first frame. It neither confirms nor refutes the
[sink/append repair](2026-10-24-descriptor-append-cause-host.md). **No observation
of the native banner, calibration rows, captures or poison exists from this
run.** Old native absence stays **“unobserved, never zero”**; zero marker lines
here is a log-content fact, not zero descriptor activity/cost. No strict-parser
measurement result is claimed; no old raws were re-parsed for this record.

The resolved review's device gate still needs the whole raw and strict-parser
result, the native banner, **16 calibration rows and complete 10-row native
captures**, or the new sink-identifying poison as diagnostic failure evidence
(never a measurement pass). The required full emission/smoke gate remains **unrun**;
this interrupted attempt does not satisfy it. Device-side emission, A0
justification and A2 remain gated. Next is a fresh owner-authorized device gate,
with the phone handed back and left untouched for a few minutes, Playport kept
visible; no retry is authorized by this host-only record.

## PLA-440: one live session interruption

This was the first live interruption of the new deterministic UI-session gate:
the batch cancelled rather than continuing input after Playport lost foreground.
No input followed the loss, the lock was released, and no automatic relaunch
occurred. This is **one occurrence**, not proof that the app-side marker path
confirms cancellation. The retained `ui-done` event is recorded, but does not
close the separate marker-path confirmation work or establish general safety.

**Games observed:** Hollow Knight (`app-367520`) launched on IPA
`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`, run
`.work/ui-runs/descriptor-append-gate-dxvk-on-20261024/`, and reached “game
started” (+6.59 s), but was cancelled before any frame. **No first frame, no
gameplay, no native emission observation.** This writer ran no phone commands.
