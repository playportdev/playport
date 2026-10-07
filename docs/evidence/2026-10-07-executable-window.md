# Evidence: the executable window (PLA-41)

**Date:** 2026-10-07. **IPA:** `Playport-26.5-2432d27c.ipa` (dev), sha256
`2432d27cf8e3f0447b955ce4f7b334829141d107063fcffb9e5ac0e5a054ae63`, built from the change
committed with this record: `wine_host.c` holds `[0x140000000, 0x15c000000)` from exec (a
1440 MiB reservation, `selfcheck_exe_window_split`) and names it in `WINE_IOS_EXE_WINDOW`;
madeira-unix 0089 gives it only to an executable that cannot move, commits the claim with
the rounded size and logs `[exe-base]`. Phone: iPhone18,4, iOS 27.0, Wi-Fi. Run
directories are under `$PLAYPORT_BUILD/ui-runs/`.

## Before

`20261007T121242` (step 1 of the store sign-in plan): Jurassic World Evolution's `JWE.exe`
(ImageBase `0x140000000`, SizeOfImage `0x1a5c5000`, characteristics `0x23`: relocations
stripped, image_flags 0) was refused its base with `0xc0000018`, placed by the scan at
`0x7038010000`, and the loader ended it: `wine: failed to create main module …, status
c0000018`, 328 ms after start. Two things held the base: the session root
(`playport-session.exe`, linked at `0x140000000`, mapped there for the whole session) and
libmalloc's start-up regions just above the old 960 MiB reservation.

## Hollow Knight (`app-367520`): the mechanism and the regression

`pp ui --play app-367520 --until first-frame+10 --shot` (`20261007T134803`): JIT 2.43 s, game
+3.44 s, first frame +9.58 s, the menu; pool head 138 MiB. `pull/s1-host.log`:

    [wine_host] JIT pool: reserve 0x10a5a0000-0x1645a0000; freed 0x10a5a0000+576 MiB for the pool (kr=0)
    [wine_host] executable window: 0x140000000-0x15c000000 held for an executable that cannot move
    [wine_host] vm: map  0x140000000-0x15c000000    448 MiB tag 0
    ml977: executable window [0x140000000,0x15c000000) is reserved; …
    ml985: preferred base 0x140000000+0x10000 REFUSED status=0xc0000018 image_flags=0x4 charact=0x22 …
    [main-exe] NOT_AT_BASE (relocated) — continuing normally
    [init-peb] … module=0x12ad10000

The session root is now refused the window (it is DYNAMIC_BASE) and runs relocated; the
session answers as before. No `RELEASED` line: Hollow Knight's executable is relocatable.
This launch's slide (`0x10a5a0000`) is above the highest seen before (`0x10a3f8000`); the
reservation ends at `0x1645a0000`, still under the lowest main-thread stack seen
(`0x16d0c4000`).

## Jurassic World Evolution (`epic-373a4372c20540aca7fdd880d27fa49a`)

`pp ui --play epic-373a4372c20540aca7fdd880d27fa49a --until first-frame+60 --shot`
(`20261007T134855`): JIT 2.74 s, game +3.47 s, then the end 488 ms later with
`0xc0000135`. The window works:

    ml985: map_image_view size=0x1a5c5000 base=0x140000000 … charact=0x23 …
    ml977: RELEASED the executable window to 0x140000000+0x1a5c8000 (fixed-base main image)
    ml988: fixed base 0x140000000+0x1a5c8000 is OWNED by gen 1 (map succeeded; …)
    [main-exe] virtual_map_main_module = 0x0 Machine=0x8664 chars=0x23

No `failed to create main module`. At the exit the image is retired and held for the next
launch (`OWNED -> RETIRING`, `HELD_NOT_READY -> HELD_READY`): the rounded commit matched.

It then hit the next limit, the JIT pool's head, as expected:

    iOS JIT: copied image 0x140000000+0x1a5c5000 → pool 0x106ea5000 (offset 0x1345000, used 0x1b911000/0x20000000)
    [jit-pool] image map FAILED (pool exhausted): .text of view 0x73fb2e0000 -> STATUS_NO_MEMORY   (three DLLs)
    err:module:loader_init Importing dlls for L"C:\\Games\\JurassicWorldEvolution\\JWE.exe" failed, status c0000135
    title: done … pool=exhausted:head exit=0xc0000135

Pool head 480 MiB of 512 (`head_exhausted=12`). The copy of the whole 422 MiB image is the
next step's subject (madeira-unix 0090).

## Host checks

`pp test --quick` passes, with `app/tests/selfcheck_test.c`'s window cases: a 512 or
768 MiB pool keeps the window at the lowest and highest slides seen; 896 MiB keeps it at
the lowest only.
