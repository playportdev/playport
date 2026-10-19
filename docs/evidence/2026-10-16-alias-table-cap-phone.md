# 2026-10-16: The CEF helpers' secur32 fault was a full emulator alias table (PLA-373)

**Linear:** [PLA-373](https://linear.app/playportdev/issue/PLA-373), for
[PLA-370](https://linear.app/playportdev/issue/PLA-370) stage D. Plan:
[CEF low-VA build](../plans/finished.md#own-low-address-space-cef).
**Change:** `patches/fex` 0046 and `patches/madeira-unix` 0155, with the host test
`tools/tests/test_alias_table_caps.py`.
**Question:** In the phone Open of [CEF on the phone](2026-10-16-cef-low-va-phone.md),
why did Social Club's CEF network and storage services, and a second browser, read address 0
in Wine's `secur32.dll` and then overflow their stacks?

- **IPA:** dev, sha256 `a2a8996714e6cc21c2bb8266a8ec9663a633270a513ae705a5db36a3a4e6d271`,
  built from `7180b9b` (branch `dev/pla-291-rockstar-launcher`).
- **Phone:** iPhone18,4, iOS 27.0.1. At the start it was at 80 % on external power, with
  3.3 GB free. The owner was attended.
- [M] measured, [I] inferred.

## Result

- **The secur32 fault is fixed [M].** With both tables at 1024 entries, no emulator refused an
  alias (`alias_full=0`, and no `[jit-alias] … FULL` line). The network and storage services
  logged the same clean `load_auth_packages … 80090304` as the launcher, and went on.
- **The sign-in page was still not reached [M].** The browser's main thread overflowed its
  stack in a Chromium font recursion, described below. That is a different fault. Social Club
  lost the browser at 7.7 s, and the launcher then exited through its crash handler.
- **Hollow Knight still works [M].** Its first frame came at +10.17 s, and the screenshot shows
  the title menu.

## The cause, from source and the earlier run

Run `20261016T190852` (IPA `2eefce7e…`), read against our build trees:

1. **The faulting code is a delay-load thunk, not a secur32 function [M].** secur32's rva
   `0x239bc` and `0x2398c` are the x64 delay-load thunks (`lea rax, [__imp_…]; jmp
   __delayLoadHelper2` tail) for `rpcrt4!RpcStringBindingComposeW` and
   `rpcrt4!I_RpcExceptionFilter`. `secur32` imports `rpcrt4` as a delay import (its
   `Makefile.in`). `load_auth_packages` (`dlls/secur32/lsa.c`, called from
   `SECUR32_initializeProviders` in `secur32.c`) calls `get_lsass_handle()`, and that function
   makes the first `rpcrt4` call. These processes made no SSPI or `GetUserNameEx` call
   first: loading `secur32` is enough.
2. **The thunks run from their JIT-pool copies [M].** This is normal. In the launcher and the
   first browser, FEX's `[pool-rip-fix]` translated the same thunk addresses back to their PE
   addresses through the emulator's alias table, and the call failed cleanly with `80090304`.
3. **The alias table was full in the processes that crashed [M].** Wine pushes every live image
   copy of every process to every process's emulator (`ios_alias_push_all`, and the drain when
   an emulator starts). Wine's table held 512 entries, but FEX's `IosAliasEntries` held only
   256. The emulators of the network service, the storage service and the second browser
   started with 243, 287 and 338 images to drain, and the log has
   `[jit-alias] PLA-310 emulator of peb=… FULL … NOT registered` (capped at 8 lines). Their
   `secur32` was loaded late, so it was never registered. FEX could not translate the
   thunk's pool address and built a NoExec block, and the code it emitted read address 0.
4. **The stack overflow follows from the same fault [I].** `LSASS_CALL_END`'s `__except`
   filter, `rpc_filter`, calls `I_RpcExceptionFilter` through another unregistered thunk.
   That call faulted (`AV EXEC` at the thunk's pool address) inside the filter, and each nested
   dispatch ran the same filter again: about 1,330 times per thread, until `0xC00000FD`. There
   is no separate fault in the exception dispatch.
5. **`80090304` is benign here [M].** `start_samss` logs `Failed to open SamSs service`. The
   app ships `lsass.exe`, and `wine.inf` adds `SamSs`, but this prefix has no such service.
   Without it, `secur32` loads no LSA packages and still returns cleanly. The launcher has run
   that way in every Open.

## The change

- `patches/fex` 0046: `kMaxEntries` 256 → 1024.
- `patches/madeira-unix` 0155: `IOS_JIT_MAX_MAPPINGS` 512 → 1024. A refused alias is now logged
  for the first 64 refusals, and then once every 256, each line with the running count; before,
  only 8 lines were logged per session.
- **Headroom [I].** About 213 images were live when the browser started, and each CEF process
  loads about 50 (FEX `Load module` counts per process: 46–54). The full tree, with a browser,
  network and storage services, three renderers and utilities, comes to about 650–700 of 1024.
- **Kept in step.** Every emulator entry mirrors one live Wine entry, so the FEX table must be
  at least the size of Wine's. The host test reads both values from the series and fails
  otherwise.
- **Cost.** 32 KiB of `.bss` per emulator. The reverse walk scans live entries, so it does not
  grow with the cap.

## The phone runs (IPA `a2a89967…`)

| Run | What | Result |
| --- | --- | --- |
| `20261016T193537` | `pp install --no-build`, then `--play app-367520 --until first-frame+10 --shot` (one lock session) | JIT 2.41 s, runtime +3.40 s, first frame +10.17 s; title menu |
| `20261016T193634` | `--settings 'launcher-rockstar:{"runtime":"env.FEX_SMCCHECKS=none"}'` | Saved |
| `20261016T193658` | `--action open-launcher:rockstar --until "mark:first window+240" --wait 600`, screenshots at 60, 150 and 230 s and at stop | First window +30.47 s; until mark reached; app alive |
| `20261016T194154` | `--settings "launcher-rockstar:{}"` | Key cleared |

Runs 2–4 were one `pp phone lock` session.

**Social Club [M]** (ms from its SDK start):
- 205: `WAIT_BROWSER_WINDOW`;
- 803: browser subprocess connected;
- 3,391: `LOADING`;
- 3,407: `WAITING_FOR_PAGE_LOAD`;
- 7,717: "Main browser connection lost";
- 7,823: `FAILED`.

**Screenshots [M]:**
- 60 s: the launcher's window, black with the Rockstar logo outline.
- 150 s, 230 s and stop: the crash handler's dialog, "The Rockstar Games Launcher exited
  unexpectedly", code `00000010`.

**The tree [M]:**
- `services.exe`;
- `Launcher.exe` with its crash handler, `LauncherPatcher.exe`, a second `Launcher.exe` with its
  crash handler, and `RockstarService.exe` (twice);
- the Social Club browser `SocialClubHelper.exe`, which started the network service and the
  storage service.

No renderer started. The second browser of the earlier run did not appear.

**Memory [M]:**
- footprint peak 5,452 MB at +44.2 s;
- pool 896 MiB: head 461 MB (444 live), tail 273 MB, room 163 MB, 344 images, 11 children,
  `alias_full=0`, `exhausted=none`;
- band 16,384 MB: peak 13,438 MB, 159 threads, `refused=0`.

No renderer reservations to report.

## The next blocker: a font recursion in the browser's main thread [M]

- The browser's main thread ended with `0xC00000FD`, as in the earlier run.
- Over the 2 s before that, its guest stack pointer fell by about 4 MiB, and Wine allocated a
  new DC attribute bucket every 0.3 s.
- The unwinder walked tens of thousands of frames in our `libcef.dll`. Symbolised with our
  build's PDB, they repeat one cycle:
  - `gfx::PlatformFontSkia::EnsuresDefaultFontIsInitialized`
    (`ui/gfx/platform_font_skia.cc:166`) calls `win::GetDefaultSystemFont`;
  - that calls `SystemFonts::Initialize` (`ui/gfx/system_fonts_win.cc:194`), which calls
    `AddFont`, then `GetFontFromLOGFONT` (line 112), then `PlatformFont::CreateFromNameAndSize`;
  - `PlatformFontSkia::InitFromDetails`: when `CreateSkTypeface` finds neither the mapped face
    name nor the fallback `sans`, it calls `EnsuresDefaultFontIsInitialized` again.
- `is_initialized_` is set only at the end of `Initialize`, so the cycle has no exit [I]. The
  cycle requires that Skia can create no typeface at all on the phone. Under desktop Proton the
  same build reaches sign-in, and the launcher's d2d `DrawTextLayout` failures in the earlier run
  point the same way: Wine's DirectWrite on the phone finds no usable font [I]. Not checked.
- **A second fault [M].** After the browser died, the storage service's main thread jumped to
  guest RIP `0x30000010a`. FEX's `CompileBlock` (`libarm64ecfex.dll+0x1d46c`) then read
  address `0x48`. `ResetToConsistentStateImpl` hit the same fault about 50 times. Not diagnosed.

## Not checked

- The sign-in page, renderers and their reservations: no renderer started.
- Whether Wine's DirectWrite on the phone enumerates any font. It did not: see
  [CEF fonts on the phone](2026-10-16-cef-fonts-phone.md) (PLA-374).
