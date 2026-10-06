# 0010: JIT without a host at launch

**Status:** accepted, 2026-09-25. Supersedes the statements in
[0002](0002-linux-only-build.md) ("Why", "What a Mac would remove") and
[0003](0003-runtime-backend.md) ("Decision", "Constraints accepted with it")
that the debugger-assisted JIT activation needs a paired host at every
launch. Its statement that the workstation's activation tool stays for
driven launches is superseded by [0011](0011-no-workstation-jit.md).
[0051](0051-jit-from-another-app.md) adds StikDebug and another app (LiveContainer) beside the built-in helper, in both variants.

## Decision

A Home Screen launch gets its JIT pool with no workstation. By default the
app's own helper extension, `PlayportJIT.appex`, attaches with StikJIT
(StikDebug's MPL-2.0 framework, unmodified) and runs Playport's own
universal-protocol script. In a dev build, StikDebug installed beside the app
is the alternative. The workstation's activation tool stays for driven harness
launches only ([ARCHITECTURE.md, "JIT activation"](../ARCHITECTURE.md#jit-activation)).

## Why

A player cannot keep a paired Linux host at hand. With the built-in helper a
launch needs no second app, no app switch and no tap, and it acquired the
896 MiB pool in about 3 s
([evidence](../evidence/2026-09-24-builtin-jit.md)).

## Costs

- The phone still needs Developer Mode, LocalDevVPN with its tunnel up, and an
  RP pairing file made once from a workstation.
- The helper is started through private NSExtension methods on a borrowed
  extension point; an iOS update can break it.
- The helper has its own App ID, one of the ten a free team may register per
  week.
- The build is still a `get-task-allow` build: JIT still comes from a
  debugger attach.
