# RDR2 with the owner's chosen defaults (owner-run test)

**IPA:** dev `3e260842aec44a3300b1e41757423c6bdd4fa5eef619a6a2584633e98326368c`
(`.work/out/20261020-155847-3e260842/`). **Decision:** [0142](../decisions/0142-rdr2-owner-test-defaults-heap-size-sync-and-afp.md).
**Linear:** PLA-413, PLA-364.

## What the build changes

RDR2's (`app-1174180`) compatibility default gets four runtime keys besides `jumbo-mb=8960`. Each
is the owner's choice for a test the owner plays; a dev build's Runtime keys row overrides each:

| Key | Effect | Override |
| --- | --- | --- |
| `env.PLAYPORT_VK_HEAP_MB=3072` | KosmicKrisp reports heap 0 as 3,072 MiB, not 8,192 (mesa 0064); the plan's budget cap of 3,072 MiB is unchanged | `env.PLAYPORT_VK_HEAP_MB=0` |
| `env.MADEIRA_FASTSYNC_SEM=1` | semaphores get fastsync cells; inert while `inproc-sync=1` (below) | `env.MADEIRA_FASTSYNC_SEM=0` |
| `env.FEX_HOSTFEATURES=disableafp` | FEX runs without FEAT_AFP: no FPCR write at each x64-to-ARM64EC call and return (patches/fex 0005); the app adds the CPU's own switches (`enablelrcpc2`) after it | `env.FEX_HOSTFEATURES=enableafp` |
| `inproc-sync=1` | Madeira's in-process sync (madsync) for the session; it turns fastsync off | `inproc-sync=0` |

`inproc-sync=1` is the owner's choice for this test: it keeps decision 0023's defects (a thread
blocked in madsync runs no system APC, so an async completion such as a named-pipe read's can be
lost; one global mutex).

## Host checks

- `build/stages/mesa.sh $PLAYPORT_BUILD/run/mesa host hosttest`: passed. New check
  `check_heap_cap`: `PLAYPORT_VK_HEAP_MB=1536` gives heap 1,536 MiB, budget at most 1,536; 100 and
  5,120 (the mock's working set) are ignored; with `PLAYPORT_VK_BUDGET_MB=1024` and heap 3,072 the
  heap is 3,072 and the budget 1,024; two 192 MiB allocations succeed under a 256 MiB heap.
- `./pp test`: all passed.

## Phone

- Hollow Knight first frame+10 on `3e260842`: passed (run `.work/ui-runs/20261020T155956`, first
  frame at +9.03 s).
