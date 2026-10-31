# 2026-10-31: arrow keys reach a game as extended keys (madeira-unix 0248)

**Linear:** [PLA-340](https://linear.app/playportdev/issue/PLA-340), follow-ups
[PLA-599](https://linear.app/playportdev/issue/PLA-599) (keypad Enter) and
[PLA-600](https://linear.app/playportdev/issue/PLA-600) (clang 23 test fixtures). Branch
`dev/pla-340-mapped-arrow-keys-extended-flag`, on `dev/pla-13-touch-controls-gates` (which contains
main `3fb12cc`).

| IPA | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-8d8009f7.ipa` (dev) | `8d8009f79318f1daf61d2d5f9f105300d6856bc42d56b7daace49f7e8f7e541b` | `43c186f` |

Host: `pp test --quick` all passed (with the new `keys` C test). HostIOKit's Swift tests pass (157).
`pp build` verified the IPA (90 checks). In the app binary, `_playport_key_scan` and
`_winios_post_key_extended` are defined (`llvm-nm`). Phone: iPhone18,4, iOS 27.2. Runs are in
`$PLAYPORT_BUILD/evidence/pla340/`.

## Cause

`winios_drv_post_key` took a posted key's scan code from Wine's
`MapVirtualKeyEx(MAPVK_VK_TO_VSC_EX)` and set `KEYEVENTF_EXTENDEDKEY` only when that returned an E0
code. Wine's kbdus table searches its base entries before its E0 entries, and the base table lists
the arrows, the nav cluster and Print Screen at the numpad's (and SysRq's) scan codes (`T48 _EQ(UP)`).
VK_UP therefore became plain `0x48`, which is numpad 8 to a game that reads scan codes. This
affected the hardware keyboard and mapped keys alike.

## Results

| Check | Result | Run |
| --- | --- | --- |
| Hollow Knight first-frame+10 | **passed**: first frame at +10.17 s | `hk-smoke` |
| Arrow keys from a Keyboard & mouse layout whose stick is arrow keys, on Hollow Knight's title menu | **passed**: see below | `hk-own-layout`, `hk-own` |
| Keypad Enter as E0 1C (PLA-599) | **not checked**: `pp ui` has no hardware-keyboard input | — |

The arrow-key run repeats the touch-controls run that found the bug
([phases 4–5](2026-10-31-touch-controls-phases-4-5.md), `runs6b-3/hk-own`): the same saved layout,
then `touch:move.down`, `move.down`, `move.up`, 300 ms each.

- **Before** (IPA `6f177007…`): the log has `drv_post_key vk=0x28 scan=0x50 flags=0x0`, and Hollow
  Knight's menu did not move.
- **After** (IPA `8d8009f7…`): the log has `vk=0x28 scan=0xe050 flags=0x1`, and the key-up has
  `flags=0x3`. Up is `vk=0x26 scan=0xe048`. In the screenshots, the menu's selection goes from Start
  Game to Options, then to Achievements, then back to Options.

The run saved Hollow Knight's controls with `--controls`. DriverUndo puts the game's own layout back
at the app's next launch outside the session.
