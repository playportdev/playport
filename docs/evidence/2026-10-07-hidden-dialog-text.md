# Evidence: hidden dialog text (PLA-59)

## Change

Madeira-unix 0094 logs `[win-text]` at win32u's common ANSI/Unicode text-setting path
(`WM_NCCREATE`, then `WM_SETTEXT`), not at a sampled geometry change. Top-level captions
and textual Static children carry their window handle and root, for correlation with
`[win-pos]`. The existing wine-pe 0011 `[msgbox]` diagnostic is unchanged.

The hook reads window metadata outside the WND lock, without invoking a guest window
procedure. Nonempty changed text is logged; identical updates are silent. Edit controls
(including top-level Edit controls), image/non-text Static controls and message-only trees
are excluded. Each entry keeps at most 1024 UTF-16 units, escaping controls, quotes,
backslashes and non-ASCII units; `...` marks the limit. Unicode surrogate pairs remain
recoverable as escaped UTF-16. No allocation is added to the diagnostic itself.

This does not present or dismiss dialogs and cannot capture owner-drawn text which never
becomes window text. Like the existing MessageBox diagnostic, a guest's caption or dialog
body may contain private information; review/redact before sharing. There is no new
account action, launch mode or developer title.

## Host checks

`./pp test` passed (Python, host C and all Swift packages); the two focused diagnostic
tests also passed separately. `./pp test --quick` passed again with the chunk staged;
`pp names` and `pp secrets` are clean. `./pp build` passed all 80 IPA checks; the existing archive
link diagnostic first prints duplicate wineserver globals, then its adjusted link test
passes (`libwineserver-ws4.a`).

Dev IPA: `.work/out/20261007-224157-cfed9639/Playport-26.5-cfed9639.ipa`, sha256
`cfed9639b273f11dc4cae4c9b3ed0ab88800db41b5cf0a106fda44b6065d3cfb`.

`tools/tests/test_window_text_log.py` compiles the policy and formatter directly from the
shipped patch (all Static styles, Edit exclusion, Unicode, line escapes, empty text,
truncation, an unterminated limit-sized input and buffer
canaries). When the local runtime tree is present and patched, it also compiles the actual
setter with Wine/server/driver stand-ins to check creation, ANSI/Unicode updates, duplicate
suppression, empty/resource/invalid-window handling and logging outside the WND lock.

## Phone

Installed in place, then played through the UI on iPhone18,4 / iOS 27.0, built-in JIT:

| Run (under `.work/agent-notes/hidden-dialog/`) | Result |
| --- | --- |
| `jwe-normal` | normal Epic launch: game started +3.08 s; no frame or top-level window in the 45 s observation; screenshot black; pool head 70 MiB, no exhaustion |
| `jwe-missing-ovt-correct` | temporary UI launch argument `-epicovt=playport-missing-diagnostic.ovt`, before the proper Epic arguments: game started +3.14 s; no frame/window/text in 120 s after game start; screenshot black; no exhaustion |
| `hollow-knight` | normal regression: first frame +8.20 s, JIT 2.41 s, continued through `first-frame+10`; screenshot shows main menu; pool head 83 MiB, no exhaustion |
| `hk-glcore-dialog` | temporary `-force-glcore`: exits `0x00000001`, 0.54 s after game start, without a dialog; only the caption logged; unsupported OpenGL configuration, not a normal-launch regression; restart log confirms settings restored |
| `multiversus-vulkan-dialog` | refused before launch: MultiVersus is no longer installed; no compatibility play or dialog check occurred |
| `fm-resource-archiver` | normal Epic launch: first frame +3.77 s, then exit `0x00000001` about 1.32 s after game start; a top-level window but no nonempty caption or Static text; not fixed here |

Hollow Knight emits one caption entry after its initial geometry events:

```text
[win-text] hwnd=0x10030 root=0x10030 kind=caption class=c023 style=04cf0000 text="Hollow Knight"
```

JWE did not create a dialog in either run. The temporary missing ownership-token argument
was an attempt to provoke its former DRM error; it did not reproduce that window. This
controlled launch does not measure normal game compatibility. JWE's remaining no-frame
blocker is not fixed here. Settings are session-scoped and undone at the next app launch
outside the test session (the later Hollow Knight run also starts that undo).

**Verification limit:** the new caption path is shown on the phone; Static control body
logging and update/escape behaviour are host-tested, but **no Static-body dialog was
reproduced on the phone**. PLA-59 remains open for that device check. The failed/refused
attempts above are not evidence that a Static-body dialog was captured, nor fixes for
JWE or Resource Archiver. No developer test title was added to work around this limit.

Screenshots and raw logs remain in the run directories; no game artwork is published.
Compatibility results are recorded in Linear PLA-41 (JWE), PLA-42 (Hollow Knight) and
PLA-66 (Resource Archiver; the failure was filed, not fixed in passing).
