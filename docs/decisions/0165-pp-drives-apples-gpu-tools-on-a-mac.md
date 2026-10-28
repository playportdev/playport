# 0165: `pp gpu` drives Apple's GPU tools on a Mac; the app may start with Metal's capture layer

**Status:** accepted, 2026-10-28, by the owner in the second Mac session ("fix GPU tracing and all
other tooling here on Mac to not have manual steps with Xcode", PLA-458). Amends
[0031](0031-a-mac-for-analysis-only.md) and [0164](0164-pp-ui-from-the-mac.md).

## Decision

- **On a Mac, `pp gpu live` (with `--capture`, `--profile`, `--trace`) and `pp gpu profile` run** Apple's command-line tools
  (`gpucapture`, `gpudebug`, `xctrace`) against the phone, under the device lock, with the play
  through `pp ui` as before. No Xcode window is used: when the phone is not yet a remote device of
  those tools, `pp` starts Xcode hidden (`open -gj`) for its GPU tools agent and never drives it.
- **`pp ui --capture-layer`** adds `MTL_CAPTURE_ENABLED=1` to the dev app's launch environment.
  Metal loads its capture layer, which connects to Apple's tools, only when the process starts with
  it; Settings' GPU capture `setenv()`s it inside the process, which is enough for the app's own
  `MTLCaptureManager` trace but not for `gpucapture` or Xcode. It is a launch variable of the
  driver, like `HIO_VPAD`, not a way into app functionality: the play is still the Play button
  (decision 0012).
- Building, signing and installing stay as 0031 and 0164 say, except where the owner allows a
  reinstall from the Mac for a session.

## Why

- The first session's open questions came from manual Xcode steps: the capture button stayed grey,
  the profile was exported by hand, and the replay device appeared to `gpudebug` only while Xcode
  replayed. With the launch variable `gpucapture list` sees Playport's process on the phone, and
  `gpucapture start` captures a frame of the running game straight into the Mac's run directory.
- The Witcher 3's GPU frame (~28 ms) needs repeated captures and profiles of chosen scenes, which
  the pads' routes make repeatable only when the capture and the profile are scripted too.

## Costs

- The capture layer costs CPU on every Metal call while it is loaded: a `--capture-layer` play's
  frame figures are not a measurement (`pp perf` is).
- A Mac-only path in `pp`: `tools/apple.py` refuses elsewhere; its results cannot be rerun on the
  workstation, as 0031 says.
