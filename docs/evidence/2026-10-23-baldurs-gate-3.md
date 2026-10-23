# 2026-10-23: Baldur's Gate 3, a C++ rethrow and Wine's `__C_specific_handler`

**Date:** 2026-10-23. **Kind:** play on a phone, the app log with `WINEDEBUG=+seh`, a read of the
built DLLs (symbols and the SEH scope table). **Game:** Baldur's Gate 3 (Steam 1086940, build
25605617), started as `bin\bg3_dx11.exe`: x86-64, Direct3D 11, on DXMT. **Phone:** iPhone 17 Pro
Max (iPhone18,2), iOS 27.0.1. **Report:**
[#58](https://github.com/playportdev/playport/issues/58), which also lists what else the game
needed.

**Build:** Playport 0.4.0, the release IPA re-signed, with its arm64ec `ntdll.dll`,
`ucrtbase.dll`, `msvcrt.dll`, `msvcr110.dll` and `msvcr120.dll` replaced by builds of this change
on the 0.4.0 `wine-pe` tree. The DLLs were built on macOS with llvm-mingw 20260922 and the
configure flags of `build/stages/wine-pe.sh`. Unpatched, those five and `vcruntime140_1.dll`
reproduce the IPA byte for byte. Here the change is `wine-pe` 0045 on `main`'s series: it applies
cleanly, and the five DLLs build with no new warnings. It was not built with `pp build`, which
needs a Linux workstation, so `app/artifacts.tsv` and `build/generated/wine-pe-*.tsv` are not
updated here.

## The problem

The game reached its menus, then always ended on the loading screen of a level. It ended with exit
code `0xffff7001`, after `crashpad_client_win.cc:132] crash server failed to launch,
self-terminating`: crashpad's unhandled exception filter, with no handler process. With
`WINEDEBUG=+seh` and no log cap, the thread showed this:

1. The game throws an `ls::khonsu::Exception`, and a frame with a `catch` for it takes it
   (`__CxxFrameHandler4`, `find_catch_block4 matched`). `call_catch_block4` in `vcruntime140_1`
   registers the frame info (`__CxxRegisterExceptionObject`) and calls the catch funclet.
2. The funclet rethrows (`throw;`, `e06d7363` with no object). `cxx_rethrow_filter` returns
   `EXCEPTION_EXECUTE_HANDLER`, and `RtlUnwindEx` unwinds to the rethrow `__except` at
   `vcruntime140_1+0x118cc`. On the way, **the `__finally` of the same function runs**:
   `cxx_catch_cleanup` → `__CxxUnregisterExceptionObject` (the first time).
3. The `__except` re-raises the original exception. An outer frame catches it, and the unwind to
   it passes `call_catch_block4`'s frame again: `cxx_catch_cleanup` runs a second time, for frame
   info no longer in the list.
4. `_FindAndUnlinkFrame` reads `next` through a NULL list head: `SEGV addr=0x8` at
   `ucrtbase+0x1eec8` (`except.c:928`, inlined into `__CxxUnregisterExceptionObject`). Crashpad
   takes the access violation and ends the process.

Step 2 is the fault. `call_catch_block4` is one `__try`/`__finally` around a
`__try`/`__except`, and clang gives it this scope table (`vcruntime140_1.dll`, RVAs):

```
0  0x117b0-0x117c4  filter cxx_rethrow_filter  jump 0x118cc   (the rethrow __except)
1  0x117b0-0x117c4  __finally cxx_catch_cleanup
2  0x118cc-0x119b8  __finally cxx_catch_cleanup              (the same __try, the __except's range)
```

The target unwind starts at the call in the `__try` body, in records 0 and 1. Wine's
`__C_specific_handler` skips record 0, an `__except`. It then runs record 1's `__finally`,
because the target `0x118cc` is not in record 1's range, though it is in record 2, the same
`__try`. Windows stops there: records with the same handler and jump target are one scope, and an
`__except` record whose jump target is the unwind target ends the unwind.

## The change

`wine-pe` 0045 makes `__C_specific_handler` stop a target unwind at a record when the target is
in any record with the same handler and jump target, or is the record's own jump target. This is
in both copies of the handler:

- `dlls/ntdll/unwind.c` (the arm64 and x64 variants);
- `dlls/msvcrt/except.c` (arm64, arm and x64). `vcruntime140_1` imports `__C_specific_handler`
  from `vcruntime140`, which forwards it to `ucrtbase`. The first build changed only ntdll, and
  the game crashed in the same place.

Any Wine whose PE side is built with clang's SEH has such scope tables, so the bug is probably
not specific to the iOS port.

## Result

With the change, the level loads, and the game plays: a new game on the Nautiloid, and an Act 3
save in the Lower City and in the Temple of Bhaal, on the touch pad. The game is CPU-bound: about
8–10 FPS in the crowded city, 14 on the Nautiloid, and 32 in the Temple of Bhaal.

The figures are from the Metal HUD on the phone's screenshots, at 1564×720 on DXMT. The app's
footprint in the city was 7.95–8.22 GB, with 368–636 MB available. The screenshots are in #58,
and stay out of this record (decision 0043).
