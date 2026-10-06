# JIT methods: Built-in still plays, the method row shows

What [decision 0051](../decisions/0051-jit-from-another-app.md) changed, run on
the phone on 2026-10-05.

- **IPA:** dev, commit `aa229a8` (branch `feature/external-jit`),
  sha256 `b010759fab725366a9ab47602c404ba0d4c0e006fe97fb6f69d44fdaba7063c3`.
- **Phone:** iPhone18,4, iOS 27.0, TXM present.

## Result

- **Built-in, the default, plays as before.** Hollow Knight (`pp ui --action
  set:jit.method=builtIn --play app-367520 --until first-frame+10`): the log
  starts the JIT step with `jit: method builtIn`, and the helper finished after
  2.60 s with a 512 MiB pool. The runtime started at +3.41 s, the game at
  +3.53 s and its first frame came at +8.52 s; the run went on to
  `first-frame+10`.
- **Settings › Setup check shows the method.** With nothing stored, a
  *JIT method* row reads **Built-in**, followed by the helper's row
  (*ready (TXM present)*). After `set:jit.method=stikDebug`, the row reads
  **StikDebug**, and the *JIT* row below it names StikDebug instead of the
  helper's readiness. The checklist summary stayed *3 of 3 done*.

## Not run

- **StikDebug and Another app** were not run: neither StikDebug nor
  LiveContainer is installed on the reference phone. The StikDebug request's
  URL is checked by a PlayportKit test only.
- **Inside LiveContainer** (`LC_HOME_PATH`), and the close-and-relaunch
  message after a game, were not run.
