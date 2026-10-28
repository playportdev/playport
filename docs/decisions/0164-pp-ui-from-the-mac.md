# 0164: `pp ui` may drive the phone from the Mac

**Status:** accepted, 2026-10-28, by the owner at the start of the Mac session
(PLA-457). Amends [0031](0031-a-mac-for-analysis-only.md). Amended by
[0165](0165-pp-drives-apples-gpu-tools-on-a-mac.md): `pp gpu live` and `pp gpu profile` run on the Mac too.

## Decision

During a Mac session, the Mac may run these `pp` commands against the
installed app:
- `pp ui`: launch through the app's Play button, pads, runtime settings,
  screenshots, the same as from the workstation;
- the read-only checks `pp phone status`, `pp secrets` and `pp names`.

Everything else in 0031 stands: the Mac does not build, sign, verify or
install (`pp build`, `pp check`, `pp install`, `pp release`, `pp sync` and the
pipeline stay on the Linux workstation, decision 0002), and Xcode never Runs,
Installs or Uninstalls Playport.

## Why

- The checkout and its build area are on the Mac for the session, and the
  items in [GPU-DEBUGGING.md](../GPU-DEBUGGING.md#on-a-mac) need a title
  launched, a save loaded by a pad and a runtime setting changed while
  Instruments records. Tapping by hand loses the pads' repeatable routes.
- `pp ui` drives the app's own UI (decision 0012), so launching through it is
  still the Play button.

## Costs

- **Untested tooling on macOS:** `pp ui` was written for the workstation
  (netmuxd, its socket, the device lock in `.work`). What it needs on macOS
  is found and recorded in the session.
- **Two hosts, one phone:** the device lock covers one `.work`; the workstation
  must not drive the phone while the Mac does.
