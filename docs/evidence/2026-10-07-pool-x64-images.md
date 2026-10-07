# Evidence: no JIT-pool copy for a pure x86-64 image (madeira-unix 0090)

**Date:** 2026-10-07. **IPA:** `Playport-26.5-18ab92ce.ipa` (dev), sha256
`18ab92cedcc09ea8fc8270913f18b9ad2034ab74ee4dd7057e2027486dd99afc`, built from the change
committed with this record (madeira-unix 0090 on top of 0088 and 0089). Phone: iPhone18,4,
iOS 27.0, Wi-Fi. Run directories are under `$PLAYPORT_BUILD/ui-runs/`; screenshots stay
there.

## The change

`map_image_into_view` marks an AMD64 image without CHPE metadata (no `VPROT_ARM64EC`, not
WoW64) `VPROT_X64_IMAGE`, skips its eager copy into the JIT pool and logs `[jit-pool] x64
image … no pool copy`; `mprotect_range` clears `PROT_EXEC` from such a view's host
protection, as for WoW64 images, so no later protection change copies it either. FEX
translates x86-64 code at its PE addresses and moves a guest RIP found in a pool copy back
to the PE address (`[pool-rip-fix]`), so nothing ran the copy; it only took the pool's head.

Madeira's own notes (ml457, reverted by ml458) say not to re-attempt this: Steam's
`steam.exe` died calling through a zeroed `.fptable`. Both of its trials predate ml957, which
first gave an RWX section a writable backing, so a run-time table written then reached only
the copy; this change leaves the backing as ml957 does. The phone was to decide: a title
regressing because of 0090 would revert it.

## Plays (one `pp phone lock` session, `pp ui --play … --shot`)

| Title (ID) | Run | Until | Outcome | Pool head before → after (MiB) |
| --- | --- | --- | --- | --- |
| Jurassic World Evolution (`epic-373a4372c20540aca7fdd880d27fa49a`) | `20261007T135415` | first-frame+60 | ends at +3.4 s, `0xc0000135`: `gdiplus.dll` not found (below) | 480 (`20261007T134855`, exhausted) → 68 |
| Hollow Knight (`app-367520`) | `20261007T135451` | first-frame+10 | first frame +9.77 s, menu | 138 (`20261007T134803`) → 83 |
| Snakebird Complete (`epic-8337d1f975514d35ad0c1176e8a29f26`) | `20261007T135542` | first-frame+30 | first frame +4.64 s, menu | 188 (`20261007T133928`) → 97 |
| Death's Door (`epic-65d73e3be8824829b5b788bd849b6559`) | `20261007T135650` | first-frame+25 | first frame +4.33 s, menu | 123 (`20261007T121935`) → 82 |
| Portal 2 (`app-620`, i386) | `20261007T135751` | first-frame+20 | first frame +5.89 s, menu | 19 (`portal2-window`, 2026-10-03, no first frame) → 26 |
| The Witcher 3 (`app-292030`), its disk cache on | `20261007T135845` | first-frame+30 | ends at +4 s, `0xc0000005` in FEX (below) | 158 (`20261006T112005`) → — |
| The Witcher 3, disk cache off (`--settings`) | `20261007T140438` | first-frame+30 | first frame +17.93 s, the intro | 158 → 88 |
| Among Us (`app-945360`) | `20261007T135921` | first-frame+30 | first frame +15.05 s, then `0xc000001d` at 17 s (PLA-39, as before) | 245 (`20261007T131411`) → 120 |

Portal 2's earlier runs are not like for like (none reached a first frame); its x86-64 image
is only the session root, so 0090 changes nothing there.

In Hollow Knight's log, before and after: `[pool-rip-fix]` 2 and 2, `[exc-pool-rip]`,
`[iOS-bogusrip]`, `[rip-leak]`, `[iOS-xquery] MISS` and `[x86-ptr] KEPT` 0 and 0, `ml958` 24
and 24; five `x64 image` lines (the session root, `hollow_knight.exe`, `UnityPlayer.dll`,
`mono-2.0-bdwgc.dll`, `steam_api64.dll`). Among Us's log lists ten, its `crashpad_handler.exe`
child's executable and `EOSSDK-Win64-Shipping.dll` among them.

Jurassic World Evolution's `JWE.exe` (its packer's RWX `.ecode`) now maps at its base with no
copy, and the process gets through its imports to `gdiplus.dll`, which the runtime does not
ship (its arm64ec build exists, it is not staged): `err:module:import_dll Library gdiplus.dll
(which is needed by L"C:\\Games\\JurassicWorldEvolution\\JWE.exe") not found`, then
`Importing dlls … failed, status c0000135`. That is the next limit, not 0090's.

The Witcher 3 with its disk cache on ends 239 ms into the title in FEX's own code
(`[fault-pc] … host_pool_reserve+…`, a read of `0xc52ee078`, `Unhandled exception code
c0000005`), at the same address on this IPA, on `2432d27c` (0089, no 0090,
`20261007T140145`) and on `afe0403c` (0088 only, `20261007T140303`, where the crash comes
before crypt32 is loaded). With the disk cache off on this IPA it plays. So it is not 0090,
0089 or 0088; its cause (most likely the cached code) is open.

No title regressed because of 0090, so it stays.
