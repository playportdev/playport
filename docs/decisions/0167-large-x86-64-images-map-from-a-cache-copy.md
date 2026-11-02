# 0167: Large x86-64 images map from a re-laid-out cache copy, not read into memory

**Status:** accepted, 2026-10-30, approved by the owner (PLA-476) with the 64 MiB threshold. It extends
[0123](0123-builtins-linked-with-16-kib-sections.md) from Playport's own builtins to foreign x86-64
images, and it keeps [0150](0150-dev-single-process-social-club.md)'s "no installed executable or DLL is
changed on disk": only a separate copy in the app's caches is written.
[Plan](https://linear.app/playportdev/issue/PLA-476), [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md).

**As built 2026-10-30 (owner, PLA-476):** the key carries the file's ctime, and each use checks 16
sampled points ([below](#as-built-2026-10-30-the-ctime-in-the-key-and-a-sampled-check-madeira-unix-0238)).

## Context

- **When an image's section is copied (M, code).** madeira-unix's `map_file_into_view_ex` mmaps an image
  section from its file (`MAP_PRIVATE`) only when three things hold:
  - the section starts on a 16 KiB host page;
  - its mapped size is whole host pages;
  - its file offset is 16 KiB-aligned.

  Any other section is `mprotect`ed RW and `pread` into the anonymous view.
- **Rockstar's libcef is copied whole.** It has 4 KiB sections and 0x200 file alignment, and no section's file
  offset is congruent to its RVA modulo 16 KiB. So every process that loads it reads all of it
  (`[img-map] x64 libcef.dll … file-mapped 0x0 read 0xedc6c00`, 238 MiB).
- **What l11 read (M).** In l11 (`20261030T154831-rdr2-p476l11`) the x86-64 images read 2466 MiB in all:

  | Image | Size | Loads | Read |
  | --- | --- | --- | --- |
  | libcef.dll | 239 MiB | 6 | 1426 MiB |
  | RDR2.exe | 115 MiB | 5 | 427 MiB |
  | Social-Club-Setup.exe | 122 MiB | 2 | 244 MiB |
  | Launcher.exe | 32 MiB | 5 | 142 MiB |
  | everything else | < 8 MiB each | | |

  Not one byte of them was mapped from a file. Playport's own libcef (`patches/cef` 0003, 16 KiB sections, run d1)
  read 0 and mapped 245 MiB.
- **Why the copy costs memory (I, b-stock-cef-cost).** A page that was read is anonymous: it is in
  `phys_footprint`, it compresses, and it is not shared between the pseudo-processes of the one Mach process.
  A clean page mapped from a file is "external": it is not in the footprint, the kernel can drop it, and it is
  shared.
- **The estimated saving (I).** Stock CEF costs about **+210–230 MiB** in the game's helper B at RDR2's Story
  step, and about +200 MiB in the launcher's helper A while A lives. Of libcef, only about 20 MiB of relocated
  pages (1295 distinct 16 KiB pages) plus `.data` would stay private.
- **What confirms it (madeira-unix 0232).** The `res_file/res_anon` columns of `[proc-mem]` measure the split
  on the phone.

## Decision

- **Scope: x86-64 PE images of at least 64 MiB** (SizeOfImage).
  - At first this is libcef.dll, RDR2.exe and Social-Club-Setup.exe in an RDR2 play.
  - Not included: ARM64/ARM64EC/ARM64X images, WoW64 (i386) images, `IMAGE_FLAGS_ImageMappedFlat` images,
    images with a shared writable section (`IMAGE_SCN_MEM_SHARED|WRITE`), and images on removable media.
  - Every game is covered, not only RDR2. The threshold is a constant in the patch, and lowering it (for
    example to 32 MiB, which adds Launcher.exe) is a later record.
- **The copy.** The cache copy is the image laid out as it is in memory, before any write:
  - the headers at offset 0;
  - each section's file bytes at its RVA, with the same rounding Wine's loop uses (`PointerToRawData & ~0x1ff`,
    clipped to the section's mapped size);
  - zeros elsewhere, up to SizeOfImage rounded to 16 KiB.

  File offset therefore equals RVA, so the whole image maps with one `mmap(MAP_PRIVATE|MAP_FIXED)` at the view's
  16 KiB-aligned base. Its content equals what today's `pread` path puts in the view before relocation (a host
  test checks the layout function against the loop's rules).
- **Where it lives.** In the app container: `Library/Caches/images/`, given to the runtime as
  `PLAYPORT_IMAGE_CACHE_DIR` by `wine_host.c`, as the Mesa and DXMT caches are.
  - It is never in the game folder, the prefix or the Social Club folder.
  - The installed file is only read, so 0150's on-disk rule holds.
  - iOS may purge Library/Caches; a purged copy is written again.
- **Key and invalidation: file identity, not a hash.**
  - The file name is `v1-<dev>-<ino>-<size>-<mtime s.ns>-<view size>.img` (hexadecimal).
  - On use, the copy's size must be the view's rounded up to 16 KiB, and its first SizeOfHeaders bytes must
    match the header `map_pe_header` just put in the view.
  - Any mismatch, or a copy of the wrong length, means the copy is not used. That map takes the `pread` path,
    and the copy is deleted and written again.
  - **Cost:** one `fstat`, one `open`, one header compare per map. A SHA-256 of 239 MiB on every map (about
    0.3–1 s of CPU, ×6 maps a play) is rejected.
  - **What identity misses:** an in-place rewrite that keeps size, mtime and inode. A store update writes a new
    file (new inode or mtime).
- **Writing the copy (first load).**
  - The first map of an image with no valid copy takes today's `pread` path unchanged.
  - It then hands the key and a `dup`ed fd to one background writer thread. Nothing is written under
    `virtual_mutex`.
  - The writer:
    1. lays the copy out from the file into `<key>.tmp` with a 1 MiB buffer;
    2. reads each 1 MiB block back and compares it;
    3. runs `fsync`, then `rename`s the file into place.
  - One write per key at a time (an in-flight set). A failed write leaves no file.
  - **Cost (I):** about 239 MiB read and written, plus a verify read, for libcef. About 0.5–1.5 s of I/O
    off the loading thread, once per image version.
  - In RDR2 the launcher helper A loads libcef first (≈+27 s), so the game's helper B (≈+107 s) maps the copy in
    the same play. Later plays map it for every process.
  - `[img-cache]` lines log the write (`wrote <name> <MiB> in <ms>`, or the reason it did not) and each use
    (`mapped <name> from the cache copy`).
- **Disk budget and eviction.**
  - At most **1 GiB** of copies.
  - No copy is written unless the phone keeps at least **2 GiB** free after it (`statfs` before the write).
  - Before a write, the least recently used copies (mtime touched at each use) are deleted until the new one fits.
  - Deleting a copy that is mapped is safe: the inode lives until the views go.
  - Settings › Storage counts the copies with the *Emulator cache* row and clears them with it (decision 0012:
    through the UI).
  - The l11 set is libcef 239 + RDR2.exe 115 + Social-Club-Setup.exe 122 = **476 MiB**. The phone had
    3.1–4.0 GB free in these runs.
- **What stays private.** Wine's loader and FEX still write into the mapping, and every page written becomes an
  anonymous copy:
  - relocated pages (libcef: 1295 pages, about 20 MiB);
  - the import table;
  - `.data`/`.tls` and the header page (the ImageBase update);
  - any page an unpacker writes (RDR2.exe's protected code may be written at run time, so its saving is
    unmeasured).

  Protections are unchanged (Wine's per-page vprot; MAP_PRIVATE allows the RW upgrades). x86-64 code is never
  executed natively (FEX translates it at its PE addresses, `VPROT_X64_IMAGE`), so no executable file mapping is
  needed.
- **Failure fallback: `pread` as today.** Any of the following maps the image as today, with an `[img-cache]`
  line:
  - no `PLAYPORT_IMAGE_CACHE_DIR`;
  - an image outside the scope;
  - an open, `fstat`, header-compare or `mmap` failure;
  - a missing copy.
- **Sharing.** All pseudo-processes live in one Mach process. Each one's `MAP_PRIVATE` view of the same copy
  shares the copy's clean page-cache pages with the others (A and B's libcef, RDR2.exe's early-image replays).
- **Kept views (0166, madeira-unix 0226/0229/0231).**
  - A view a parked thread keeps (0127/0132/0166) holds its mapping as today. Its clean pages are external, so a
    kept libcef view costs its private pages, not 240 MiB.
  - A slot held in place (0231) maps its `PROT_NONE` hold over the view with `VM_FLAGS_OVERWRITE` whatever backs
    it.
  - The Social Club layout's routing (0226) places the view as today; only its backing changes.
- **Both builds.** The saving is the release app's too (single-process stock CEF, 0153). There is no switch:
  l11 is the before-measurement, and the `pread` path stays as the fallback.

## As built (madeira-unix 0235, `Class: feature`)

- `pp_img_cache.h` (pure, host-tested in `tools/tests/test_img_cache.py`): `ppic_eligible`, `ppic_name`,
  `ppic_layout` (map_pe_header's bytes and zeroes, then each section's sector-rounded file bytes and the
  zeroes after them, in the order Wine applies them), `ppic_overlap` and `ppic_evict`. The test replays
  Wine's steps on a synthetic libcef-shaped file and compares the writer's copy byte for byte; the same check
  passed on Rockstar's real libcef (15 sections, 0x1000/0x200).
- `virtual_ios.c` `map_image_into_view`: after `map_pe_header`, `ios_img_cache_map` maps the whole view
  from a valid copy with one `map_file_into_view` (MAP_PRIVATE) and the section loop is skipped; otherwise
  the loop runs as before and the copy's write is queued. Everything after the loop (ARM64EC ranges,
  `VPROT_X64_IMAGE`, `[img-map]`, relocation, protections) is unchanged; `[img-map]` then reads
  `file-mapped <whole view> read 0`.
- One detached writer thread (all signals blocked, no Wine lock) writes `<name>.tmp` in 1 MiB blocks with
  `F_NOCACHE`, reads each block back and compares it, `fsync`s and renames it. A `.tmp` left by an
  interrupted write is deleted before the next.
- `wine_host.c` makes `Library/Caches/images` and sets `PLAYPORT_IMAGE_CACHE_DIR`; `EmulatorCache` counts
  and clears the copies with FEX's cache in Settings › Storage's *Emulator cache* row, and its launch-time
  budget check leaves them alone (the runtime keeps them within 1 GiB).
- Lines: `[img-cache] … no copy yet, read as before; writing <name> (N MiB) in the background`,
  `[img-cache] wrote <name> for <image>: N MiB in N ms`, `[img-cache] mapped <image> at <base> from its copy
  <name>`, and the reasons a copy was not written, did not match, or was deleted for room.
- Proof owed: Hollow Knight first-frame+10; in the next RDR2 layout run, the write and its time, the game's
  helper's libcef mapped from the copy, and its `[proc-mem]` image `res_file/res_anon` (madeira-unix 0232)
  against l11.

### As built, 2026-10-30: the ctime in the key and a sampled check (madeira-unix 0238)

By the owner (PLA-476, hardening 2 of the V8-probe research), against the gap above: an in-place
rewrite that keeps size, mtime and inode.

- **The name** is `v2-<dev>-<ino>-<size>-<mtime s.ns>-<ctime s.ns>-<view size>.img`. No one can set a
  file's status change time, and any write changes it; a chmod or a new link only costs a miss. A name
  that does not fit the runtime's 128 bytes takes the `pread` path.
- **A sampled content check on each use**, after the header compare, with no stored hash.
  - `pp_img_cache.h`'s `ppic_samples` picks 16 points:
    - spread evenly over the bytes the file's runs put in the copy;
    - each 4 KiB, starting on a 4 KiB boundary of its run;
    - none under a later run (the header page past SizeOfHeaders is zeroed after the header is
      mapped).
  - At each point, `pread` the image file at the run's offset and the copy at the rva, and compare.
    This costs about 128 KiB of reads per map, under `virtual_mutex`.
  - A difference deletes the copy. The image is read as before and its copy is written again.
- **Older copies.** The writer deletes `.img` copies of another name version (the `v1-…` copies)
  before it writes.
- **Lines:** the use line ends `(N MiB; 16 sampled points equal the file)`. A difference logs
  `[img-cache] <image>: copy <name> differs from the file at rva 0x… (sampled check); deleted, read
  as before`, and an old copy logs `[img-cache] deleted <name> (an older version's copy)`.
- **What it still misses:** a rewrite between points whose ctime stays the same, which no userspace
  write can produce.
- **Host test:** `tools/tests/test_img_cache.py` covers:
  - the name and its length bound;
  - the points on libcef's layout (count, spread, inside a run, never under a later run);
  - a right copy passing, and a byte rewritten at any point failing.

## Consequences

- **Memory:** about −200 MiB in each live process that loads stock libcef, and less for RDR2.exe and the
  installer (unmeasured).
- **Disk:** about 0.5 GiB for RDR2's set, capped at 1 GiB, written once per image version.
- **A new loader path for every game's large x86-64 images.** A wrong copy would corrupt an image; the header
  compare, the write-then-verify and the identity key are the guards.
