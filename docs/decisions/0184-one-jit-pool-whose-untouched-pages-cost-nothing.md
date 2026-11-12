# 0184: One JIT pool whose untouched pages cost nothing

**Status:** accepted, 2026-11-12, as [0183](0183-no-per-game-memory-keys.md) and its spec
[PLA-835](https://linear.app/playportdev/issue/PLA-835) decided it (the owner's grilling session):
one pool for every game, whose untouched pages cost nothing, or one that grows on demand if iOS
makes that impossible. Built in [PLA-846](https://linear.app/playportdev/issue/PLA-846)
(madeira-unix 0296); no phone has run it yet. Amends
[0036](0036-one-512-mib-jit-pool.md), [0108](0108-a-launchers-jit-pool-and-service-start-timeout.md)
and [0153](0153-rdr2s-settings-are-every-games-defaults.md); supersedes the per-title pool sizes
proposed for RDR2 ([PLA-549](https://linear.app/playportdev/issue/PLA-549)) and SANABI
([PLA-810](https://linear.app/playportdev/issue/PLA-810)).

## Context

- **The whole pool is dirty from activation.** The debugger blesses the pool by writing one byte,
  `0x69`, to every 16 KiB page of it (StikJIT's `prepare_memory_region`, one gdb-remote `M` packet
  per page). A written page is resident and dirty, so the whole pool counts against the memory
  limit from then on (0019 measured the footprint at the runtime's start as the pool plus about
  35 MB, for every size it tried).
  - Hollow Knight on an IPA with every game's 896 MiB pool (run `pla835-hk-e9b0b`): the footprint
    went from 58 MB before activation to 962 MiB just after. The play used 73 MiB of head and
    129 MiB of tail, leaving 695 MiB that it paid for and never touched.
  - RDR2's 896 MiB pool was all dirty from activation, with about 475 MiB live once the launcher
    had ended (PLA-549).
- **Per-title sizes were the old answer.** 0036 gave every Play 512 MiB because the pool was memory
  the game could not have; 0108 let a compatibility entry or a launcher ask for more; 0153 made
  RDR2's 896 every game's. PLA-549 and PLA-810 would have measured a size per title. 0183 forbids
  per-title memory keys.
- **What iOS leaves out of the footprint.** A dirty anonymous page is left out only when the kernel
  may discard it (`MADV_FREE_REUSABLE`, a volatile purgeable object), or when another task owns it
  (a private entitlement). A page the kernel discarded comes back zero-filled at its next fault.
- **Which mapping faults it back decides whether it executes.** The pool has two mappings, the
  blessed RX region and the app's RW alias (`mach_vm_remap` of it).
  - XNU marks an entry the debugger wrote through `VM_PROT_COPY` as `vme_xnu_user_debug` once the
    code-signing monitor has associated its range as a debug region. A fault through such an entry
    maps the page with the debugger's page type (`fi_xnu_user_debug`, `PMAP_OPTIONS_XNU_USER_DEBUG`),
    which may be both writable and executable for a debugged process.
  - On iOS a remapped entry does not keep the flag (`vm_map_entry_copy` clears it), so the RW
    alias's faults give an ordinary page.
  - Madeira swept freed pool ranges with `MADV_FREE`, then `MADV_FREE_REUSABLE`, and handed them
    out again through the RW alias first. Those ranges lost execute (its ml87 and ml88). With no
    sweep, 66 reuses ran with no exec fault (ml90, Madeira `fea6798`).
- **Growing on demand would need the debugger back in the middle of a Play.** The pool is blessed
  only while a debugger is attached. An attached debugger stops the whole process on every
  exception, and Wine and FEX take faults all the time. StikDebug and another app's JIT cannot be
  called back from inside a Play at all.

## Decision

- **One pool for every Play:** 896 MiB (PlayportKit `JitPool.sizeMB`), the most the executable's
  exec-time reservation holds, whatever the game and the memory limit.
  - No compatibility entry, launcher, `everyGame` default or person's settings sets a pool size.
    `LaunchSettings` has no `jitPoolMB`, so the compatibility table refuses one. The configuration
    check (`TitleConfig.refusedKeys`) refuses the key as a runtime key too.
  - A dev build's *Simulated JIT memory* still sets any size, the run that shows *ran out of JIT
    memory*.
- **Untouched pages cost nothing; the pool does not grow on demand.** madeira-unix 0296
  (`pp_jit_room.h`, `ios_pool_room_*`):
  - At the pool's start, the **room** (every page but the first, which holds the trampolines) is
    made reusable through the RW alias. It leaves the footprint, and iOS may take a page back.
  - A page is claimed once, just before it is first handed out: by the head's bump (before the
    head passes it), a fresh tail carve (before its NOP prefill) or a stub region below the tail.
  - The claim cancels reusable, reads the page through the RX mapping (so a page iOS took back
    faults in through the blessed entry), then writes it back through the RW alias. The write makes
    the page dirty, so pageout compresses it rather than discards it again.
  - The pool warmer reads the RX mapping before the RW alias, since the tail publishes a carve
    before it claims it.
  - If the madvise fails, the pool stays as before: dirty from the bless.
- **Logs.** `[jit-pool] room:` lines report:
  - the footprint before and after the madvise;
  - each claim that met pages iOS had taken back (a taken-back page reads 0 where the bless left
    `0x69`);
  - every minute, the room left out of the footprint and how many claimed pages had been taken
    back.
- **Unchanged.**
  - The head and tail rules, and the outcome when they run out (0019, 0022).
  - The restart when prerequisites leave the game less than `JitPool.gameRoomMB` (0094).
  - The exec-time reservation.

## Costs and risks

- **Not shown on the phone yet.** That a page iOS took back executes once it is faulted in through
  the RX mapping rests on XNU's source and on how Madeira's sweep failed, not on a run.
  - If it does not, a game faults in pool code on such a page. The `[jit-pool] room:` lines say
    whether any page was taken back, and where.
  - The way back is to drop 0296: the pool is then dirty from activation, as before.
- **Every Play gets 896 MiB.** On a phone whose limit is under 6 GiB, that is 384 MiB more than it
  got before. Only the pages a game uses count against its limit, and the rest is address space
  in the exec-time reservation.
  - At the highest slides, an 896 MiB pool leaves the reservation without the executable window,
    as it already did on every phone with a 6 GiB limit or more.
- **A claim touches each page once**, a read and a write, and a page iOS took back costs one
  fault. Claims happen when the head or the tail grows, not on the hot path.
