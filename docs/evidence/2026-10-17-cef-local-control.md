# Local Windows CEF diagnostic: invalid baseline control

**Linear:** [PLA-379](https://linear.app/playportdev/issue/PLA-379), under
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Result:** INVALID CONTROL. The sole baseline launch failed in Proton prefix
setup before the diagnostic executable started. The candidate was **not run**.
No JavaScript, DOM, worker, paint or code-range conclusion is possible. The
[existing candidate visual rejection](2026-10-17-cef-jitless-code-range.md)
remains in force; PLA-379 is not complete and PLA-380 stays stopped.

Run `c9dceb68-0612-467d-a108-79627582072b` (owner-selected Sol high),
`dev/pla-291-rockstar-launcher`, starting HEAD `9bf7ecd`. This records only the
supervisor-authorized bounded local diagnostic. No Rockstar launch, closed-binary
analysis, credentials, game, phone, app build/install or libcef rebuild occurred.
Only documentation/status is committed; unfinished patch 0007, series and
candidate payload record were not changed, staged or committed.

## Harness and verified inputs

All scratch paths below are under `$PLAYPORT_BUILD/agent-notes/pla379-local-cef/`.
`host.c` is a small MIT-licensed C host using pinned CEF headers, generated API
headers and the existing baseline `libcef.lib`. It builds as PE32+ Windows x64
with the existing llvm-mingw UCRT compiler, `CEF_API_VERSION=14300`; no C++ wrapper,
Chromium build, download, xwin invocation or new Microsoft component is needed.
`compile.command`, `compile.log`, `compile.exit` preserve the successful compile
(exit 0). An initial compile failed on the source tree's net-error include;
adding the pinned Chromium source include directory fixed that compile issue
before any runtime arm. The host checks the CEF platform API hash at startup
(`122bae6ae9a9961fb2fc27bd10aede159858f870`), but never reached that check here.

Both payloads were staged and every copied runtime file rehashed. There are
232 files in each, with identical relative names; **only libcef.dll differs**.
Manifests: `{baseline,candidate}/inputs.sha256`; summary: `inputs.json`.

| Input | SHA-256 |
| --- | --- |
| Baseline libcef.dll | `a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e` |
| Candidate libcef.dll | `13210e75e4056eb41cc0a32bdc85dc4f66425700d756957000d5952864faef44` |
| Context snapshot, both | `ab1090ad4b547fbd8047001f657ca1af6c15d871ccfbb40ff76b2b708f0ad99f` |
| chrome_elf.dll, both | `6ceaf1f1afa9dd96d8ec2b9082c3fe6e180c3960e3cc579bc13abf7c1aa67367` |
| Diagnostic executable, both | `9658dd9613ad503b055396dd6bf1ef1302a26da7b80d6b8471b6a69f0fa0c83e` |
| host.c | `f426c82e68e5ff5ac3d5779c0c91e1e91e77b070c070ec33ab293c9fad3ba99b` |
| page/index.html | `29e013e76d9eca812631c8f65f54833d15ff4f87180b8af55730eba915b1223f` |
| page/worker.js | `5e5015cd2fca9f53ceead263eaa9e30a672d2d49a2745eafdd2f6c98dea77865` |

The local-only page contains HTML_LOADED, synchronous arithmetic/function/regexp
checks (SYNC_PASS_42), a Promise (PROMISE_PASS_43), timer (TIMER_PASS_44) and
same-origin worker response (WORKER_PASS_45). Each updates text and a colored
strip, and emits a console marker. The server binds only `127.0.0.1:18793`, with
CSP, no external assets and no authentication. The host independently requests
`frame.get_text` once per second, writing `dom-last.txt`: the supported CEF path
reads Blink's current document text, not script source or console output
(`cef/libcef/renderer/frame_impl.cc:855–866`, relative to the pinned source).
Native callbacks record console, load errors and renderer termination. OSR
OnPaint writes raw BGRA and PPM, with per-frame FNV hashes for later SHA-256 and
visual comparison. These are designed controls, **not measured runtime results**.

Configuration is identical for both prepared arms: 640×360, scale 1, 15 fps,
en-US, fresh profile, no sandbox, default native request context, software OSR.
OSR uses Alloy style and bypasses final window presentation, unlike Social Club;
there are no remote services, multiple frames or complex launcher workload.
Proton's WineD3D option is also explicit. Thus even a passing diagnostic would
not replace the Social Club visual gate or phone acceptance.

The exact command/environment is `baseline/run/command.json`. Relevant switches:

```
--in-process-gpu --disable-gpu --disable-gpu-compositing
--js-flags=--jitless
--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess
```

Additional identical controls disable first-run/default-browser prompts,
background networking, component updates, domain reliability and sync; force
direct proxy handling; and reject host resolution except loopback. Steam clients
and URL opens are disabled, with an empty scratch Steam client directory.
The verified sway-nocap PID 1025249 owned wayland-1 and X0; `xdpyinfo :0` worked.
The launch explicitly used `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`, never niri.
TMPDIR and all newly created scratch files are under the diagnostic directory.

## Sole arm and failure

`run.py baseline` bounded the producer to 30 seconds, plus cleanup. It copied
Proton's shipped `default_pfx` into a fresh scratch `baseline/compat/pfx`.
This was a harness error: copied Wine DLL relative symlinks become dangling
outside Proton's installation tree. Proton's subsequent prefix upgrade sees
the target missing and tries to create an absolute symlink at the existing link.
The preserved traceback reports `FileExistsError` for `msado15.dll` in prefix
setup (`pfx_copy`/`copy_pfx`), **before any Windows executable launched**.
Read-only inspection of those open-source functions and the copied symlink
confirms this setup explanation. It is not a libcef or JavaScript failure.

- Producer PID **1079442**, filter PID **1079441**.
- Producer exited **1** within the first second; filter exit **0**.
- Wrapper exit **0** means evidence/cleanup finished, **not successful control**.
- Result explicitly records `control_pass: false`; elapsed wall time 32.175 s
  includes the 30-second arm and approximately two seconds of cleanup waits.
- No host logs, page requests, native load/termination callbacks, JS/DOM/worker
  results or paint files. Reservation measurements are **unavailable**, not zero.
- Every prefix PID snapshot and the final scan were empty. No signals were
  required; no survivors and no listener on port 18793 remain.
- Candidate arm **not launched**. No launch retry or post-failure harness fix.

Raw evidence: `baseline-wrapper.{log,exit}`, `baseline/run/{wine.log,server.log,
result.json,processes.json,command.json}`, `cleanup-verification.json`.
There are no screenshots because the host never started.

## Stop and next step

The task's baseline-failure stop rule was applied. This probe establishes no new
runtime property of either payload. The failing candidate remains rejected and
must not be packaged; its patch/series/record remain unfinished. The next single
step is supervisor review of a corrected fresh-prefix initialization approach
(let Proton create the prefix rather than relocating its template symlinks)
before authorizing any new baseline control. No new run is authorized by this
record. Linear status synchronization is left to the supervisor session.
