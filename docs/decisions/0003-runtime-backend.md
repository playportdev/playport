# 0003: Runtime backend

**Status:** accepted, 2026-09-24; "a host at every launch" is superseded by [0010](0010-jit-without-a-host.md)

## Decision

Playport runs Windows games with Madeira's stack: Wine ARM64EC with FEX's
arm64ec PE (`xtajit64.dll`) translating x86-64 guest code, DXMT translating
Direct3D 10/11 to Metal, and Madeira's iOS unix layer with wineserver as a
thread, all in the app's one Mach process
([ARCHITECTURE.md](../ARCHITECTURE.md)). Executable memory comes from the
debugger-assisted JIT activation, which needs a paired host at every launch.

## Why

- It is the only stack known to run Windows games on a non-jailbroken
  iPhone, and it is open source.
- It is testable end to end on the phone: the probe ladder, the G2 probes and
  a title smoke exercise exactly this stack, and every build's results are
  recorded under `docs/evidence/`, starting with
  [the bootstrap record](../evidence/2026-09-24-bootstrap.md).
- Embedding a full-system emulator with a Linux guest would add a second
  operating system to the same memory and JIT budget for no gain on this
  hardware.

## Constraints accepted with it

- **x86-64 guests only.** WoW64 needs memory below 2 GB, which iOS's 4 GB
  page zero forbids.
- **No crash isolation between Windows processes.** They are threads of one
  process; a crash in any of them ends the app.
- **Direct3D 10/11 only.** D3D9, OpenGL and Vulkan titles are out; D3D12
  through Madeira's native runtime is not built
  ([0006](0006-licence.md)).
- **A host at every launch** for JIT, and a `get-task-allow` build.
- **Memory.** The JIT pool and the title share the app's memory limit, which
  needs the increased-memory-limit entitlement.
