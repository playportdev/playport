# 0142: RDR2's owner-test defaults: a 3,072 MiB heap, fastsync semaphores, FEX without AFP

**Status:** accepted, 2026-10-20, as the owner's chosen defaults for a Red Dead Redemption 2 test
the owner plays on the phone (PLA-413, PLA-364). Amends
[0106](0106-8gb-row-in-full-and-vulkan-plan-default.md): KosmicKrisp's heap size may follow a title's
value, not only its budget. Revisit with the owner's results: each default stays only if that play
supports it. **Amended the same day:** `inproc-sync=1` is dropped from the default after the
owner's first play (below, and the evidence).

## Context

- **RDR2 reads the heap's size, not its budget.** KosmicKrisp reports heap 0's size as Metal's
  `recommendedMaxWorkingSetSize`, 8,192 MiB on the reference phone, and patches/mesa 0036's
  `PLAYPORT_VK_BUDGET_MB` (the plan's video figure, 3,072 MiB, by 0106) caps only the
  `VK_EXT_memory_budget` budget. RDR2's Graphics settings show 8,192 MB of video memory. Since
  madeira-unix 0179 fixed its camera aspect its footprint passes the 8 GB limit about 6 minutes into
  a play (run f3, 8,118 MB).
- **The owner chose the rest for the same test.** `MADEIRA_FASTSYNC_SEM=1` (semaphores in fastsync
  cells) and `FEX_HOSTFEATURES=disableafp` (no FPCR write at each x64-to-ARM64EC call and return,
  patches/fex) were open CPU items; `inproc-sync = 1` turns on Madeira's in-process sync (madsync),
  off by default since [0023](0023-in-process-sync-stays-off.md).

## Decision

- **`PLAYPORT_VK_HEAP_MB=N`** (patches/mesa 0064): heap 0 is reported as N MiB when N is 256 or more
  and under the working set; the budget is never over it. Allocations past it still succeed: nothing
  in the driver checks an allocation against the heap's size (the mesa host test allocates 384 MiB
  under a 256 MiB heap). Unset, nothing changes.
- **RDR2's compatibility default (`app-1174180`) adds three runtime keys** to `jumbo-mb=8960`:
  `env.PLAYPORT_VK_HEAP_MB=3072 env.MADEIRA_FASTSYNC_SEM=1 env.FEX_HOSTFEATURES=disableafp`. Like
  any runtime key of a default, a person's Runtime keys row (dev build) overrides each by key:
  `env.PLAYPORT_VK_HEAP_MB=0`, `env.MADEIRA_FASTSYNC_SEM=0`, `env.FEX_HOSTFEATURES=enableafp`
  (FEX's own default on iOS).
- **`inproc-sync=1` is not a default.** The owner chose it too, and the first build had it. The code
  runs one in-process engine per session: with madsync's device handed out, ntdll's fastsync is off
  whatever `MADEIRA_FASTSYNC` says and the server allocates no cells, so the semaphore switch did
  nothing. In the owner's first play the Rockstar launcher could not open the service control
  manager (`Unable to open SC manager! (1722)`) and showed "Failed to connect to the Rockstar Games
  Library Service"; RDR2.exe never started. With `inproc-sync=0` the launcher started the game.
  The service manager's RPC runs over a named pipe, the case 0023's defect names. A person can still
  set `inproc-sync=1` in the Runtime keys row.

## Costs and risks

- **A 3,072 MiB heap is a smaller pool target for the game**; a game that refuses a setting it
  thinks the heap cannot hold may lower its own quality or refuse a preset.
- **The defaults reach a release build too**, where a person cannot override runtime keys (0126).
