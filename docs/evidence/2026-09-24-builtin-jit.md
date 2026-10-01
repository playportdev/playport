# Built-in JIT: Playport's own helper extension, with StikJIT, built and signed on Linux

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-24. **Tree:** the commit that adds `app/Sources/PlayportJIT`
and `build/stage-stikjit.sh`; this record's commit adds only this record and docs.
**Result:** on the phone, Playport's own helper extension enabled JIT for a
Hollow Knight launch with **no second app, no app switch and no tap**. It
attached, blessed the 896 MiB pool in 1.49 s and detached. The acquire took
3.20 s in all, against 10.93 s with StikDebug by URL. The title reached its
menu at about 57 FPS. The launch was driven from the workstation
(`title-device-run.py --jit builtIn`, which gives the app the Home Screen method
and runs no debugger of its own), because nobody could tap the phone during the
session. The literal Home Screen tap sequence is the one step still unrun (§4).
The built-in path now runs Playport's own GPL-3.0-or-later protocol script,
`app/PlayportJIT/playport-universal.js`, and was re-verified on the device
with it: acquire 3.27 s, the title at its menu (§5). A fresh live round on
the build of `c649395` (the current script) passed again (§6). The current
HEAD's own flow, tap Playport then tap a title in the product UI, ran on a
build of `d3a076e` with the built-in helper and no app switch (§7).

**Note, added later:** this run used StikJIT's bundled `universal.js`. The
bundled scripts were then removed from the staged framework and replaced by
Playport's own `app/PlayportJIT/playport-universal.js` (docs/LICENSING.md,
"StikJIT"); the device re-run with that script is recorded in §5.

## 1. The build spike: can xtool on Linux build and sign the extension?

