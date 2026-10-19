# Smaller builtin copies in the JIT pool's head

[PLA-377](https://linear.app/playportdev/issue/PLA-377),
[decision 0122](../decisions/0122-builtin-copies-without-rsrc-and-reloc.md).

Every pseudo-process gets its own pool copy of each image it loads (decision 0019). In RDR2's
Steam play with the signed-in Rockstar launcher (run `20261019T120333`, IPA `8553f023…`), the head
ran out at 535 MiB live, before RDR2.exe could copy kernelbase and ucrtbase. RDR2.exe then died
with `0xc0000135`. Of those 535 MiB:
- 155.6 MiB were the builtins' trailing `.rsrc` and `.reloc`, which no code reaches;
- 154.7 MiB were the padding of Wine's 64 KiB section alignment.

The analysis scripts are in the build area (`.work/agent-notes/pla377/`).

## A1: no `.rsrc` or `.reloc` in a copy

### The change

- `patches/madeira-unix` 0165:
  - A copy ends after the last section code may reach (`ios_copy_extent.h`). It leaves out
    trailing sections that are neither executable nor writable, and that hold the resource
    directory or are discardable, as long as they hold no other data directory.
  - ntdll is copied whole.
  - The relocations are read from the PE view.
  - A mapping keeps the copy's size and SizeOfImage.
  - `[jit-pool] image` lines carry `copy=0x… of 0x…`, and the `pool:` line carries `trimmed_mb`.
- `patches/wine-pe` 0048: ntdll's resource functions turn a copy's base into the PE view's.
- `build/wow64/copy_extent_test.c` tests the extent on the section tables of shell32,
  kernelbase, kernel32, ntdll and FEX's xtajit64, plus the layouts that must stay whole.
- Over the IPA's 594 ARM64EC images, the extent matches `pe_sections.py` for every image with
  code. It differs only for 14 code-less images, which get no copy.

### Phone

IPA `f7e18e5173061fe7a5ab173b25aca3891b1fb563e41e408bb8b23a7d8b0b9caf` (dev).

The session ran `.work/agent-notes/pla377/a1/phone-session.sh`, with `phone-1.log` beside it.

**Hollow Knight** (run `20261019T131014`):
- first frame at +9.94 s (the last run took 12.05 s);
- pool head 62 MiB, against 84 in run `20261019T120213`;
- `trimmed_mb=24`;
- no `resource lookup through the copy` line.

**Red Dead Redemption 2** (run `20261019T131132`, the same route as `20261019T120333`, nothing
pressed):

| | before (`20261019T120333`) | A1 (`20261019T131132`) |
| --- | ---: | ---: |
| head at the end, MiB | 560 | 464 |
| tail at the end, MiB | 337 | 433 |
| trimmed, MiB | – | 199 |
| head refusals | 33 | 33 |
| RDR2.exe | died `0xc0000135` (kernelbase, ucrtbase not copied) | loaded 64 images (61 MiB), started `crashpad_handler.exe`, died at +~107 s |
| band peak, MB / threads | 5,670 / 216 | 5,612 / 228 |

Timeline of the A1 run:
- **About +55–75 s:** `Launcher.exe` starts RDR2.exe. The `pool:` line logged between these
  points shows head 377 MiB, tail 433 MiB and 87 MiB of room.
- **RDR2.exe loads past `0xc0000135`.** Its system DLLs are copied, and it starts its
  `crashpad_handler.exe`.
- **About +96 s:** room reaches 0. The head refuses RDR2.exe's `rsaenh.dll` (a 608 KiB copy)
  33 times, and `CRYPT_LoadProvider` fails.
- **RDR2's FEX asks for smaller and smaller code buffers.** The tail refuses 16, 8, 2 and 1 MiB.
  The last refusal is `tail_fatal`. FEX faults at `0xdead`, and RDR2.exe and its crashpad
  handler end.

At the first refusal, the live head was 456.6 MiB in 538 allocations. In the earlier run it was
535 MiB in 452. Shell32's eight copies took 9.2 MiB, where seven copies had taken 67.9.

**The tail took the freed room.** At about +43 s, the launcher's first Social Club renderer
(`SocialClubHelper.exe`, pid `0284`) took a 128 MiB FEX code buffer, as decision 0116's tail rule
lets a process do while the room allows. In the earlier run only the CEF browser got one; the
renderer's ask came when the room was smaller. The head ended 96 MiB lower and the tail 96 MiB
higher.

**The launcher's page.** After RDR2.exe ended, the screenshot at 240 s shows the Rockstar
launcher's own page: *A game is currently running … EXIT*. It is `Launcher.exe`'s window
`0x30074`, re-shown after the exit. Playport sent the launcher no close. The run ended as
`pool=exhausted:head` at +348 s.
