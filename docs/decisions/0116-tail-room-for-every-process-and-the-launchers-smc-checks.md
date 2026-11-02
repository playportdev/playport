# 0116: The pool's tail keeps room for every other process; the Rockstar launcher's Open turns SMC checks off

**Status:** accepted, 2026-10-18, chosen under the owner's standing approval of the decisions
needed to bring the Rockstar launcher's sign-in page up (PLA-394). 0115 was left for the Steam
bridge record. [PLA-394](https://linear.app/playportdev/issue/PLA-394),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](https://linear.app/playportdev/issue/PLA-370),
[evidence](../evidence/2026-10-18-pool-tail.md).

**Amended 2026-10-30 (owner, PLA-476):** the cap's largest grant is 64 MiB, not 128, for every
process and title (madeira-unix 0233); the room rule is unchanged
([below](#amendment-2026-10-30-the-largest-grant-is-64-mib)).

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
- On the phone (IPA `2f784757…`) the tail peaked at 353–385 MiB, not 416–433, and three of three
  Opens showed the Sign In form with its text; Hollow Knight still got its 128 MiB buffer. The
  head grew into the room (512–533 MiB), so the pool still ends nearly full: the head (images) is
  not changed by this record and is the next lever.

## Amendment 2026-10-30: the largest grant is 64 MiB

**Approved by the owner, 2026-10-30 (PLA-476).**

- **The change.** The tail cap's largest grant (`TAIL_MAX`) is 64 MiB, not 128, for every process
  and title (madeira-unix 0233, `pp_jit_tail_cap.h`). A process that fills its first 16 MiB buffer
  and asks for 128 MiB gets 64 MiB at most; FEX halves its ask on the refusal, as it already did when
  the room was short. The room rule (48 MiB, plus 16 MiB for each other process with a live carve) is
  unchanged. A lone game now keeps a 64 MiB buffer, not 128.
- **Why 128 was chosen (ml1052, Madeira's comment).** The cap had been 32 MB (16 MB once the tail
  passed 160 MB). FEX keeps one code buffer per process and discards every translation when it fills;
  one run measured 12.5 M block lookups, 5.5 M real compiles (a 56 % hit rate), 390 rotations and a
  quarter of the running CPU samples in the compiler. 128 MiB is FEX's branch range.
- **Why 64 now** ([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md)). Red Dead Redemption 2
  asks for 128 MiB at its second generation in every run; what it got depended on the tail's room
  at that moment:
  - d1 and l11 got 64 (`tail CAP … cap 0x4000000`, 8 other processes), filled it and rolled to a
    third generation at press+2.1 and press+2.0 s (`[gen] alloc#3 … prev_size=0x4000000`). A roll
    discards the code cache and the per-thread lookup caches in FEX's band: RDR2's `[proc-mem]` fex
    row fell 524 → 239 MB (d1) and 561 → 237 MB (l11), and was 303 and 298 at Story's load step.
  - l9 and l10 got 128 and did not roll: l10's fex row was 467 at the step, 169 MB more than l11's,
    against a margin l10 lacked by ≥210 MB and l11 by ≥10–30 MB.

  A 64 MiB cap makes the roll the rule rather than tail-room luck.
- **Costs.** A process that outgrows 64 MiB rolls more often and retranslates after each roll. The
  launcher's Social Club helper already rolled four to six 128 MiB generations during the sign-in
  (l10, l11); RDR2's later generations stay 64 MiB (d1's third got 128). Hollow Knight gets 64.
- **Proof required.** A Hollow Knight `pp perf` pair on one phone session, before (the installed IPA)
  and after, on the October 8 route (`--pad first-frame+25:hk-new-game --pad first-frame+80:hk-walk`,
  compared over 85–120 s): frame rate, hitches, FEX compiles and `[gen]` rolls; and RDR2's load in the
  next layout run against l11 (`[gen]` rolls, the fex row, compiles). No RDR2 Story-world `pp perf`
  pair is required; gameplay speed in the Story world with 64 MiB generations stays unmeasured until
  one is run. If a gate fails, the fallback is a 64 MiB cap only when the footprint is within 2.5 GB of
  the limit at the ask.

