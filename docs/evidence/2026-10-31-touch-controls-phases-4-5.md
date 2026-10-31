# 2026-10-31: touch controls phases 4–5 on the phone (Keyboard & mouse, Point & click, touch keyboard, layout editor)

**Linear:** [PLA-538](https://linear.app/playportdev/issue/PLA-538) (parent
[PLA-13](https://linear.app/playportdev/issue/PLA-13)). **Plan:**
[touch controls](../plans/2026-10-09-touch-controls.md), phase 4 and 5 gates. Before:
[U](2026-10-13-touch-controls-U.md). Branch `dev/pla-13-touch-controls-gates`: the phase 4–6
integration branch rebased on main `3fb12cc`, with merges kept (`git rebase --rebase-merges`; each
in-branch merge's conflicts resolved as the original merge did). The tree equals the old branch tip
plus main's changes, except that the XInput read counter moved from madeira-unix 0224 to **0247**
(main's 0224 is Social Club's layout).

| IPA | sha256 | Built from |
| --- | --- | --- |
| `Playport-26.5-6f177007.ipa` (dev) | `6f177007b6d46078a0125da1517ca597e9af151bf81edb1eef9a96350b2f2295` | `0cac95b` |
| `Playport-26.5-release-173f7f90.ipa` (release) | `173f7f90de28f974fd324bf103163b8555df8afa65b9803a1667e4dc0e751b17` | `fc19fb8` |

Host: `pp test` all passed. `pp build` verified the dev IPA (90 checks; Unix stage rebuilt for
0247). The release build passed `pp verify --variant release` (95 checks, 0 failures). Phone:
iPhone18,4, iOS 27.2, the session unattended. Runs are in
`$PLAYPORT_BUILD/agent-notes/pla-13-p4/runs6b`, `runs6b-2` and `runs6b-3`, with their scripts beside
them (`phone-session-6b*.sh`).

## Results

| Gate | Result | Run |
| --- | --- | --- |
| Hollow Knight `first-frame+10` | passed in every Hollow Knight run (7): first frame +9.36 to +10.18 s | `runs6b/hk-smoke`, `hk-end`; `runs6b-2/hk-end`; `runs6b-3/hk-*` |
| Settings › Controls › Starting layout | shown, "Suggested for the game" | `runs6b/settings-controls` |
| Touch keyboard types into a game's text field | **passed** | `runs6b-2/p2-keyboard` |
| Point & click on a menu | **passed** (Hollow Knight) | `runs6b-3/hk-point` |
| A driven `--controls` layout (the game's own copy) | **passed**: drawn, and its keys reach the game | `runs6b-3/hk-own`, `hk-own-z` |
| The layout editor over the paused game | **passed** | `runs6b-2/editor-ingame` |
| The layout editor from Game options | **not run**: `open:ID#layout` is cancelled (PLA-597) | `runs6b-2/editor-options` |
| Portal 2 Keyboard & mouse in a level (moves, looks, fires) | **not run**: Portal 2 crashes when it loads a map (PLA-596) | `runs6b-2/p2-km`, `p2-own` |
| 3c cosmetics | mostly fixed; one value truncated again (PLA-598) | `runs6b-2/panel-3c` |

### What the runs showed

- **Touch keyboard** (Portal 2 at its main menu with `-console`, Keyboard & mouse layout): the
  in-game menu's **Touch keyboard** row opened the keyboard over the game, with F keys, the number
  row, letters, arrows, Ctrl/Win/Alt and Close. `touch:kb-e kb-c kb-h kb-o kb-space kb-shift kb-p
  kb-l kb-a kb-y` typed **"echo Play"** into the console's input field. A tapped Shift stayed down
  for the next key only (`held=kb-shift`, then clear), so only the P is upper case. After
  `kb-enter` the field was empty: the line went to the console. `kb-close` closed it
  (`controls: touch keyboard closed`).
- **Point & click** (Hollow Knight's main menu): the side bar (Right, Hover, Scroll, Keys, Esc)
  and the Tap to click / Trackpad switch drew as on the board. Tapping Hover lit it amber, and a
  second tap turned it off. A tap at (0.5, 0.62) of the view clicked the menu and opened a page of
  its Extras (Lifeblood). Hollow Knight's own menu arrows did not follow hovering, so the hover
  itself is not shown in a screenshot.
- **A driven layout:** `--controls` saved Hollow Knight's own Keyboard & mouse copy (look area, a
  stick of arrow keys, Z, X, Fire and Esc buttons, at given anchors). The log's `controls` line
  named `layouts=keyboardMouse(6 controls)`, and the layout drew from it rather than from the
  preset. `touch:jump` (Z) opened Select Profile, and `touch:attack` (X) went back to the title.
  The stick's arrow keys moved nothing in Hollow Knight's menu. That is the known missing
  extended-key flag (PLA-340), not the layout.
- **The layout editor over the paused game** (Portal 2, `menu:open menu:layout`): it opened over the
  paused game. It showed a grid, the bar (Add, preset Keyboard & mouse, Opacity 60%, undo, redo,
  Reset, Done) and a pad legend (A Edit, LB/RB Control, X Add, Y Reset, B Done). `pad:rb` selected
  the look area and opened the inspector ("Look · Look area · middle", Label, Remove). B came back
  and Resume went back to the game.
- **3c cosmetics, with the scripted pad:** the in-game Controls panel's "Controller" label fits
  on one line. The in-game Controller row says "Scripted pad". The panel shows Off/Pad/Keys/Point,
  "Edit layout…", Opacity, Gyro aim and Sensitivity. The menu's left column truncates the
  Controls value as "Keyboard & mouse · hi…" (PLA-598). The ActionPicker's footer was not
  reached: A on LT as a controller asks "Change what this input does?" first.

### Not checked, and why

- **Portal 2 crashes in this build.** Portal 2 was not installed on the phone, so the run installed
  it through the UI (`install:620`). It then ended `0xc0000417` when it loaded
  `+map sp_a1_intro3` (+27 s, the "Program Error" dialog), and once at its main menu. The crash
  follows `ISteamFriends017 GetFriendPersonaName() -> 0 (not served)`: Playport's i386
  steamclient (PLA-442, on main) returns NULL. That is **PLA-596**. The touch-controls branch does
  not change `app/SteamClientShim`. Portal 2's Keyboard & mouse gate (move, look, fire in a level)
  waits for that fix. On Hollow Knight's menu, the Keyboard & mouse look drag logged
  `driver drags look -100,0 pt: mouse -300,0 counts`, but the menu shows no camera to turn.
- **`open:ID#SECTION`** (Game options at a section, including `#layout`) ends every batch with
  `cancelled: task cancelled`, on main too (seen 2026-10-30 at `1413ed9`): **PLA-597**. So the
  editor from Game options and a read-only "before" of each game's controls were not driven.
- No owner hands-on play yet, and no release install. Both are owner steps (PLA-538).

The runs saved settings and controls through `--controls`/`--settings`, so DriverUndo puts each
game's own back at the app's next launch outside the session (Hollow Knight's Gamepad layout was
back at the next session). Portal 2 stays installed.
