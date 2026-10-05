# 0051: JIT from StikDebug or another app, beside the built-in helper

**Status:** accepted, 2026-10-05. Narrows [0009](0009-dev-and-release-builds.md)
(a release build's JIT is no longer "built-in only"),
[0010](0010-jit-without-a-host.md) and [0011](0011-no-workstation-jit.md)
(a Home Screen launch need not get its pool from the built-in helper). No
workstation provides JIT still (0011), and every method ends in the same
universal `brk #0xf00d` protocol.

## Decision

- **Three JIT methods, chosen in Settings › Setup check › JIT method**, in
  both variants (PlayportKit `JitMethod`, `UI/JitMethodPicker.swift`; X on the
  setup checklist's first step opens the same picker):
  - **Built-in** (the default): the app's own helper extension, as before.
  - **StikDebug**: Play opens
    `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js`
    (StikJIT `INTEGRATION.md`, "Configure the JIT methods") and waits. The
    script is StikDebug's own `universal.js`, which speaks the protocol
    `wine_host_jit_pool_acquire` uses; Playport's own
    `playport-universal.js` stays in the helper.
  - **Another app**: Play only waits for a debugger: LiveContainer's
    *Launch with JIT*, SideStore, StikDebug started by hand, each running
    `universal.js` (or a script speaking the same protocol).
- **A debugger already attached is used whatever the method.** LiveContainer's
  *Launch with JIT* attaches before the app runs and its script waits at the
  first `brk`, so the Play acquires the pool at once.
- **Inside LiveContainer** (`LC_HOME_PATH` set) the built-in helper is not
  offered and never started: LiveContainer cannot start an app extension. A
  stored or default Built-in reads as Another app.
- **With JIT from another app, Playport's pairing and LocalDevVPN are not
  setup steps.** The checklist marks them settled (StikDebug still asks for
  LocalDevVPN, which it uses), and the check before a Play does not stop it.
- **No restart without the pairing or inside LiveContainer.** After a game,
  CoreDevice would relaunch LiveContainer rather than Playport, and the
  request needs the pairing. Playport then says to close it and launch it
  again (with JIT), and the game's page offers Close Playport, as for a
  failed restart (0029, 0030). Outside LiveContainer, a stored pairing still
  restarts Playport whatever the JIT method.

## Why

A player asked for it: the built-in helper "doesn't work under LiveContainer,
so it would be nice for the app to also support the old fashioned way of
enabling JIT". StikJIT's integration guide asks for the same three methods,
and for the built-in one to be hidden under LiveContainer.

## Costs

- An external method is only as good as its app: Playport cannot see why
  StikDebug or LiveContainer did not attach, only that no debugger came.
  The launch screen names the method and the script.
- A debugger without the protocol script (a plain attach), or a phone where
  the script does not run (TXM absent), lets the first `brk` kill the app,
  as with the built-in helper on such a phone.
- Under LiveContainer, every game needs a fresh launch from LiveContainer.
- Not yet run on the phone: neither StikDebug nor LiveContainer is installed
  on the reference phone. Only Built-in was checked after the change.
