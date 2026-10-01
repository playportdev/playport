# The UI as the only entry point: the device check

**Date:** 2026-09-25. **Decision:** [0012](../decisions/0012-the-ui-is-the-only-entry-point.md).
**IPA:** `Playport-26.5-720344da.ipa` (dev), sha256
`720344da83257f48041352a670188784f5a7951fa3de282bb8c20fdb01accc0a`; verify-ipa
59 checks passed, 0 failed. Installed in place with `pp install`.

## Host

`pp test`: the name gate, `tools/tests` (30 tests, 7 skipped as before), the
four host C tests (the controller block, also under ThreadSanitizer,
`host_log.c` and the title path resolver) and the HostIOKit, SteamClient and
PlayportKit Swift tests all pass. `pp check` compiles the dev and the release
app. The build's `stage` step reports `registry seed verified unchanged`.

## Phone

`pp ui --play app-367520 --until first-frame+10 --shot`, through the Play
button (`S1_MODE=ui`, `UI_ACTIONS=play:app-367520`, no other launch variable):

| Mark | Seconds from Play |
| --- | --- |
| surface ready; asking for JIT | 0.02 |
| runtime started (built-in helper, 896 MiB, 3.01 s) | 3.04 |
| game started | 3.06 |
| first frame | 12.20 |

The driver stopped 10 s after the first frame (`result ok`, exit 0), with
Hollow Knight at its main menu at 120 FPS in the screenshot.
`pp ui --action open:settings --shot-each-action` shows Settings without
the Diagnostics link. The container holds no shared `madeira.cfg`, so nothing
is left that no tool can now remove.
