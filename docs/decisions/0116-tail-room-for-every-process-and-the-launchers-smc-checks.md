# 0116: The pool's tail keeps room for every other process; the Rockstar launcher's Open turns SMC checks off

**Status:** accepted, 2026-10-18, chosen under the owner's standing approval of the decisions
needed to bring the Rockstar launcher's sign-in page up (PLA-394). 0115 was left for the Steam
bridge record. [PLA-394](https://linear.app/playportdev/issue/PLA-394),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](../plans/2026-10-16-cef-low-va-build.md),
[evidence](../evidence/2026-10-18-pool-tail.md).

## Context

Every process of a session shares the one JIT pool (896 MiB for the launcher, decision 0108):
x86-64 image copies from the bottom (head), FEX code buffers from the top (tail). Each emulated
process takes a 16 KiB carve and a 16 MiB first code buffer; a process that fills its first
buffer asks for 128 MiB (FEX's maximum), and the tail's cap granted the largest power of two up to
128 MiB that left 48 MiB (`HEAD_RESERVE`) between head and tail.

In the launcher's Opens of 2026-10-18 (fex 0047, [evidence](../evidence/2026-10-18-fex-exit-fault.md)),
the tail reached 416–433 MiB and the head 460–464 MiB in every run, warm or cold cache. Run
`20261018T095950` ended with no window content: at the end the tail held seven processes' 16 MiB
buffers (services, the launcher, Rockstar Service and others), Social Club's browser 16 + 128 MiB,
its first renderer 16 + 128 MiB (granted when only 189 MiB were left), and its second renderer
four 16 MiB generations; the head then grew 60 MiB with late images, head and tail met, and the
second renderer's next buffer was refused (`tail_fatal`). Two processes had also been handed a
free 16 MiB carve for their 16 KiB ask, then carved a fresh 16 MiB for their code buffer. Dead
processes' carves were reused (`tail REUSE`).

With FEX's self-modifying-code checks on (no saved `env.FEX_SMCCHECKS=none`, run `095302`) the tail
passed 560 MiB and Social Club's CEF crashed; the key lived only in a dev build's saved settings,
so clearing them dropped it.

## Decision

- **Tail cap (madeira-unix 0157, all titles).** The room the cap may grant from is the pool less
  head, tail, 48 MiB and 16 MiB for each other process that holds a live tail carve. A lone game
  (its process beside one start process) loses 16 MiB of room and keeps its 128 MiB buffer; in the
  launcher the browser still gets 128 MiB, later renderers less. `tail CAP` and `tail BIG` lines
  print the count. The pool's size, its split and FEX's buffer sizes are unchanged.
- **Small asks (madeira-unix 0157).** An ask below 16 MiB takes a free carve of 16 MiB or more only
  when a fresh carve would not fit.
- **The launcher's runtime keys.** `PublisherLauncher` has compiled `runtime` keys under the ones
  saved for its title id (a saved key of the same name replaces one); `rockstar` has
  `env.FEX_SMCCHECKS=none`. The release app, which reads no saved settings, runs them too. A later
  chunk may let a game inherit a launcher's keys (Red Dead Redemption 2's Steam Play); that is not
  wired here.

## Consequences

- Multi-process sessions (a launcher, Steam's web helper) give late hot processes smaller code
  buffers; they rotate more often instead of running the pool out for everyone.
- Hollow Knight's run is the gate for single-process games; a game whose head is within 16 MiB of
  the old cap's step would get the next smaller buffer.
- Whether the sign-in page paints is measured in the evidence; the head (images) is not changed by
  this record.
