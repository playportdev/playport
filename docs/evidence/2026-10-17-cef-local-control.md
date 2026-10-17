# Local Windows CEF diagnostic: corrected control and candidate agree

**Linear:** [PLA-379](https://linear.app/playportdev/issue/PLA-379), under
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Latest result:** corrected local baseline and candidate both pass JavaScript,
independent DOM and software OSR paint controls; final DOM and paint bytes agree.
Candidate traces have no 512 MiB code-range requests/views. This limited no-range
workload works; the [existing candidate visual rejection](2026-10-17-cef-jitless-code-range.md)
remains in force. PLA-379 is not complete; PLA-380 stays stopped. The original
prefix-setup failure below is preserved as historical invalid-control evidence;
see the corrected diagnostic section for the authorized continuation.

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

## Original arm and failure (historical)

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

## Original stop point (superseded by explicit continuation authorization)

The task's baseline-failure stop rule was applied. This probe establishes no new
runtime property of either payload. The failing candidate remains rejected and
must not be packaged; its patch/series/record remain unfinished. The next single
step is supervisor review of a corrected fresh-prefix initialization approach
(let Proton create the prefix rather than relocating its template symlinks)
before authorizing any new baseline control. No new run is authorized by this
record. Linear status synchronization is left to the supervisor session.

## Corrected diagnostic — authorized continuation, stopped after one pair

The supervisor independently confirmed the prefix-copy error and authorized a
setup correction at HEAD `37fe441`. Same Sol high run
`c9dceb68-0612-467d-a108-79627582072b`, continuation `78bedfc2`. The old failed
`baseline/` prefix/logs were not overwritten. The original scratch runner was
preserved as `run-invalid-prefix.py`; corrected `run.py` removes the template
copy, adds separate setup/runtime phases and checks full baseline console/DOM/
paint success before permitting candidate setup or runtime.

New paths under the scratch root: `corrected-{baseline,candidate}/`, each with
`compat/pfx`, `payload`, `setup`, `run`, `tmp`, `empty-steam` and `inputs.sha256`.
No host/page/worker recompile or source change: the exact executable and hashes
above were reused. All 232 runtime source/copy hashes were reverified before
setup and runtime, same file set, only libcef differs. `corrected-inputs.json`
records this check. All native CEF API hash checks matched version 14300.
Native settings, view/locale, page, switches and Proton options stayed identical;
only arm-specific scratch paths/process-generated identifiers differ. Browser
commands contain all five 0111 switches; renderer commands confirm jitless,
disabled GPU compositing and the same in-process service feature flags.

### Prefix setup and isolation

Each setup invoked normal `proton run C:\windows\system32\cmd.exe /d /c exit 0`
with a new, initially absent prefix, bounded to **180 s**, separate from CEF time.
Proton created its own prefix and converted Wine DLL links normally. Neither
installed Proton nor other prefixes were modified.

| Setup | Baseline | Candidate |
| --- | --- | --- |
| Producer PID / actual exit | 1082256 / **0** | 1082763 / **0** |
| Wall seconds, including cleanup | 3.062 | 3.043 |
| DLL/EXE symlinks checked / dangling | 1202 / **0** | 1202 / **0** |
| Canonical prefix PIDs before / after | empty / empty | empty / empty |

Setup service cleanup signalled only individually reverified canonical-prefix
PIDs (with matching `/proc` start times). Baseline used SIGTERM, then SIGKILL for
remaining winedevice PID 1082292; candidate used SIGTERM for PIDs 1082769/1082839.
The exact sets are in each `setup/result.json`; all were gone before CEF runtime.
Steam client DLLs/browser redirects remained disabled and the Steam client path
empty. Proton's own builtin `system32\steam.exe` launch shim appears in process
snapshots; this is not the owner's Steam client. Explicit sway `:0`/`wayland-1`
ownership/access was rechecked. The loopback server was active only for runtime.

### Corrected runtime outcomes

Exactly one corrected **30 s** runtime arm per payload; candidate ran only after
a valid baseline. Setup time was excluded. Browser close was requested at 22 s,
and each producer exited normally before the 30 s bound. Wrappers took about
32.3 s including cleanup waits, not additional CEF execution. No runtime process
was signalled or timed out. Wrapper success is independently backed by native
browser exits, console/DOM controls, paints and the actual producer exit codes.

| Observation | Baseline | Candidate |
| --- | --- | --- |
| Producer / trace filter PIDs | 1082418 / 1082417 | 1082934 / 1082933 |
| Producer / filter / wrapper exits | **0 / 0 / 0** | **0 / 0 / 0** |
| Browser Windows PID | 288 | 284 |
| HTTP index / worker requests | 200 / 200 | 200 / 200 |
| Main load-end ms / HTTP | 363 / 200 | 339 / 200 |
| Sync arithmetic/function/regexp console ms | 357 | 333 |
| Promise / timer console ms | 357 / 460 | 334 / 437 |
| Worker console ms | 377 | 353 |
| First independent complete DOM text ms | 1205 | 1193 |
| Native browser exit ms / code | 22025 / **0** | 22022 / **0** |
| OSR paints / dimensions | 5 / 640×360 | 5 / 640×360 |
| Load-error / renderer-termination callbacks | none / none | none / none |
| Canonical prefix PIDs before / after | empty / empty | empty / empty |

Times are relative to each native browser start, not performance comparisons.
Both `dom-last.txt` files contain all five expected markers. Native browser logs
report `dom=1 paints=5 errors=0 closed=1`. Four child logs each show startup/API
checks: storage, two renderers and transient ProcessorMetrics. Metrics child 748
explicitly returns subprocess exit 0 in both arms; the other three child exit
codes were **not captured**, so browser/producer exit 0 is not claimed as their
individual exit status. Process snapshots show the children present until browser
shutdown and no prefix processes by the first producer-exit snapshot (~23.15 s).
Both Chromium logs have the same network-change-notifier and unconfigured OAuth
warnings; neither prevented the wholly local controls completing.

Final DOM SHA-256, both:
`e7bd52aa02c206b4750ec7264a0a817ea9ddcf9dc707e44a62541136aaa97926`.
Final BGRA SHA-256, both:
`5c39f1fdcc8210b1d04f1eb2a4966ec424bb36e288bba474388935324f100363`.
Final PPM SHA-256, both:
`df23d78773cf25b1b6ff5e8712d27f696b1ff7736f690dfb218c34f77b9cbbcb`.
The entire five-frame hash sequences also agree. Pixel checks and inspected
`corrected-{baseline,candidate}/paint-last.png` images show the blue HTML marker
and four green JS completion strips, with matching text. These PNGs are offline
conversions of OSR paints, not final desktop screenshots; images remain in .work.

### Successful held reservations, not failed hints

`+pid,+virtual,+process` traces were filtered by the existing `vfilter64.py`.
Counting only successful 512 MiB `VIEW` results with matching view extent:

| Windows renderer PID | Baseline successful views | Peak held | Explicit releases | Unreleased in filtered trace |
| --- | ---: | ---: | ---: | ---: |
| 0228 (552) | 1 | 1 | 0 | 1 |
| 0234 (564) | 2 | 2 | 1 | 1 |
| Candidate, both renderers | **0** | **0** | **0** | **0** |

Baseline had three additional failed/unconfirmed `NOVIEW` hints, excluded from
held counts. The additional allocation on thread 02e0 is explicitly released;
MEM_DECOMMIT on the other views does not release their reservations. Baseline therefore has
three actual successful ranges (one subsequently freed), versus candidate **no
512 MiB request or successful view**. Two baseline views / 1 GiB lack explicit
release records in the filtered trace; **this is allocation/release bookkeeping,
not live VA after exit**. Process teardown reclaims their reservations. There is
no independent VirtualQuery inventory, total VA/footprint measurement or claim
that the trace directly enumerates live isolates. Raw lines and accounting are
preserved in `corrected-analysis.json` and each `run/wine.log`.

### Interpretation and final stop

**Observed:** both payloads execute the intended sync/Promise/timer/worker work,
independent document text agrees, and software OSR paint output agrees exactly;
the candidate does so without the traced code-range reservations.
**Limited inference:** this no-range workload works; blanket JavaScript
nonexecution is not supported by this probe. The SC visual gate remains
unresolved and workload/environment-dependent. This is not evidence that its
failure is necessarily painting, nor replacement SC or phone acceptance.

No further diagnostic arm, implementation, range size, packaging or PLA-380 work
was performed. The default assembled candidate remains rejected. Patch 0007,
series and payload record remain unchanged and uncommitted. No game or phone
acceptance. **ONE next step:** independent review of this passing local control
alongside the existing SC visual-gate evidence before selecting further diagnosis.

Raw evidence under each corrected arm: `setup/{wine.log,command.json,result.json,
processes.json,dll-exe-symlinks.json}`, `run/{wine.log,server.log,command.json,
result.json,processes.json}`, `payload/{host-*.log,chrome_debug.log,dom-last.txt,
paint-last.bgra,paint-last.ppm}`. Wrapper logs/exits are at the scratch root.
`analyze-corrected.py`, `corrected-analysis.{json,log}` preserve offline comparisons.
`corrected-cleanup-verification.json` records a final empty scan of all diagnostic
prefixes and successful port-18793 bind check after the servers stopped.
