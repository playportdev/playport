# RDR2: the Mach exception thread registry ran full; threads now give their slots back (PLA-364)

**Linear:** PLA-364 (RDR2 gameplay), PLA-416 (ending terminated pseudo-processes).
**Decision:** [0134](../decisions/0134-a-thread-gives-back-its-exception-registry-entry-when-it-ends.md).
**Change:** madeira-unix 0173 (`pp_thread_slots.h`), test `tools/tests/test_thread_slots.py`.

## 1. What run m10b's log shows

This is run `$PLAYPORT_BUILD/ui-runs/20261020T073042-rdr2-m10b` (IPA `500381f6`), its
`pull/s1-host.log`. The log is counted up to the `[thread-registry] FULL` line (line 185,886);
see [the kk-memory evidence](2026-10-20-rdr2-kk-memory.md), section 6.

- **Registrations.** `Mach exception handler registered thread` appears 512 times. Every thread
  of every pseudo-process registers once, at `init_syscall_frame`.
- **Ended threads.** There are 350 distinct `[srv-kill] kill_thread tid=` lines, in 11 processes
  (`[srv-kill] kill_process`): the session root's helpers, the Rockstar launcher tree (ended under
  0130), the game's own Social Club helpers (0133 was on: `set:endGameSocialClubAfterSignIn=true`),
  and their restarts.
- **Parked threads.** There are 35 `[proc-end] parked` lines. Parked threads stay Mach-suspended
  for ever (0127).
- **Live threads.** So at the FULL line about 162 registered threads still existed, of which 35
  were parked. About 127 were running. With the give-back, the phone runs in section 3 had at most 284
  live at once, earlier in the session.
- **The registry never gave a slot back.** Entries were handed out by a high-water mark
  (`ios_thread_count`). Thread exit, `pthread_exit_wrapper`, did not touch the registry, and
  neither did a process's teardown. The only existing release, `ios_thread_registry_forget`, clears
  the TEB of a torn-down WoW64 window's threads but keeps the entry. Port names are pinned
  (ml401), so an entry was not even reused by a recycled name.
- **The trampolines ran out first.** The JIT pool's TEB-restore trampoline slots (256, also never
  given back) ran out at line 80,397 (`allocated trampoline slot 255`). From then on, 257 threads
  got slot 0 and wrote their TEB into the first thread's slot (`allocated trampoline slot 0` × 258).
- **What FULL means.** A thread that is not in the registry has its Mach exceptions resolved to
  the slot-0 TEB, the first process's. Thread 0878 of RDR2.exe (pid 0414) was the 513th; a second
  one, 087c, followed. RDR2 then ended with 0xc0000005.

## 2. The change (madeira-unix 0173)

- **At thread exit** (`pthread_exit_wrapper`, last before `pthread_exit`), a thread gives back its
  registry entry and trampoline slot.
- **A parked thread gives back both when it is parked.** It is never resumed, so it cannot fault.
- **A registration reuses the lowest free entry** before raising the mark.
- **The trampoline page holds 1,024 slots** (0x4000 / 16), not 256.
- **The logging.** Each give-back logs `[thread-slots] port=… ended|parked: idx=… tramp=… live=N`,
  and each registration line now ends with `live=N`.

**Host checks** (`tools/tests/test_thread_slots.py`, in `pp test`):
- the claim, publish, release and find order;
- a claimed entry naming no thread until it is published;
- a claim that races a free-entry scan at the mark;
- 8 threads making 160,000 registrations and releases with no entry held twice;
- the trampoline slots, with slot 0 never given back.

`./pp build` built the dev IPA `82b9cd29`, and `./pp test --quick` passed.

## 3. On the phone: IPA `82b9cd29`

- **The IPA.** sha256 `82b9cd292a0ddafc96a0dbafad835f75b6ee407a2a5497c94e71721dd53ffbb8`, upgraded in
  place.
- **Hollow Knight.** The first frame+10 check passed (`…T075811`). It logged one `[thread-slots] …
  ended` line, with registrations at `live=46`–`58`.
- **The RDR2 runs.** Three Story runs, all with the same settings as m10b:
  - `set:endGameSocialClubAfterSignIn=true` (0133) and `donorPoolMB=auto`;
  - the game's own lowest graphics settings;
  - A pressed by hand on the Story tab, 132–155 s after the first frame, once a screenshot showed
    "Story (A)".
  - The Online tab, its policies page and LB were never touched.
- **The run directories** are under `$PLAYPORT_BUILD/ui-runs/`, and the screenshots under
  `$PLAYPORT_BUILD/agent-notes/pla364r/`.

| Run | Registrations | Highest live | `FULL` | How it ended |
| --- | --- | --- | --- | --- |
| `…T075952-rdr2-r1` | 515 (314 ended, 35 parked give-backs) | 284 | none | jetsam `per-process-limit` at 08:07:54, in the Story load (loading spinner), 235 s after A |
| `…T080946-rdr2-r2` | 510 (310 ended, 34 parked) | 282 | none | jetsam at 08:17:46, in the intro's 3D cutscene, 218 s after A |
| `…T081941-rdr2-r3` | 516 (317 ended, 33 parked) | 281 | none | jetsam at 08:30:59 (8,193 MB), after 2.5 min of gameplay |

