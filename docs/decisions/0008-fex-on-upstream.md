# 0008: FEX from its own upstream, with Madeira's port as a series

**Status:** accepted, 2026-09-24. Applies [0007](0007-dxmt-on-upstream.md)'s
approach to FEX, the second of the three components, and supersedes, for FEX
and its rpmalloc, the consequence of [0001](0001-superproject-on-madeira.md)
that Madeira's gitlinks decide which commits are built.

## Decision

- `pins.lock`'s `fex` row is a [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX)
  release commit (FEX-2609.1, the head of the `FEX-2609_1` release branch),
  not Madeira's `FEX` gitlink.
- Madeira's FEX port (`willfaust/FEX` `ios-port-2607`, 64 commits at the time)
  is carried rebased onto that commit as `patches/fex-port`, one patch per
  Madeira commit with `Madeira-commit:` naming the original, plus one
  adaptation commit of Playport's. Playport's own FEX changes stay in
  `patches/fex`, applied after it.
- FEX-2609 needs a newer rpmalloc than Madeira's fork is based on, so rpmalloc
  moves with it: the `rpmalloc` row is the FEX pin's `External/rpmalloc`
  gitlink (FEX-Emu/rpmalloc), and Madeira's rpmalloc changes are
  `patches/rpmalloc-port`, applied inside the FEX tree's `External/rpmalloc`.
  The port series carries none of Madeira's `External/rpmalloc` gitlink moves.
- The `fex-port` and `rpmalloc-port` rows record the Madeira commits the two
  series were rebased from. The build refuses to run when Madeira's `FEX`
  gitlink or that FEX's `External/rpmalloc` gitlink differs, and
  `tools/upstream-sync` holds on such a move, so a Madeira FEX update is
  re-ported deliberately rather than silently ignored.

The base is the latest release, not `main`: FEX-Emu tags a release every
month, FEX-2609.1 was three days old (122 commits behind `main`), and a
monthly tag gives each later rebase a well-defined target. The one change
between FEX-2609 and its point release fixes the Linux syscall instruction,
which the Windows build does not use.

## Why

Playport follows the latest DXMT, FEX and Wine with Madeira's and its own
patches ([0007](0007-dxmt-on-upstream.md)); DXMT went first. FEX is the second. Wine stays on Madeira's base until it gets
its own go-ahead once the cost of the first two is known: its port also
consists of about 92k lines of whole-file replacements that git cannot merge.

## What it costs

Measured on the first rebase ([record](../evidence/2026-09-24-fex-latest-rebase.md)):

- 16 of Madeira's 64 commits needed a real three-way resolution, 3 more
  needed compile fixes against changed upstream APIs, and 14 carried
  rpmalloc gitlink moves that went to the rpmalloc series (two became
  empty). rpmalloc itself: 3 of 16 commits resolved.
- Upstream had rewritten the code Madeira's port hardens most. The shared JIT
  code buffer is now claimed with an atomic bump and has no
  `CodeBufferWriteMutex`, so Madeira's lock-ownership stamps around that
  mutex were dropped and only its delivery-mode refusals carried over. Guest
  exceptions are now raised through `NtRaiseException`; on iOS the port keeps
  the `KiUserExceptionDispatcher` return Madeira's exception fixes were built
  on. Several auto-merged hunks landed in the wrong place and were caught
  only by reading every resolution against both sides.
- Every later upstream FEX release and every Madeira FEX or rpmalloc change is
  a hand-driven re-port followed by the full device gate, never automatic.
  Upstream-sync never moves `fex`, `rpmalloc` or the port series.
- Madeira's native iOS FEXCore build (`build/fex-ios`), which Playport does
  not build or ship, was resolved in good faith but not compiled.
