# 0011: No workstation JIT

**Status:** accepted, 2026-09-25. Supersedes the statement in
[0010](0010-jit-without-a-host.md) that the workstation's activation tool
stays for driven harness launches. The driven launch modes it names are
retired by [0012](0012-the-ui-is-the-only-entry-point.md); the UI driver's
launches use the built-in helper as this record says.

## Decision

No workstation provides JIT. The host activation tool
(`harness/g0/tools/stik_universal_debug.py`) and its patched `idevice-tools`
build are removed, and the app no longer waits for a host debugger. Every
launch gets its pool on the phone: a driven dev launch (`S1_MODE`, a ladder or
G2 step) always from the built-in helper, a Home Screen launch from the method
chosen in Settings (built-in by default; StikDebug in a dev build).

## Why

The drivers and the Home Screen took two different JIT routes, so gate runs
measured a route no player uses, and the host route needed its own patched
tool, a socat bridge and Python `pexpect`. The built-in helper already ran
driven launches (`S1_JIT=builtIn`) unattended.

## Costs

- Every gate and driven run needs LocalDevVPN connected and the pairing file
  in the app's Keychain (imported once per phone; it outlives a reinstall).
- A launch waits for the helper, which may first mount the Developer Disk
  Image: driven launches wait 180 s for the pool instead of 90 s.
- A gate now also fails when the helper does (the private NSExtension
  methods, the tunnel, the DDI mount), not only when the runtime does.
