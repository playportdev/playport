# Xbox save conflicts in the runtime: a question per container, the cloud's side kept (patches/xgameruntime 0002)

**Date:** 2026-10-30. **Linear:** [PLA-485](https://linear.app/playportdev/issue/PLA-485).
**Kind:** host build and tests on the workstation, in a side copy (decision
[0117](../decisions/0117-side-copies-that-build.md)). Headless: no display, and no crash dialog
in the test prefixes. No phone run.

## Result

**Passed.** The review of PLA-485 found three faults in 0002's conflict handling. They are
fixed, and each has a test that failed before the fix:

| Fault | Before | With 0002 now |
| --- | --- | --- |
| The host's reply was searched with `strstr`, but the bridge's buffer has a size and no NUL. | A `<Choice>` past the stated size was taken. | The reply is parsed with `xmlReadMemory` within its size, with `XML_PARSE_NONET` and no DTD. Only the root `SaveConflictResponse`'s `Choice` counts. |
| One question per sync: the first answer settled every conflicting container. | A second conflicting container was never asked about. | Each conflicting container sends its own `SaveConflictRequest` (its own Container, DisplayName and times). The answer applies to that container only. An unanswered container keeps both sides. The others still sync, and the sync reports `E_GS_CONTAINER_NOT_IN_SYNC`. |
| `local` uploaded over the cloud's side with no copy of it. | The cloud's version was lost. | The cloud's container is first downloaded whole into a `.recovery-cloud-` tree, beside the `.recovery-` copy a download keeps of the local side. Only then is it uploaded. If the copy cannot be made, nothing is uploaded and the container stays dirty. |

The wire protocol is unchanged: a `SaveConflictRequest` with Scid, Container, DisplayName,
LocalTime, CloudTime and CloudDevice, and a `SaveConflictResponse` with
`<Choice>local|cloud|none</Choice>`.

## What ran

| Part | What |
| --- | --- |
| Source | The pin `ab2fac35`, then `git am -3` of `patches/xgameruntime` 0001–0003 in `series` order onto a clean worktree. The result is the same tree (`db5c933`) as the one the patches were written from. 0001 is byte-identical. 0003 changes only its context line in `scripts/test-component.mjs`. |
| Build | `cmake` with `ENABLE_TESTS=ON` and `ARCH=x86_64`, using llvm-mingw 20260922. The build was against the Wine tree and `widl` of the PLA-495 desktop proof. `$PLAYPORT_BUILD/bin/xgameruntime.dll` (unstripped) was 2,771,968 B, sha256 `8e4831faa59e3809703f474daffa64c8d89b63384ff6ff61819b2c30c655c3f7`. |
| arm64ec | `-fsyntax-only` on `XGameSave.cpp` with `arm64ec-w64-mingw32-clang++`: clean. |
| Baseline | The same build of the pin with the previous 0001–0003 (`xgameruntime.dll` sha256 `a4ff08cc…`). |
| Wines | The host's Wine 11.20. Also the PLA-495 desktop build of Playport's Wine with `patches/wine-gdk` (x86_64). |

## Tests

`env -u DISPLAY -u WAYLAND_DISPLAY` was used, with `WineDbg ShowCrashDialog=0` in each prefix.
The save state under `LOCALAPPDATA` was cleared between runs:
`nexus_gamesave-files` expects a fresh folder and fails 3 of its checks on a prefix reused
without clearing, with or without the patch.

| Test | Baseline (both Wines) | New tests, old code (wine-gdk) | Patched, host Wine 11.20 | Patched, Playport's Wine (wine-gdk) |
| --- | --- | --- | --- | --- |
| `nexus_gamesave-sync` | 315/0 | 407 checks, 28 failures | **407/0** | **407/0** |
| `nexus_gamesave-transfer` | 263/0 | — | **263/0** | **263/0** |
| `nexus_gamesave-files` | 25/0 | — | **25/0** | **25/0** |
| `nexus_gamesave-file-paths` | 55/0 | — | **55/0** | **55/0** |

The 92 new `gamesave-sync` checks run for both providers, the container provider and
XGameSaveFiles. They cover:
- **A reply cut short:** the choice lies past the stated size. Nothing is taken: no
  download, no upload, and both sides are kept.
- **`local` when the cloud's side cannot be read whole:** nothing is uploaded, no partial
  `.recovery-cloud-` tree is left, and the local container is kept dirty.
- **`local`:**
  - the cloud's container is kept whole in one `.recovery-cloud-` tree before the upload
    is tried;
  - the local data is unchanged and still unsynced when the closed fixture refuses the
    upload.
- **Two conflicting containers, in both orders (`cloud`/`none`, then `none`/`cloud`):**
  - two questions are asked, Save then Other, and each names its own container;
  - the container answered `cloud` is downloaded and synced;
  - the other is preserved dirty;
  - the sync reports `E_GS_CONTAINER_NOT_IN_SYNC`.

The new tests failed on the old code: the bounded reply, the cloud's copy and the
per-container question. `scripts/test-component.mjs` therefore requires 407 for
`nexus_gamesave-sync`, up from 315.

## Not shown here

- A real host answering over the keyed bridge. The tests answer through
  `SaveTransport::Conflict`'s fixture.
- A real cloud: the transport is a closed fixture. A `local` upload's success is not shown,
  only that it is attempted after the copy, and that its failure leaves the local data.
