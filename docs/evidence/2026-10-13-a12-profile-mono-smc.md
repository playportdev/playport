# The A12 profile: Mono's code-write storm fixed, Hollow Knight still black without AFP (PLA-320)

**Linear:** PLA-320 (from PLA-132). Patch: fex 0040. Dev IPA
`a697860c027a57becd458b2106572c354dd893c85f3a4d221368e351206f9d0d`.

An A12 has neither AFP nor LRCPC2. On our phone (iPhone18,4) the A12's FEX profile is forced with the
game setting `runtime: env.FEX_HOSTFEATURES=disableafp,disablelrcpc2` (sweep 15b,
`2026-10-13-host-cpu-features.md`). Hollow Knight (Unity 6, Mono) then reached its first frame but stayed
black, with about 8,500 `Unhandled JIT SIGBUS` lines.

## The storm (fixed)

The `Unhandled JIT SIGBUS` lines were not the vector stores going wrong. FEX turns its code-write
tracking off once it finds Mono's call backpatcher (as upstream does), and Playport found it only from an
access violation on Mono's patching `xchg` (`DetectMonoBackpatcherBlock`). Wine's Mach handler can also
complete that `xchg` itself (`[swp-emul]`) when the code page is writable to Wine. The native bridge
(`[mono-bridge] ml648 ACTIVATED`) then marks the block, but nothing turned the tracking off. Every method
Mono then wrote beside code FEX had compiled faulted and invalidated a host page of code. Each fault
retried a plain `STR q`/`STUR q` through `HandleUnalignedAccess`, which declined it (the log line), and
the Mach handler completed it.

Whether the page is still writable at that moment depends on the store before it. With LRCPC2, a guest
store at an offset is `STLUR`. The Mach handler does not decode `STLUR` (`[store-undecoded]`), so it
became an access violation that reprotected the page first, and the `xchg` then faulted as one too.
Without LRCPC2, or with TSO off, the store is `STLR` or `STR` on a computed address, which the handler
completes. That is why LRCPC2 chose the route.

fex 0040: the bridge's activation (`IosMonoTryActivate`) now calls the tracker
(`MonoBackpatcherMarkedByBridge`), which turns the tracking off as the access-violation path does
(`MADEIRA_KEEP_SMC=1` still keeps it).

| Hollow Knight, `FEX_HOSTFEATURES` | before (IPA 42d9ad91) | after (IPA a697860c) |
| --- | --- | --- |
| normal (`enablelrcpc2`) | 7 access violations, 2 SIGBUS lines | 7, 0 (`.work/ui-runs/20261013T070133`) |
| `disableafp,disablelrcpc2` | 9,357, 8,524 (`20261013T064441`) | 2, 1 (`20261013T065533`) |
| all four off | 8.5k SIGBUS lines (`20261013T064317`) | 2, 1 (`20261013T065644`) |

## Hollow Knight still black without AFP (not fixed)

The screenshots after the fix are still black at first frame + 30 s (`20261013T065533`, `20261013T065644`),
and at about +80 s (`20261013T070730`). The game is not stuck: it presents about 58 frames a second (a normal run: 56), its
`Player.log` matches a normal run line for line (title scene loaded), and its CPU use is that of a normal
run. It draws black.

Same IPA, Hollow Knight, first frame + 30 s:

| `FEX_HOSTFEATURES` | TSO | how Mono's backpatcher was found | screenshot |
| --- | --- | --- | --- |
| normal (AFP on, LRCPC2 on) | on | access violation | menu (`20261013T070133`) |
| `disableafp,disablelrcpc2` | on | bridge | black (`20261013T065533`) |
| `disableafp,disablelrcpc2` | off | bridge | black (`20261013T070504`) |
| `disableafp,disablelrcpc2`, half-barriers off | on | bridge | black (`20261013T070620`) |
| `disableafp` (LRCPC2 on) | off | bridge | black (`20261013T071114`) |

From 15b on the previous IPA: `disableafp` alone (the access-violation route) shows the menu, and
`disablelrcpc2` alone (the bridge route, AFP on) shows the menu. **Correction (2026-10-21):** the
`disableafp` runs of 15b (`20261013T063943`, `20261013T064052`) were black too, so the black needs AFP
off only, not the bridge route; the conclusion below does not hold
([2026-10-21-afp-off.md](2026-10-21-afp-off.md)). So the black needs AFP off **and**
the bridge route, not LRCPC2 itself: AFP off with LRCPC2 on is black too once TSO off sends it down the
bridge route. The cause between the two is not found. AFP changes FPCR handling at every
JIT entry and exit (NEP, AH, FIZ) and scalar SSE code; the two routes differ in how the first `xchg`
completes (Mach handler without an FPCR or context restore, against Wine's exception path that resumes
from a full context) and on which thread and when the block is marked.

Portal 2 (no Mono) with all four off shows its menu at first frame + 30 s (`20261013T065754`).

## Gates (normal profile, same IPA)

- Hollow Knight, `--until first-frame+10 --shot`: menu, first frame +9.7 s, `FEX_HOSTFEATURES=256`
  (`enablelrcpc2`) in the title process (`.work/ui-runs/20261013T070133`).
- Portal 2, `--until first-frame+10 --shot`: Source logo, first frame +5.75 s, `FEX_HOSTFEATURES=256`
  (`.work/ui-runs/20261013T071306`).