The open question from the scout (the extension route "not proven on our
Linux toolchain") is settled: **yes**, with three packaging fixes. The spike was a
throwaway package (a host app, one extension product, the StikJIT
`binaryTarget`) built with the pinned, patched xtool 1.20.1 and ld64, first
unsigned, then `--sign --ipa` under the final identifiers
(`dev.playport.app` and `dev.playport.app.PlayportJIT`),
so it registered only the one App ID the real app uses.

| Step | What happened | Fix, now in the tree |
| --- | --- | --- |
| Fetch `StikJIT.xcframework.zip` (StikJIT 1.6.0 release asset, 1,706,550 B, sha256 `14990ce6…b716f215`) | one `ios-arm64` slice: a dynamic `StikJIT.framework` (arm64 `MH_DYLIB`, install name `@rpath/StikJIT.framework/StikJIT`, minos 17.4, sdk 18.5), swiftinterface only, `universal.js`/`legacy.js` as resources, **no `Info.plist`** | — |
| Unsigned `xtool dev build` | the host Swift 6.4 compiler cannot build the module from its interface: `'DDIPaths' is not a member type of enum 'StikJIT.StikJIT'`. The module and its public enum are both `StikJIT`, so every `StikJIT.X` in the interface resolves to the enum | `build/stage-stikjit.sh` drops the module qualifiers (`StikJIT.StikJIT.` to `StikJIT.`, `StikJIT.DDIPaths` to `DDIPaths`, …); each name still resolves to the same declaration. The unsigned build then succeeds and xtool puts the framework in `PlugIns/<ext>.appex/Frameworks/` |
| `--sign --ipa` | zsign: `Can't find free space of LoadCommands for CodeSignature!`. The extension's executable had **no `__text`**: xtool links the extension product from an archive with `-e _NSExtensionMain` (Foundation), nothing references the principal class by symbol, and the linker dropped it | the extension target links with `-ObjC`, and `PlayportJITEntry/entry.c` defines `NSExtensionMain` in the executable (the entry point now names it) |
| `--sign --ipa` again | signed; the extension got **its own App ID and profile** (`XTL-TEAMIDXXXX.dev.playport.app.PlayportJIT`, same device, same expiry as the app's), but **the framework was left unsigned**: zsign signs a nested bundle only if it has an `Info.plist` | `build/stage-stikjit.sh` writes the framework's `Info.plist` (StikJIT's own `project.yml` values: `com.stik.StikJIT`, `FMWK`). The framework is then signed (`LC_CODE_SIGNATURE`, `_CodeSignature/CodeResources`) |

The fallbacks the brief named (our own companion app, or staying on the
StikDebug URL path) were not needed.

## 2. The real build

- **IPA:** `Playport-26.5-f62ffacb.ipa`, sha256
  `f62ffacb9277a78aa9c9042bddfc8f3fbecf23a69b0c4cbd9acc1e63e30ed3f4`, built by
  `build/build-from-pins --from stage` (earlier stages from the shared
  `run/` trees at this tree's pins and series; `app/artifacts.tsv` unchanged).
  verify-ipa: 58 checks, 0 failures, including the new `jit-helper` group:
  the extension's plist (`com.apple.ar.viewer`, `FALSEPREDICATE`,
  `PlayportJITHelper`), its code and links, the embedded StikJIT binary equal
  to the release's past its load commands, both code directories, and the
  extension's own profile.
- The device run below used this IPA, built before the branch was rebased
  onto the merged StikDebug work (#3), which added the return to the title
  list after a launch ends. The rebased tree builds to
  `Playport-26.5-95643378.ipa` (sha256
  `956433784e19580ec4ea7ed71e6549afa00921b248f1611d971a6b939eb9aa0c`),
  verify-ipa 58 checks, 0 failures; it was not run on the phone.
- Layout: `S1Probe.app/PlugIns/PlayportJIT.appex/{PlayportJIT, Info.plist,
  embedded.mobileprovision, _CodeSignature, Frameworks/StikJIT.framework}`.
- The extension uses one more free-team App ID (ten per seven days); it
  takes no device slot.

## 3. On the phone

- **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi,
  Developer Mode on, under `flock $PLAYPORT_BUILD/device.lock`. LocalDevVPN
  1.3.0 was installed and its tunnel was up (`utun4`). No person touched the
  phone: the captain could not tap or unlock it during the session.
- **Install:** `pymobiledevice3 apps install` over the existing Playport
  (in-place upgrade; prefix and staged Hollow Knight kept). installd accepted
  the extension and its separate profile with no error.
- **Pairing file:** the RP pairing file from the StikDebug record (501 bytes,
  made by `idevice-tools rppairing pair`) written to
  `Documents/StikJIT/pairingFile.plist` by `harness/device/push-pairing-file.py`
  and read back identical. StikJIT accepted it unchanged.

### 3.1 Readiness check (a plain launch, no launch mode)

`dvt launch` with no environment shows the probe screen, whose JIT section
runs the readiness check once. `readiness-syslog-milestones.txt` and
`readiness-s1-host-lines.txt` hold the lines below.

| Time (phone) | What happened |
| --- | --- |
| 18:19:18.24 | Playport (pid 1315) queries PlugInKit for `…playport.PlayportJIT`: one match, under `com.apple.ar.viewer` |
| 18:19:18.25 | synchronous `beginExtensionRequest`; runningboardd launches the extension as an `xpcservice` of pid 1315 (pid 1316) |
| 18:19:18.43 | the helper builds `PlayportJITHelper`, decodes the request **with the listener endpoint** (the `entry.c` class-check change works), connects back; `prepareWithPairingFile:reply:` arrives over XPC |
| 18:19:18.43 | StikJIT's reachability connects to `10.7.0.1:49152` over `utun4`, then the RSD/DDI check |
| 18:19:18.47 | `ready, TXM present`; the DDI was already mounted this boot. The app ends the helper (`_kill:`) |

### 3.2 Hollow Knight with built-in JIT

```sh
python3 harness/device/title-device-run.py --pool-mb 896 --jit builtIn --title-wait 90 \
    'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'
```

The key lines are in `title-s1-host-lines.txt`.
Offsets are from the acquire's start.

| Offset | What happened |
| --- | --- |
| 0 | `asking the built-in helper to attach to pid 1320`; the helper (pid 1321) connects, `enableJIT pid 1320`; tunnel and DDI checked, `device ready` |
| +0.36 s | `app active`: the launch's own activation. **The only transition line of the launch**: no `resign active`, no `background`, no `foreground` |
| ≈+1.7 s | the helper runs `universal` against pid 1320; Playport sees `CS_DEBUGGED`, frees the pool range and issues `brk` x16=1 |
| +3.2 s | `prepare(NULL, 0x38000000) -> 0x119000000 in 1.49 s` (**57,344 pages blessed**), RW alias, `brk` x16=0, **debugger detached**, `JIT script finished (region blessed, detached)` |
| 3.20 s | `acquire(896 MiB) via builtIn -> 0`; `built-in helper finished`; `wine_host_init -> 0`, `wine_host_run_exe -> 0` |
| +90 s | `title: done … running after_s=90`; FEX still translating at +100 s (325 translation summaries) |



Compared with the StikDebug URL path on the same phone, pool and title
([record](2026-09-24-stikdebug-url.md)): 3.20 s against 10.93 s from the
request to a blessed and detached pool. The bless itself went from 4.11 s to
1.49 s, because the helper runs on the phone and not over Wi-Fi. There is no
StikDebug flash, no app switch and no "Enable JIT?" prompt.

## 4. What this does and does not show

- **Shown on the device:**
  - the whole built-in chain: extension discovery, the private NSExtension
    start, the XPC endpoint hand-off, StikJIT's tunnel and DDI checks, the
    attach, the universal protocol, the detach, and the title running;
  - with the phone untouched (Playport was in front for the launch);
  - with StikDebug installed but never opened or asked.
- **Not run: the literal Home Screen sequence** (tap Playport, tap a title).
  That path is `TitleMode.start(exe:)` from the probe screen's list. It calls
  the same `JitProvider.acquire` with the same `builtIn` vehicle (the Home
  Screen default) and the same helper. The driven launch differs only in
  where the title name comes from (`TITLE_EXE`) and in using `S1_JIT` to pick
  the vehicle. One attended check remains before phase 2 can be called done
  on the captain's terms: tap Playport, then Hollow Knight, and confirm there
  is no switch and no prompt.
- **Not exercised:**
  - a DDI download and mount (the image was already mounted this boot);
  - the document-picker import (the file was pushed from the workstation);
  - "Reset Developer Disk Image".
- **StikDebug can come off the phone** now that the built-in path works; that
  frees a free-team slot. Nothing was uninstalled here: that is the captain's
  call.
- **The accepted risk stays.** The extension point is borrowed and the
  NSExtension methods are private; an iOS update can break either.

## 5. Re-run with Playport's own script

- **IPA:** built from head `a9ea18c` (the fix round that added
  `app/PlayportJIT/playport-universal.js`) by `build/build-from-pins --from stage`
  in a lane build area whose earlier stages were the pre-#5 shared run trees,
  so it links the previous DXMT (the phone's installed build already had it).
  Playport-26.5 IPA sha256
  `87da1de22d7f9c051f2d08b3f1b3101db5d0dc0079698e4c979e6c66c1979c45`.
  `verify-ipa`: every jit-helper check passed, including "the extension's
  playport-universal.js is the committed app/PlayportJIT/playport-universal.js"
  and "the StikJIT framework carries none of StikJIT's scripts". Its only
  failure was the DXMT unix-table slot check, because of those older DXMT
  trees (unrelated to this change). This IPA was not shipped.
- **Phone:** iPhone18,4, iOS 27.0, netmuxd Wi-Fi, under `flock device.lock`,
  installed in place, the pairing file already in `Documents/StikJIT`, no one
  touching the phone.
- **Run:**

  ```sh
  python3 harness/device/title-device-run.py --pool-mb 896 --jit builtIn --title-wait 60 \
      'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'
  ```

- **Result:** pass. In `s1-host.log`: `jit: helper: Running
  playport-universal.js against pid 1363`, `attached to pid 1363`,
  `prepare(NULL, 0x38000000) -> 0x119000000 in 1.62 s`, `Blessed 57344 JIT
  page(s) at 0x119000000`, `prepared 0x119000000 (57344 pages)`, `debugger
  detached`, `detached after 1 prepare(s)`, `acquire(896 MiB) via builtIn -> 0
  after 3.27 s` (3.20 s with StikJIT's script in §3.2), `wine_host_init -> 0`,
  `wine_host_run_exe -> 0`, and `title: done ... running after_s=60`. There is
  no `resign active`, `background` or `foreground` line: the only transition
  was the launch's own `app active at +0.29 s`. FEX was still translating
  (353 translation summaries). Hollow Knight's menu ran at about 120 FPS in
  the Metal HUD.

The key lines are in `own-script-title-s1-host-lines.txt`.



## 6. Fresh live round on c649395

§3 and §5 ran earlier builds: §3 StikJIT's own script, §5 the build of
`a9ea18c`. `c649395` then changed `playport-universal.js` (an `E..` reply to
`_M` is now an error), so this round was run fresh on a build of that commit.
No earlier evidence is reused.

- **Build:** Playport-26.5 from `c649395`, built by `build/build-from-pins
  --from stage` against trees at the current pins; IPA sha256
  `5ceb7fac02647fe7398cef0212bb6d9181cdf283cc4d7929c89813e13ab963f7`,
  `verify-ipa` 60/60. The phone is shared with other lanes and the installed
  bundle cannot be read back, so this IPA was installed in place again at the
  start of the round (2026-09-25 00:30:33 CEST, `pymobiledevice3 apps install`,
  "Installation succeed"). Every scenario below ran after that, within 6
  minutes, each under `flock $PLAYPORT_BUILD/device.lock`.
- **Phone:** iPhone18,4, iOS 27.0, netmuxd Wi-Fi, the pairing file already in
  `Documents/StikJIT`, LocalDevVPN connected, no one touching the phone.

| # | Scenario | How | Verdict |
|---|---|---|---|
| 1 | Built-in Hollow Knight launch | live | **pass** |
| 2 | The script's protocol handling | live (scenario 1's lines) | **pass** |
| 3a | App killed while the helper runs the script, then a next launch | live | **pass** |
| 3b | Failures a real debugserver cannot be made to produce | **simulated** | **pass** |
| 4 | The IPA's contents | inspection of the installed IPA file | **pass** |
| 5 | Readiness check on a plain launch | live | **pass**; the cancelled-by-a-title path **not driven** |

### 6.1 Built-in Hollow Knight launch (live)

```sh
python3 harness/device/title-device-run.py --pool-mb 896 --jit builtIn --title-wait 60 \
    'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'
```

The pulled `s1-host.log`, from this launch's nonce (`5569ed3d`) on, abridged
(timestamps dropped):

```text
jit: asking the built-in helper to attach to pid 3063
jit: app active at +0.12 s (debugger not attached)
jit: helper started, pid 3064
jit: helper: Running playport-universal.js against pid 3063…
jit: helper: attached to pid 3063
[wine_host] JIT pool: 1 low pins; prepare(NULL, 0x38000000) -> 0x119000000 in 1.61 s
jit: helper: Blessed 57344 JIT page(s) at 0x119000000
jit: helper: prepared 0x119000000 (57344 pages)
[wine_host] JIT pool: rx=0x119000000 rw=0x7000000000 size=0x38000000; debugger detached
jit: helper: detached after 1 prepare(s)
jit: acquire(896 MiB) via builtIn -> 0 after 3.35 s
title: runtime: pool 896 MiB; wine_host_init -> 0, activation 3.35 s
title: wine_host_run_exe -> 0
title: done nonce=5569ed3d running after_s=60 (TITLE_WAIT_S reached)
```

The helper ran Playport's script, the pool was blessed and detached,
`acquire -> 0`, `wine_host_run_exe -> 0`, and the title was still running at
the 60 s cutoff (`title-device-run.py`'s exit status 1 means only that the
title had not exited). The
launch has no `resign active`, `background` or `foreground` line; its only
transition is the launch's own `app active at +0.12 s`. The screenshot was
taken 45 s into the run: the menu at about 120 FPS in the Metal HUD. Key
lines: `fresh-title-s1-host-lines.txt`.



### 6.2 Protocol handling (live, from 6.1)

`attached to pid 3063`, one prepare with a NULL address answered by
debugserver's allocation at `0x119000000`, `Blessed 57344 JIT page(s)` (896 MiB
of 16 KiB pages) and `prepared 0x119000000 (57344 pages)`, the app's
`prepare(NULL, 0x38000000) -> 0x119000000` (the address came back in x0), then
`detached after 1 prepare(s)` and the app's `debugger detached`: the whole
universal protocol, served by the committed script.

### 6.3 Failure handling

**Live: the app killed while the helper runs the script.** A driven launch
(`dvt launch` with `S1_MODE=title`, `S1_JIT=builtIn`, nonce `5eed0003`), then
`pymobiledevice3 developer dvt kill` of the app 0.8 s after the launch
returned; the kill completed at 00:32:57.82. The app's last lines
(`fresh-kill-s1-host-lines.txt`):

```text
jit: helper started, pid 3078
jit: helper: prepare: device ready
jit: helper: Running playport-universal.js against pid 3077…
```

The syslog (`fresh-kill-syslog-milestones.txt`)
shows the helper's connection to the app invalidated at 00:32:57.828, its
extension context torn down at .828, and SpringBoard flagging the helper as
exiting at .857: the helper went 30 ms after the app, with no hang. A process
list 60 s later has neither process. The script's own failure message could
not be observed: the helper is ended together with the app that started it,
and its `NSLog` text is `<private>` in the syslog. The next launch (nonce
`15fd7571`, the same command as 6.1 with `--title-wait 30`) worked: `Running
playport-universal.js against pid 3081`, `prepared 0x119000000 (57344 pages)`,
`detached after 1 prepare(s)`, `acquire(896 MiB) via builtIn -> 0 after
3.08 s`, `wine_host_run_exe -> 0`, still running at the 30 s cutoff.

**Simulated, not live.** A real debugserver cannot be made to send a non-brk
stop, an unknown call, an address at or above 2^53, an empty reply, an `E..`
reply to `_M`, or endless stops. These ran the committed script under node's
`vm` against a simulated StikJIT host API (`get_pid`, `send_command`,
`prepare_memory_region`, `log`). Every case threw a specific
`playport-universal:` error and stayed bounded: `vAttach` `E96`, target exit
`W09` and `X09`, a stop that is not `brk #0xf00d`, `x16=0x5`, an address
`0x20000000000000`, `_M` answered with `E01`, empty replies to `P` and `D`,
and "no detach after 256 stops" (1025 packets). The happy path completed.
The same `E01` case against the script at `335f7ad` "completed" with a region
at `0xe01`, which is the defect `c649395` fixed. Output:
`fresh-simulated-script-cases.txt`.

### 6.4 The installed IPA's contents (inspection)

The IPA above, unpacked: `PlugIns/PlayportJIT.appex/playport-universal.js`
is byte-identical to the committed `app/PlayportJIT/playport-universal.js` at
`c649395` (sha256 `cb463b9b…ae19ad27d2b5c5` for both). It is the only `.js`
file under `PlugIns/`: `PlugIns/PlayportJIT.appex/Frameworks/StikJIT.framework`
holds `_CodeSignature`, `Headers`, `Info.plist`, `Modules` and the `StikJIT`
binary, with no `universal.js` or `legacy.js`.

### 6.5 Readiness check on a plain launch (live)

This ran on the `c649395` build, before the product UI from #8, where a plain
launch showed the probe screen. At HEAD a plain launch shows the product UI
(`PlayportTabs`), which starts the readiness check, and the probe screen
appears only under `S1_MODE=probe` (§7).

`pymobiledevice3 developer dvt launch <bundle>` with no environment showed
that build's probe screen, which ran its readiness check once:

```text
jit: helper: helper pid 3093 connected
jit: helper: prepare: checking the tunnel
jit: helper: prepare: checking the DDI mount
jit: helper: prepare: device ready
jit: helper: ready, TXM present
```

The JIT section showed Method Built-in, Pairing file imported and Readiness
`ready (TXM present)` 25 s after the launch. The launch before it had left
Hollow Knight running; `dvt launch` replaced that process. Its last writes
overlap the new process's first ones. The readiness path's `helper started`
line is missing from the file, most likely overwritten by those writes; the
five lines above are intact. Key lines:
`fresh-readiness-s1-host-lines.txt`.



**Not driven: a readiness check cancelled by a title's enable.** That needs a
title started while the readiness check runs, which is a tap (on that build,
in the probe screen's list; at HEAD, Play in the product UI), and no one
could tap the phone. A driven title launch (`S1_MODE=title`) shows neither
screen, so it never starts a check to cancel. By reading the code:
`BuiltInJit.prepare` reports a `.cancelled` helper call as `not checked` with
no detail, and `BuiltInJitStatus.check` then clears `checkedThisLaunch`, so
the next time the screen that starts the check appears (at HEAD,
`PlayportTabs`), its check runs again.

## 7. The product UI flow on HEAD (d3a076e)

§6 ran on a build from before the rebase, without the product UI from #8. At
HEAD a Home Screen launch shows the product UI (`PlayportTabs`), which starts
the readiness check; the JIT controls are in Settings; and a library title's
Play goes through `TitleLaunch.start` with the built-in vehicle. This run
covers that flow. It was driven by the lane operator, not in the review step.

- **Build:** this run's head `d3a076e`, built by `build/build-from-pins --from
  stage` in a lane build area whose earlier stages are the p1 lane's post-#6
  FEX and post-#5 DXMT trees. IPA sha256
  `b0c17ec84b1f52a4d8e160abf4bc0573458c590def134718ed4807e98e90e183`,
  `verify-ipa` 60/60. The stage step rewrote eight `artifacts.tsv` rows (the
  DXMT PE DLLs and `xtajit64.dll`), whose hashes depend on the build root
  (AGENTS.md); the committed `artifacts.tsv` is unchanged.
- **Phone:** iPhone18,4, iOS 27.0. Installed in place at 00:59:25 CEST on
  2026-09-25 under `flock $PLAYPORT_BUILD/device.lock`, with the pairing
  file pushed and read back identical. No one touched the phone.

### 7.1 Run A: a plain launch (live)

A launch with no environment, the shape of a Home Screen launch (00:59:27,
pid 3158). The product UI's Installed tab showed Hollow Knight as Ready. The
readiness check, started from `PlayportTabs`, logged `jit: helper started`,
then:

```text
jit: helper: prepare: checking the tunnel
jit: helper: prepare: checking the DDI mount
jit: helper: prepare: device ready
jit: helper: ready, TXM present
```

Key lines: `product-ui-plain-launch-jit-lines.txt`.



### 7.2 Run B: the product UI's Play, driven with no tap (live)

`dvt launch` with `S1_MODE=ui UI_ACTIONS=play:app-367520 TITLE_WAIT_S=60
S1_JIT=builtIn MTL_HUD_ENABLED=1` (01:00:10, pid 3163). `UIDriver.swift`
makes the same `LibraryModel.play` call as the Play button. No workstation
debugger ran. From `s1-host.log`:

```text
ui: library: app-367520 Hollow Knight [Ready]
title: in-app start Games\Hollow Knight\hollow_knight.exe -logFile C:\hollow_knight-player.log (JIT via builtIn)
ui: play app-367520: started
jit: helper: Running playport-universal.js against pid 3163…
jit: helper: attached to pid 3163
[wine_host] JIT pool: 1 low pins; prepare(NULL, 0x38000000) -> 0x119000000 in 1.53 s
jit: helper: Blessed 57344 JIT page(s) at 0x119000000
jit: helper: detached after 1 prepare(s)
jit: acquire(896 MiB) via builtIn -> 0 after 3.06 s
title: runtime: pool 896 MiB; wine_host_init -> 0, activation 3.07 s
title: wine_host_run_exe -> 0
```

`title-result.log`: `title: done nonce=794ad103 running after_s=60
(TITLE_WAIT_S reached)`. There is no `resign active`, `background` or
`foreground` line: the app never left the screen. FEX was still translating
(329 translation summaries). The screenshot 50 s in shows Hollow Knight's
menu at 119.96 FPS, with the HUD naming the current DXMT build. Key lines:
`product-ui-play-s1-host-lines.txt`.



**Not done: the literal finger taps.** A tap on the title and then on Play
reaches the same `LibraryModel.play` call; `UIDriver` reaches it without a
tap.
