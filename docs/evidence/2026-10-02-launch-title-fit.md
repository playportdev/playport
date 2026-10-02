# Launch-screen long titles fit the phone

Branch `fix/launch-screen-long-titles`, in a worktree from `main` (`0ad94ce`).
The worktree uses the existing `$PLAYPORT_BUILD` caches and native run trees;
no pins, patches or committed artifact records changed.

## Fix

The aspect-fill artwork was a layout participant in the launch screen's
ZStack. It widened the foreground beyond the window, so the title's
minimum scale factor did not prevent clipping. Make the art a background
of the screen-sized foreground instead. Allow the title to wrap to two
centred lines and scale down as needed, retaining the symmetric window
safe-area margins around the Dynamic Island. Short titles keep one line.

## Phone evidence

Before IPA SHA256:
`e0960e4e8c10365f619848ff510a6d2904e9891685e8e8504d823923d7d449b1`.

Changed dev IPA SHA256 (all after runs):
`9833327a2295a816a5f8807d68f9a88354e2e5c870e43d11e46e227fa255ce9a`.

Screenshots remain under `$PLAYPORT_BUILD/ui-runs/`; none are published.

- `launch-title-before/screen-stop.png`: Witcher 3's uppercased name ran
  off both edges; the beginning and end were missing.
- `launch-title-after/screen-stop.png`: the full name, **The Witcher 3:
  Wild Hunt — Remastered**, is visible on two centred lines, with side
  margins. The progress bar, status, controller note and menu tip remain
  visible without overlap. Both Witcher runs used Play and stopped at
  `mark:surface ready; asking for JIT+0`; this verifies the launch screen,
  not a playable Witcher session (its pre-first-frame failure is unchanged).
- `launch-title-hk/screen-0000s.png`: **Hollow Knight** remains centred on
  one line, with the progress/status and footer visible. The subsequent
  game failed before its first frame (`exit=0xc0000005`); the saved
  arguments were `-force-d3d12`, selecting Vulkan.
- `launch-title-hk-dx11`: temporary UI launch settings
  `{"arguments":"-force-d3d11","graphics":"dxmt"}` reached the first
  frame at 9.48 s and ran through `first-frame+10`, result `ok=true`, no
  pool exhaustion. `screen-stop.png` shows the game's main menu. The
  settings are session-scoped, not a permanent change to the game.

## Host checks

- `pp check` and `pp check --variant release`: both app variants compile.
- `pp test`: all passed (name/secret/patch gates, 479 tooling tests,
  host C tests including pad ThreadSanitizer, and all Swift packages).
- Build/install: verified dev IPA, upgraded in place.

The slow-JIT expanded layout and the opposite landscape orientation were
not exercised on the phone.
