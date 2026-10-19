# Playport's CEF DLLs linked with 16 KiB sections

[PLA-415](https://linear.app/playportdev/issue/PLA-415). Follows
[RDR2's loading memory](2026-10-19-rdr2-loading-memory.md#memory-by-process-pla-414).

## Why

On the phone every x86-64 libcef load reads the whole DLL into its process's own memory.
- Playport's libcef (decision 0110) has 4 KiB sections (FileAlignment 0x200).
- madeira-unix maps an image section from the file (`MAP_PRIVATE`, `map_file_into_view_ex`)
  only when it is aligned to the 16 KiB host page in memory and in the file. Otherwise it
  `pread`s the section into the view.
- So each CEF process holds its own dirty copy: 284–316 MiB committed per CEF process at RDR2's
  first frame.
- Mapped from the file, a process gets its own copy only of the pages it relocates or writes
  (about 22 MiB for libcef, by its relocation table). The clean pages are file-backed, shared
  by every process, and not in the app's footprint.

## The relink

- **Linker flags:** `/ALIGN:16384 /FILEALIGN:16384` for `libcef.dll` (patches/cef 0003),
  `libGLESv2.dll` (patches/chromium 0017) and `vk_swiftshader.dll` (patches/chromium 0018).
- **The `/WX` problem:** lld-link warns `/align specified without /driver; image may not
  run`, and Chromium links with `/WX`. Each flag set is a config that comes after `/WX` and
  adds `/WX:NO`, so the warning stays a warning.
- **The build:** the ThinLTO cache relinked the three DLLs in under 2 minutes (owner-provided
  xwin SDK, `run-ninja-lowva.sh pla415`). The other 230 recorded files are byte-identical.
- **What changed:**

| File | Before | After |
| --- | --- | --- |
| `libcef.dll` | `b22e4e18…`, 256,365,568 B, 0x1000/0x200 | `cc06fbd5…`, 256,540,672 B, 0x4000/0x4000, 14 sections |
| `libGLESv2.dll` | `91c201d3…`, 0x1000/0x200 | `144b0204…`, 8,568,832 B, 0x4000/0x4000 |
| `vk_swiftshader.dll` | `551e17c0…`, 0x1000/0x200 | `2c379268…`, 5,586,944 B, 0x4000/0x4000 |

- **The records:** `build/generated/cef-143.0.14.sha256` carries the new hashes.
  `build/cef/verify-payload.py` now also fails if any section of the three DLLs is not
  16 KiB-aligned in memory or in the file; `tools/tests/test_cef_build.py` covers that check.

## The phone's proof line

madeira-unix 0167 logs one line per x86-64 image mapping:
`[img-map] x64 <name> at <base>: file-mapped <bytes> read <bytes> of <size> (sections N, align
<section>/<file>)`.
- `file-mapped` counts the bytes of its sections mapped from the file.
- `read` counts the bytes read into the process's own memory.

## Desktop check (Proton 10, Xvfb)

The launcher was run with Playport's CEF files in the scratch prefix's Social Club folder and
decision 0109/0111's switches, for 150 s, with nothing pressed and no sign-in. The runner was
`$PLAYPORT_BUILD/agent-notes/pla254-rockstar/swaprun415.py`.

| | relinked (`pla415-relink16k`) | control: the previous 4 KiB build (`pla415-control4k`) |
| --- | --- | --- |
| `socialclub_launcher.log` lists `libcef.dll` | 143.0.14.0 | 143.0.14.0 |
| Social Club UI states | `WAIT_BROWSER_WINDOW` → `LOADING` → `WAITING_FOR_PAGE_LOAD` → `WAITING_FOR_PAGE_READY` → `PAGE_READY` → `START_SIGN_IN` → `FINISHED` | `WAIT_BROWSER_WINDOW` only |
| `Launcher.exe` | ends with `Exception: 0xc0000094` in DXGI, then "failed to initialize 00000010" | the same |

- **The gap.** The sway display (`sway-nocap`) was not running, so the run used an owned Xvfb.
  Under Xvfb, Launcher.exe's main window dies in DXGI with either build, so neither run shows
  the sign-in page.
- **What it does show.** With the relinked libcef, Social Club's CEF loaded its page through
  to `FINISHED`. The phone is the real check.

## Phone

IPA `cf0e10784daaf0bcb84d95ff8039f99dcf9e47cde008e1bd04c09c43c5441dd4` (dev; the relinked
payload and madeira-unix 0167), session script `$PLAYPORT_BUILD/agent-notes/pla414/session2.sh`.

- **Hollow Knight** (run `20261019T152552`): first frame at +8.63 s.
- **`[img-map]` lines:** 69 in that run.
  - The 16 KiB builtins are file-mapped with nothing read, for example `ntdll.dll` 0xe4000
    file-mapped and `ucrtbase.dll` 0xfc000.
  - The x86-64 images with 4 KiB sections are read whole, for example `xtajit64.dll` 0x42e400
    and the session root.
- **RDR2:** not yet played with this payload. The libcef result is in the next play.