**What the registry did.**
- In every run the registrations passed m10b's 512, with no `[thread-registry] FULL` and no
  `[reg-miss]`.
- Freed entries were reused: the highest entry index (280–283) stayed at the most entries live
  at once (281–284, in the middle of the session, while the launcher tree and the game ran
  together).
- Trampoline slot 0 went to the first thread only.
- No run ended with RDR2's 0xc0000005.
- All three ended at the app's 8,192 MB memory limit (jetsam), as the Story runs before m10b did.

### Gameplay with movement (r3)

From 150 s after A, a script (`mover4.sh`) pushed the left stick, then rested for 15 s, six times.
Each push was forward, left, back, right and forward again, 4 s each, so 20 s in all. The pushes
started at 08:27:23, 08:28:11, 08:28:58, 08:29:42 and 08:30:25 (`mover.log`); the app ended
before the sixth. The
screenshots, about one every 10 s:

- **08:27:35 — the intro cutscene.** It shows the cabin's 3D interior and two figures, and a
  Social Club sign-in notice (its name is not copied here).
- **08:28:21 — gameplay.** Arthur stands, seen from close behind, with the HUD: the minimap at the
  lower left and the prompt "Sit (Y)".
- **08:28:32–08:29:09 — Arthur has moved.** The view changes, and the prompt becomes "Search
  Drawer (X) / Nightstand": he has walked to a nightstand.
- **08:29:23–08:29:57 — darker views of the cabin,** with the minimap.
- **08:30:14–08:30:36 — another part of the room.** It shows a wall post, the bunks and a window,
  with "Sit (Y)". On the minimap the player's marker has moved within the cabin's outline, and the
  outline has turned against 08:28:21.
- **08:31:07 — Playport's own screen.**

So the character walked and turned under the stick for about 2.5 min, with four 20 s pushes in
gameplay. No prompt was pressed: no Sit, no Search and no menu.

### Frame rate in r3's gameplay (`[frames]`, 10 s buckets)

- **From 08:28:00 to 08:29:30: 10–14 fps.** No shader was translated or built.
- **From 08:29:30 to 08:30:50: 6–18 fps.**
  - KosmicKrisp built 35 new Metal pipelines in this stretch, 0.6–5.8 s each, 78.6 s in all.
    That is about one build running at all times (`[kk-compile] render ms=…`).
  - None of them needed a NIR→MSL translation: `translated=0`, as every shader came from the disk
    cache.
- **The frame rate stayed above zero during the builds:** 11–18 fps in the first minute of
  builds, 6–10 fps at the end.
- **The thermal state was `serious`.**

### Save slots after r3

The save files are compared with `agent-notes/pla413c/save-backup-0`, by sha256 only. Nothing
was restored.

- **`SRDR30000`:** unchanged (671,744 bytes).
- **`SRDR30015`:** changed, 674,208 → 672,416 bytes, and a new `SRDR30015.bak` of the same size
  appeared.
  - This is the game's own write on entering the Story.
  - No save or menu was used in any run.
  - Whether m10b had already written it is not known: there was no check after m10b.
- **`Player`, `cfg.dat` and `cloudsavedata.dat`:** changed.
- **`ProfileSettings`:** unchanged since the graphics settings were lowered in an earlier run
  (`save-after-sc4`).

## 4. The performance suspicion (m10b's 4.5 fps)

- **m10b's translations held up the frames.**
  - In m10b, 07:38:07–07:38:56 rendered 80 frames in 49.6 s, 1.6 fps.
  - The 7 NIR→MSL translations took 48.6 s in all. The `[kk-compile]` totals add up each call's
    wall time, so they ran one after another, all in that window.
  - The CPU was mostly idle then (`[xp] cpu` fell from 4,175 to 726–1,069). The busiest threads
    were the wineserver thread (`m6481236`) and one game thread.
  - So the frames wait on the translation: a serial, single-thread wait, not contention with the
    render thread for CPU.
- **Inference: the 7 s per translation**, against 3.3 s earlier, fits the P cores at 1.31 GHz
  (thermal `serious`). It does not fit contention, since the CPU was idle.
- **r3 had no translations.** Its gameplay ran at 10–14 fps with no shader work.
- **r3's pipeline builds did not stall the frames.** Its new Metal pipeline builds (0.6–5.8 s
  each) cost frames, 6–18 fps, but did not stop them as m10b's translations did.
- **Not shown:** which thread runs each translation and each build. The `[kk-compile]` lines carry
  no thread id.

## Not shown

- **Gameplay longer than about 2.5 min.** Every Story run ends at the 8,192 MB memory limit:
  either in the load or in the intro (r1, r2), or in gameplay (r3).
- **What changed `Player`, `cfg.dat` and `SRDR30015`:** whether r3 or an earlier run wrote them.
