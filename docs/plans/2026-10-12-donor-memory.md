# Plan: guest RAM from donor processes that end after mapping

**Date:** 2026-10-12. **Status:** steps 1, 2 and 3 done 2026-10-14; step 4 in progress (owner: Kingdom Come is on the phone).
**Linear:** [PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Branch:** `research/extended-memory`, rebased onto `main` (`6ad89e8`). It is
not merged. Last built at `25f484d` (IPA `d8226b20…`, step 3).

## Progress

Run with the plan-runner skill (supervisor plus one writer at a time). Models
for this run: hard tasks `anthropic/claude-opus-5-5` (medium), easy tasks
`anthropic/claude-sonnet-5-5` (medium). Reports go to
`.work/agent-notes/donor-memory/reports/`.

- **Step 1 done** (`0534342`, `bf013e7`; IPA `19e10116…`): H1 passed for
  both variants at 2048 and 4096 MiB
  ([evidence](../evidence/2026-10-14-donor-memory.md)).
- **Step 2 done, entitled only** (`9552b8b`, `35af59b`; IPA `fc107a8d…`): two
  fresh donors gave 6400 MiB (purgeable), verified at 60 s; the app's
  `os_proc_available_memory` stayed about 8.1 GiB, but with the pool held the
  phone could give only 0–768 MiB more ordinary memory before
  `kern.memorystatus_level` fell under 15 %. **Physical RAM, not the
  per-process limit, is then the wall.** A 60 s background trip kept the app
  and every byte of a 6 GiB pool; right after it the app's available memory
  read 6092 MiB instead of 8140 (one sample, unexplained)
  ([evidence](../evidence/2026-10-14-donor-memory-scale.md)). The writer
  recommends option (a) for step 3: map only committed ranges, size the pool
  from `memorystatus_level`.
- **Settled:** the owner chose no unentitled research IPA for step 2; that
  part is deferred, not done.
- **Step 3 done** (`25f484d`; IPA `d8226b20…`): a 4 GiB pool at Play from
  one donor served Hollow Knight's heap; first frame +9.98 s against
  +10.24 s off ([evidence](../evidence/2026-10-14-donor-pool-at-play.md)).
- **Now:** step 4 (Kingdom Come A/B) in a writer child; its run id is in
  `.work/agent-notes/donor-memory/queue.md`.
- **Queue:** step 4 next. Before its session: a periodic `donor-pool: stats`
  log line (every 30 s), since stats are logged only at first frame and +8 s
  today. Then one locked session: Kingdom Come (379430, PLA-49) with the pool
  off and at 4 GiB (or 6 GiB if the cap allows), through the KCD orchestration
  in [kcd-helper-memory](../evidence/2026-10-03-kcd-helper-memory.md).
  Record peak fpMB against the limit, the pool stats, detaches and purges.
  Then a Hollow Knight `pp perf` A/B, a session longer than 30 minutes with
  the pool on, and one PLA-203-family title for the detach path. Detach,
  purge and reuse have not run on the phone yet. Step 5 follows.
- **Phone (2026-10-14):** dev IPA `d8226b20…` installed, battery 80 % on
  power, 3.7 GB storage free, unattended off. The app was ended after step 3.
  Hollow Knight results are filed on PLA-42.
- **Reports:** `.work/agent-notes/donor-memory/reports/` (step1-writer.md is
  the stopped first writer's partial report; step1-finish-writer.md,
  step2-writer.md, step3-writer.md).

## Why

The app's own memory limit is what ends heavy titles:

- 8 GiB on the reference phone with the entitlement, about 3.3 GB without it
  ([DISTRIBUTION.md](../DISTRIBUTION.md#6-signing-tools-and-the-memory-limit)).
- Kingdom Come peaks at 7.5–8.0 GB, about 200 MB from jetsam with the 512 MiB
  JIT pool (PLA-49, decision 0036).
- Larger titles (an RDR2-class game wants more than 8 GB of RAM plus 2 GB or
  more of video memory, all of it shared RAM on the phone) cannot start
  inside that limit.

The phone has 11.7 GiB of physical RAM. Today the per-process limit, not
physical memory, is the first wall.

## What the branch already showed

From [helper-owned memory](../evidence/2026-10-03-helper-owned-memory.md),
[FEX backing](../evidence/2026-10-03-fex-helper-memory.md) and
[Kingdom Come](../evidence/2026-10-03-kcd-helper-memory.md):

- A memory object the JIT helper creates with
  `mach_make_memory_entry_64(MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED)` and
  sends over XPC is mapped by the app without copying. 4 GiB were fully
  verified in both processes. The **helper's** footprint pays for it, not the
  app's.
- Asking for `VM_LEDGER_FLAG_NO_FOOTPRINT` is refused (`KERN_NO_ACCESS`).
- Backing only FEX's data band moved 30–90 MiB. That is too small to matter;
  the guest heap is the target.
- The ceiling of that design is the app's limit plus the living helper's
  (6 GiB, entitled). Under pressure, jetsam may end the helper.

## The lead

A public iOS emulator's source, released 2026-10-11, does the following.
This is a lead for our own work; no code is taken from it.

1. It starts up to four donor app extensions and spawns a new process for
   each request. Each donor reports `os_proc_available_memory()` and keeps a
   margin back.
2. Each donor allocates with `mach_vm_allocate(VM_FLAGS_PURGABLE)`, wraps the
   memory with `xpc_shmem_create` and sends it in 256 MiB chunks.
3. The app maps every chunk and remaps it into one reserved range.
4. **It then kills the donors** (on by default). The app's mapping keeps the
   memory alive.
5. It hands the range to the Switch guest's RAM as one block, and optionally
   512 MiB to Vulkan buffers through host-memory import.

**Hypothesis H1, from reading XNU and not tested here:** when a task dies,
the objects it owned (purgeable, and probably ledger-tagged ones too) are
disowned. Their pages then count against no process's limit, the app's
included. Only system-wide pressure still applies.

## What stays on the branch

- `app/Sources/SharedMemory`: create, transport, map (also at a fixed
  address), page counts, footprint snapshot, fill/verify.
- The probe: Settings › Developer › Probes, `probe:memory-64|2048|4096`.
- The JIT helper's `memoryAllocate` / `memoryReport` / `memoryRelease`.
- madeira-unix **0147**, a hook for FEX's data band, was removed in step 3:
  it had no release notification.
- madeira-unix **0148**: a hook for fresh RW guest commits of at least 1 MiB
  in `[0x7000000000, 0x7c00000000)`. It records the backed ranges
  (`pp_guest_ranges.h`, host-tested). Before any protection other than plain
  RW, it copies a range back to ordinary memory. It reports releases.
  **It has never run on the phone.**
- The stubs in `WineHostRuntime.swift` answer every hook with "no" in every
  build until step 3 lands.

The patches are numbered 0147/0148, after main's madeira-unix series (through
0146). Renumber them if main's series grows before this branch merges.

Removed: the per-allocation broker (one XPC request per mapping from a living
helper) with its dev switches, `probe:memory-status` and the in-game readout.

## Steps

Each step ends with a commit on the branch and an update to PLA-216. Builds
and phone runs happen only in the main checkout (decisions 0028, 0069).

### 1. Does the memory stay free after the donor dies? (H1)

This is the cheapest test, and it decides the plan.

- **Probe:** extend the probe with a "then end the helper" variant. Settings ›
  Developer › Probes gets a row first (decision 0012), and the driver an
  action for it, e.g. `probe:memory-donor-2048`. The variant fills and verifies
  N MiB as today, then ends the helper with the existing `JitHelper.stop()`
  (`_kill:`) while the app keeps its mappings.
- **Measure:**
  - the app's footprint and `os_proc_available_memory()` before mapping, after
    mapping, and at 5 s and 60 s after the helper died;
  - data verification at each point;
  - `mach_memory_entry_get_page_counts`.
- **Variants:**
  - (a) today's ledger-tagged named entry;
  - (b) purgeable `mach_vm_allocate` in the helper, sent as a memory entry
    (or `xpc_shmem`).
- **Pass:** after the helper dies, the app's footprint grows by less than
  10 % of the mapped size, and the data verifies at 60 s, for at least one
  variant.
- **Fail:** the footprint moves to the app, or the pages are lost. Then record
  it and stop the plan. The earlier helper-owned design remains as an
  app-plus-helper ceiling.
- **Evidence:** `docs/evidence/<date>-donor-memory.md`, with the IPA's sha256.
- **Result (2026-10-14, IPA `19e10116…`):** **pass** for both variants at
  2048 and 4096 MiB. The helper was gone each time (`kill(pid, 0)` →
  `ESRCH`), every byte verified at 5 s and 60 s after its death, and the
  app's footprint fell between `after_map` and `dead_60s` (tagged −43/−27 MiB,
  purgeable −27/−6 MiB at 2048/4096) while `os_proc_available_memory()`
  stayed about 8.1 GiB and the whole mapping stayed resident. Hollow Knight
  reached first frame at +10.71 s on the same IPA. No system-pressure test
  yet (step 2). [Evidence](../evidence/2026-10-14-donor-memory.md).

### 2. How much memory, and from how many donors

- Spawn K helper processes (repeated extension requests). Record each one's
  limit, then kill all of them after mapping. Find the largest verified total
  in the app and the app's own limit afterwards.
- **Without the entitlement:** record what an unentitled donor's limit is,
  and what the app gets with and without donors. This needs a research IPA
  that `pp verify` refuses: ask the owner before making one, and never
  distribute it.
- **System pressure:** with a large pool mapped, open another app, then
  return. Check whether the pool's data survives and whether iOS ends the app
  or the background app.
- **Result (2026-10-14, IPA `fc107a8d…`, entitled only):** probe
  `probe:memory-donors-<total>` (purgeable, 256 MiB objects, each donor's
  available memory less 512 MiB; stop while jetsam's level is under 15 % or
  less than 1.5 GiB is spare). Every round was a fresh helper with 6137 MiB
  available, gone about 100 ms after the stop. **6144 MiB passed twice (two
  donors); 8192 stopped at 6400 MiB** (level 13 %), all 6400 MiB verified 60 s
  after the last donor died. The app's own available memory stayed about
  8.1 GiB, but the phone could give it only 0–768 MiB more: on an idle phone,
  pool plus app gains are bounded by free physical RAM (about 6.4–6.9 GiB
  with the reserve), not by the per-process limit. With 6144 MiB mapped, a
  60 s trip to iOS Settings did not end the app and every byte verified
  after the return; right after it the app's available memory read
  6092 MiB (about a 6 GiB limit) instead of 8140, unexplained. Hollow
  Knight reached first frame at +10.56 s on the same IPA. The unentitled
  part is deferred (owner). [Evidence](../evidence/2026-10-14-donor-memory-scale.md).

### 3. A pool at Play that feeds 0127

- **When:** after JIT activation and the helper's detach, before Wine starts
  (where `SharedMemoryBroker.install()` was). Take a pool of the size a dev
  setting asks for (Settings › Developer › Memory: Off / 2 / 4 / 6 GiB, off by
  default), from donors that then end.
- **Choose one of these and record the choice:**
  - (a) Keep the memory entries' send rights in the app, with no pool
    mapping. Serve each 0127 request by `vm_map` of an entry range at Wine's
    address. Untouched pages are not resident.
  - (b) One contiguous pool view, served by `mach_vm_remap` into Wine's
    address.
- **Reuse must give zero pages,** because Windows commits are zero-filled.
  Measure the options: a `memset` on release, purging a whole purgeable chunk
  once it is free, or never reusing (monotonic, if the pool is large enough).
- **Lifetime:** a release only returns the range to the pool's free list,
  with no IPC. Detaching before a protection change copies to ordinary
  memory: count how often that happens per title.
- **Limits:** raise or remove the 2 GiB bound in 0127 and its interval table
  to match the pool, and keep the host test that checks the bound.
- **FEX's data band (0126):** serve it from the pool too if that is free,
  otherwise remove 0126.
- **Out of scope:** the JIT pool and executable memory stay ordinary.
- **Release:** the stubs stay in release. Release behaviour changes only by a
  decision record with the owner's sign-off.
- **Result (2026-10-14, IPA `d8226b20…`):** done, dev only.
  - **Setting:** Settings › Developer › Donor pool
    (`set:donorPoolMB=0|2048|4096|6144`, off by default).
  - **Option (a):** the app keeps the entries' send rights, and each 0148
    request is a `vm_map` FIXED|OVERWRITE of an unused range of one object at
    Wine's address.
  - **Cap:** the pool is capped at (jetsam level − 15 %) × RAM.
  - **Zero on reuse:** an object is handed out once from its start upwards
    and purged whole (EMPTY, then non-volatile) when its last lease is
    released. On the phone the purge took 8.4 ms per touched 256 MiB, freed
    the pages and left the charge with no process. A memset took 12.1 ms but
    left the pages resident. The bookkeeping is host-tested
    (`app/tests/guest_pool_test.c`).
  - **0148:** it reports `(address, size, detached)`, and its table is
    bounded by 8 GiB on 16 KiB pages. 0147 is removed: it had no release
    notification.
  - **Hollow Knight with 4 GiB:**
    - one donor, installed in 0.72 s;
    - by first frame + 8 s, 56 requests (400 MiB) were served, 286 MiB of
      them resident, 0 detaches, 0 purges;
    - the app's footprint at the end was 343 MB lower than with the pool
      off;
    - first frame at +9.98 s with the pool, +10.24 s without.
  - **Not yet exercised on the phone:** detaches, purges and reuse.
  [Evidence](../evidence/2026-10-14-donor-pool-at-play.md).

### 4. Does it help a game?

Measure these in one locked session each, pool off and on:

- **Kingdom Come** (PLA-49): its peak `fpMB` against the limit, through the
  same orchestration as the KCD evidence. Then raise the RAM and video memory
  the game is told it has, and check that it still loads Rattay.
- **Hollow Knight:** a launch to first frame +10 and a gameplay `pp perf` as
  the regression, with first-frame time and FPS unchanged within noise.
- **One session over 30 minutes** with the pool on.

Each game's Linear issue and `site/compatibility/games.json` get the result.

### 5. Graphics memory (stretch)

Graphics memory is charged to the app's own limit and is a large share of an
AAA game's memory.

- **DXMT:** look at `newBufferWithBytesNoCopy` on pool memory for large
  buffers.
- **KosmicKrisp:** look at host-pointer import (`VK_EXT_external_memory_host`)
  for buffers.
- **Textures:** they probably stay ordinary.
- **Next step:** this gets its own issue once step 3 holds.

## Risks

- The technique depends on how XNU accounts for memory and on private
  `NSExtension` calls (Playport already uses those for JIT). An iOS update can
  close it, so it is dev-only first and needs a fallback to ordinary memory.
- System-wide memory pressure still applies, so the phone as a whole can run
  short. Step 2 checks what happens.
- 0127 changes how Wine backs large heaps. A wrong detach or release
  corrupts guest memory, so step 3 needs Hollow Knight, Kingdom Come and one
  DRM/self-modifying title (the PLA-203 family) before anyone relies on it.

## Not done

Steps 4 and 5, and the unentitled part of step 2. Nothing from this branch is on
`main`.
