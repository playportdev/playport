# Evidence: a WoW64 window in a fixed slot, so its disk-cache bucket stays warm

**Date:** 2026-10-14. **Kind:** a host unit test and phone runs (dev app).
**Linear:** [PLA-349](https://linear.app/playportdev/issue/PLA-349).
**Branch:** `dev/pla-349-wow64-window-slots`.
**IPA (dev):** `e20a8c4982bb39332492415b1fef74bdd4b3d5ce7df60ba5cf923f192d220000`.
iPhone18,4, iOS 27.0.1. Run directories are under `$PLAYPORT_BUILD/ui-runs/`.

## The problem

fex 0043/0044 key a 32-bit process's disk-cache bucket on its guest window's host
base, because every guest memory access carries that base as a constant. The window
was a bottom-up first fit in the guest band, packed right after Wine's furniture. If
furniture landed there before a launcher's child, the child's window moved, and the
child then started cold. Assassin's Creed's game process did this: `0x7138950000`, then
`0x7139b70000` ([2026-10-14-assassins-creed.md](2026-10-14-assassins-creed.md)).

`[wow64-window] reserved` lines across the 1227 earlier ui-runs give the same picture:

- first process: mostly `0x7038950000` (298 runs);
- second process: `0x7138950000` 69 times, then 14 other bases between
  `0x7139150000` and `0x713fae0000`.

In the Assassin's Creed run `20261014T100138`, Wine's top-down DLL images sat in the top
~50 MB under the furniture ceiling (`0x73fce40000` up to `0x73ffff0000`).

## Change

`patches/madeira-unix/0146` adds `wow64_slots.h`. A window first tries fixed slots
4 GB apart. The slots count down from the furniture ceiling (`0x73ffff0000`), below a
1 GB margin left for those images, and stop at the usable floor. Today that gives three
slots: `0x72bfff0000`, `0x71bfff0000` and `0x70bfff0000`. A slot is taken only when:

- no Wine view is in it;
- it is outside CoreAnimation's range;
- the no-clobber map (`anon_mmap_tryfixed`) succeeds.

With no slot free, the window is placed as before.

The other option was to make the base a relocation that the cache patches on load. That
was not taken: every `Constant(GuestWindowBase)` fold in FEX's OpcodeDispatcher would
have to stay unfolded and be relocated.

**Host test:** `build/wow64/slots_test.c` (run by `build/wow64/test.py`, part of
`pp test`) compiles the header from the patch. It checks:

- the slot bases, the margin and the floor;
- that an occupied slot is skipped;
- that a launcher and its child get slots 0 and 1 whatever furniture is mapped below.

## Phone runs (IPA `e20a8c49…`, disk cache on)

| Run | Title | Windows | Disk cache | First frame |
| --- | --- | --- | --- | --- |
| `20261014T110245` | Assassin's Creed | launcher `0x72bfff0000`, game `0x71bfff0000` (fixed slots) | cold: new bases, so new buckets (hits=1, misses up to 14336+) | +6.06 s |
| `20261014T110339` | Assassin's Creed, again | the same two slots | warm: hits=24572, misses=2 | +4.96 s |
| `20261014T110432` | Hollow Knight, `--until first-frame+10 --shot` | none (64-bit) | warm | +8.85 s, title menu |

The second Assassin's Creed launch's screenshot shows the game's intro scene. Before
the change, both launches of the game were cold (+5.25 s and +5.18 s).
