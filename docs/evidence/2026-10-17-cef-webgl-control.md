# Final local WebGL probe: invalid software-backend control

**Linear:** [PLA-379](https://linear.app/playportdev/issue/PLA-379), under
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Result:** STOPPED. Baseline shaders, draw/readback, independent DOM and OSR
canvas pixels pass, but public renderer identity reports hardware ANGLE/RADV,
not SwiftShader. The strict software-backend predicate fails. **Candidate was
not set up or launched.** This is not a software-WebGL A/B or candidate result.
The [SC visual rejection](2026-10-17-cef-jitless-code-range.md) remains unresolved;
current assembled candidate stays rejected and must not be packaged.

Same owner-selected Sol high, revived run `08925659-40f2-4994-8009-3195e258061b`, starting HEAD `d26e17e` on
`dev/pla-291-rockstar-launcher`. Preceding run
`78bedfc2-92eb-4de0-bbcf-0808d12a7c2b` completed the valid
[non-WebGL local control](2026-10-17-cef-local-control.md). The original reviewer's
follow-up identified software WebGL as the one concrete remaining local gap.
The supervisor authorized this final bounded extension, then explicitly confirmed
STOP on the observed backend mismatch: no candidate, flag change, new baseline
or tuning. Further direction belongs to the parent/owner, not an automatic
synthetic-test expansion. No SC, game, phone, app build/install, CEF rebuild,
PLA-380, source download, Microsoft acquisition or installed-Proton modification.

## Scratch changes and preserved inputs

All scratch paths below are under `$PLAYPORT_BUILD/agent-notes/pla379-local-cef/`.
Existing corrected runs, page, runner, host and input records were preserved:
`webgl-prior-evidence.json` seals **4717 paths**, all verified unchanged afterward.
New `webgl-page/`, `run-webgl.py`, `analyze-webgl.py` and
`webgl-{baseline,candidate}/` are separate. No scratch source is committed.

**Host unchanged, no recompile:** Windows x64 PE32+ MIT C host, CEF C API14300,
640×360 OSR, en-US, scale1,15fps, same native context/settings. It still records
callbacks and independently calls `cef_frame.get_text`; its exit predicate
covers the original five markers. The **new runner**, not native exit alone,
requires WebGL completion and the specified backend before candidate permission.

The local page retains the five original markers/worker. Its final60px contains
a320×60 WebGL1 canvas and WEBGL status. Minimal vertex/fragment shaders draw red
on the left and cyan on the right using endpoint colors. It records context
creation/loss, shader compile/link status/logs, public vendor/renderer/version
and `WEBGL_debug_renderer_info`, initial/final `getError`, `readPixels` and
context-loss state. Successful draw/readback publishes `WEBGL_PASS` to DOM and
console. Context failures remove that marker. No external assets/auth/content.

| Input | SHA-256 |
| --- | --- |
| Baseline libcef | `a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e` |
| Candidate libcef, staged only | `13210e75e4056eb41cc0a32bdc85dc4f66425700d756957000d5952864faef44` |
| Both context snapshots | `ab1090ad4b547fbd8047001f657ca1af6c15d871ccfbb40ff76b2b708f0ad99f` |
| Both chrome_elf.dll | `6ceaf1f1afa9dd96d8ec2b9082c3fe6e180c3960e3cc579bc13abf7c1aa67367` |
| Unchanged diagnostic executable | `9658dd9613ad503b055396dd6bf1ef1302a26da7b80d6b8471b6a69f0fa0c83e` |
| webgl-page/index.html | `fb0c5904d9b53d98111fcac590a0194de604b5e9187a0b43c454bfc00926cc55` |
| webgl-page/webgl.js | `89954ed9849b90501591003ae7d45dbac3fa09df462aeb7522db8edbc3f3ee02` |
| Unchanged worker.js | `5e5015cd2fca9f53ceead263eaa9e30a672d2d49a2745eafdd2f6c98dea77865` |
| run-webgl.py | `587c950e19a71652fdbe3afc69eb7f187c7b40e85f9ba849fc30dd92647a1fc7` |
| Baseline run/command.json | `340a35ffd0fe94a879d930361a50047878751c1ae0aea416b0612a68dcde4a58` |

Both complete232-file runtime sets were verified from the original source payloads,
then reverified after the probe: same file set, only libcef differs. Manifests and
page/host hashes: `webgl-inputs.json`, `webgl-{baseline,candidate}/inputs.sha256`.

All existing flags stayed byte-identical to the accepted corrected runner:

```
--in-process-gpu --disable-gpu --disable-gpu-compositing
--js-flags=--jitless
--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess
```

Existing first-run/background-network/component-update/domain-reliability/sync
controls, loopback-only resolution/direct proxy handling, Steam-client/browser
redirect overrides and Proton WineD3D option were retained. No unsafe-SwiftShader
flag was added. Browser284 START records all five switches. Renderers548/560
record jitless, disabled GPU compositing and both service feature flags; storage516
and metrics744 record the service features and generated
`--use-angle=swiftshader-webgl --use-gl=angle`. Those utility flags do **not**
override the canvas's measured public renderer identity.

## Control predicates and sole baseline

Candidate setup/runtime require the new baseline `control_pass`, which requires:
- Actual producer0, no timeout/survivors, native browser0 with original DOM/paint
  success and no native load-error/renderer-termination callbacks.
- All six markers independently present in document text, all five JS markers in
  native console, original five strip colors in final OSR output.
- Context created, both shaders compiled, program linked; initial/final GL error0,
  readback exactly red `[255,0,0,255]` and cyan `[0,255,255,255]`, no context loss
  or context/shader failure events.
- Final canvas OSR probes at(80,330)/(240,330) match red/cyan BGRA; WEBGL status
  probe at(620,330) is green.
- SwiftShader identity in the captured public `WEBGL_INFO` fields. A generic log
  warning mentioning SwiftShader cannot satisfy this backend predicate.

Offline `webgl-predicate-check.log` confirms that the old successful five-marker
run is rejected by the new predicate. Python runner and JS syntax checks pass.

Normal prefix setup used builtin `cmd.exe /d /c exit 0`, separate180s bound:
producer **1088770**, actual exit **0**, wall3.040s including waits,1202 DLL/EXE
symlinks checked/0 dangling, canonical prefix empty before/after, no signals.
The sole baseline runtime had a **30 s bound**; producer **1088889**, trace filter
**1088888**, native browser Windows PID284/Linux1088959. Native close at22003ms,
browser exit **0** at22024ms; actual producer/filter/wrapper exits **0/0/0**,
no timeout/signals/survivors. Wrapper wall32.451s includes cleanup waits, not
additional CEF runtime. Four children start/API-check; metrics744 explicitly
returns0. Other individual child exit codes remain unobserved, not inferred.

All native API14300 checks match `122bae6ae9a9961fb2fc27bd10aede159858f870`.
Local index/webgl.js/worker.js requests each return HTTP200; no load-error or
renderer-termination callback. Old sync/Promise/timer/worker console markers pass;
`WEBGL_PASS` console arrives374ms, all six independent DOM markers by1182ms.
Native browser summary: `code=0 dom=1 paints=5 errors=0 closed=1`.

### Positive checks, failed backend identity

Both shaders and link succeed with empty compiler/link logs. Initial/final GL
errors0; readPixels returns both exact expected RGBA tuples; contextLost=false;
no context creation/loss errors. Final OSR pixels match red/cyan plus green status
and the original marker strips. Inspected `webgl-baseline/paint-last.png` shows
all six markers and the fixed canvas colors. This is positive **hardware
ANGLE/RADV** execution evidence only.

Public GL values, including available debug extension:

```
vendor: WebKit
renderer: WebKit WebGL
version: WebGL 1.0 (OpenGL ES 2.0 Chromium)
unmaskedVendor: Google Inc. (AMD)
unmaskedRenderer: ANGLE (AMD, Vulkan 1.4.354 (AMD Radeon RX 9070 (RADV GFX1201) (0x00007550)), radv)
```

Thus `webgl_api_pass`, `webgl_events_clean`, `console_pass`, `dom_pass`,
`paint_pass`, `canvas_pass` are true, **swiftshader_confirmed=false** and
**control_pass=false**. Producer/native exit0 does not override the failed
software-backend condition. Candidate has staged payload only, no setup/profile,
run, console/DOM/paint, WebGL or allocation result from this probe.

Baseline final SHA-256:
- DOM: `4d493050d7aa08b604c4d2bbdebbd43cec2b2dc85a14f40b93226aabe2c60092`
- BGRA: `c4f62628f42eb45bce2f738312af8c24811f13c910d4ba91c909485421feb134`
- PPM: `39165f56690c725c8f242bdb683ce3dde307bf1b97efb4a01fdfbf9cc1682bac`

### Warnings and successful reservation accounting

Baseline logs contain the same automatic-software-WebGL deprecation warning and
ReadPixels stall messages identified in the preserved SC candidate evidence,
yet this baseline's shaders/readback/DOM/paint complete. The warning alone is
not a failure discriminator and was not used to override public backend identity.
No explanation for that identity/warning combination was established or pursued.
No candidate-warning comparison is possible because candidate did not run.

Baseline `+virtual` trace: three successful512MiB VIEWs (lines461/472/482), three
NOVIEW hints excluded, one explicit MEM_RELEASE (line483). Peaks: renderer0224
(decimal548)=1, renderer0230(decimal560)=2. Two views/1GiB lack explicit release
records in the filtered trace until process teardown. This is successful
allocation/release bookkeeping, **not live final VA**, total footprint or isolate
inventory. No new candidate no-range measurement; do not substitute the previous
non-WebGL candidate result for an unperformed WebGL run.

## Final stop and evidence

Supervisor confirmed the backend-mismatch branch as an **invalid requested
software control** and prohibited candidate/new baseline/tuning. No further arm
was performed. SC visual failure remains unresolved, implementation unfinished,
patch0007/series/candidate record untouched/uncommitted; assembled out-stage-c
remains rejected. Further direction needs a parent/owner decision; there is no
automatic synthetic-loop recommendation or PLA-380/phone/packaging clearance.

Canonical prefix sets were empty before/after setup and runtime, no signals
needed; final scan of all diagnostic prefixes empty, loopback server stopped
and port18793 bind checked. `webgl-final-validation.json` records4717 preserved
paths unchanged,464 runtime copy hashes verified, candidate unrun, identical
flags, empty prefix set and closed server. Images remain in .work.

Raw evidence: `webgl-baseline/{setup,run}/{command.json,wine.log,result.json,
processes.json}`, `setup/dll-exe-symlinks.json`, `run/server.log`,
`payload/{host-*.log,chrome_debug.log,dom-last.txt,paint-last.bgra,paint-last.ppm}`,
`webgl-baseline/paint-last.png`, root `webgl-{baseline,baseline-setup}-wrapper.*`,
`webgl-inputs.json`, `webgl-prior-evidence.json`, `webgl-predicate-check.log`,
`analyze-webgl.py`, `webgl-analysis.{json,log}` and `webgl-final-validation.json`.
