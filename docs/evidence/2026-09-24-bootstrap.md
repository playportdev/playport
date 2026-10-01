# Bootstrap: first build from pins, ladder, G2 and Hollow Knight

**Date:** 2026-09-24. **Tree:** commit `9d88d78` ("Bootstrap Playport on
willfaust/Madeira"); this record's commit adds only this record, its files and
the `app/artifacts.tsv` that build wrote.
**Result:** `build/build-from-pins` built and verified an IPA from a clean run
directory in 8 minutes. On the phone, the ladder passes **6/6**, the three
unattended G2 probes pass, and Hollow Knight starts, loads its save and was
played with a DualShock 4.

Every patch in `patches/` names this record in its `Evidence:` trailer: these
gates ran on an IPA built with all 31 of them.

## 1. Pins and series

| Component | Commit |
| --- | --- |
| Madeira (`upstream/madeira`) | `5a82d392ecd9ba7b85dc0b30034f8205a05009cf` |
| wine `madeira-lgpl` | `e828644329967ec9d411b0025f6ca57ff9d04d85` |
| FEX `ios-port-2607` | `0f8edf8f6383ae8085e0ffac511c789cdae97514` |
| DXMT `ios-port` | `0cb976618700b0a5348879b943caffa0c2cd1432` |
| rpmalloc (FEX `External/rpmalloc`) | `1f271c0c3202663801a0aec32bdb57e5241d6a0e` |

`sources` checked that these equal Madeira's own gitlinks at `5a82d392`. The
series hashes the run recorded are in [`build/provenance.txt`](2026-09-24-bootstrap/build/provenance.txt).

## 2. Build

`build/build-from-pins` with no arguments, so the run directory was deleted
first and every tree is a fresh checkout of its pin plus its series.
Stage log: [`build/build-from-pins.log`](2026-09-24-bootstrap/build/build-from-pins.log);
inputs and their versions: [`build/inputs.txt`](2026-09-24-bootstrap/build/inputs.txt).

- **Time:** 14:04:41 to 14:12:34 on a 16-core workstation. The LLVM 15.0.7
  toolchain caches (`$PLAYPORT_BUILD/cache`) were warm; the earlier shakedown
  run built them in about 7 minutes.
- **IPA:** `Playport-26.5-72e2f1b3.ipa`, 655,295,453 bytes, sha256
  `72e2f1b384035276f28488a3cfad6f73cbd7e71a461c6df11a863e846beff213`.
  Bundle ID `dev.playport.app`, signed by the patched xtool with
  `increased-memory-limit`, linked with ld64-956.6.
- **verify-ipa:** 50 checks, 0 failures ([`build/verify.log`](2026-09-24-bootstrap/build/verify.log)):
  signature and profile, all 267 resource rows and 2 gaps, ladder 8/8 and G2
  5/5 guests, winemetal slot 139 on both PE arches, the bundled DXMT DLLs
  byte-identical to the patched build, the host I/O pieces and the Steam
  client's Apple seams.
- **Wine PE:** only the four `ntoskrnl.exe` test drivers fail, as expected.
  Both PE manifests were byte-identical to the previous run at the same
  build root.
- **Reproducibility between two runs at the same root:** every artifact row
  matched except `xtajit64.dll` (FEX embeds its build time) and the seven
  DXMT PE DLLs (`d3d11`, `dxgi`, `winemetal` for both arches, arm64ec
  `d3d10core`). The DXMT PE build is not byte-reproducible yet; the unix
  slice (`libdxmt_combined.a`) is. That is an open item.
- The unix-side link test reports the known four duplicate symbols under lld
  for the base `libwineserver.a` and links cleanly with the renamed variant;
  the app itself links with ld64.

## 3. Device

iPhone Air (`iPhone18,4`, A19 Pro), iOS 27.0, over netmuxd Wi-Fi, free
developer team (three app slots). Installing the new bundle ID needed a free
slot. The previous app in that slot (the retired predecessor installation,
holding a Hollow Knight copy and a save) was uninstalled on the operator's
decision, after its save files, `AppConfig.ini`, registry hives and FEX per-app
config were pulled read-only to a local backup. `port22` and `port22.dev`
were not touched. The IPA was then installed and later upgraded in place;
the container was never wiped after that.

## 4. G1 ladder: pass, 6/6

`harness/ladder/tools/ladder.py run --backend ios --pool-mb 896`, idevice-tools
v0.1.68 built from `harness/g0/tools/idevice-tools-v0.1.68-bless.diff`.
Files: [`ladder/`](2026-09-24-bootstrap/ladder/).

| Rung | Steps | Verdict |
| --- | --- | --- |
| cpu-jit | 1 | pass |
| win32-core | 1 | pass |
| concurrency | 1 | pass |
| process-model | 1 (named pipes included) | pass |
| persistence | 4 | pass |
| resource-envelope | 2 | pass |

Backend `madeira:fex-0f8edf8f6+wine-e82864432+madeira-5a82d392e`. Resource
envelope: cold start 5.614 s (0.23 s excluding JIT activation), peak RSS
1,235 MB, steady 1,230.4 MB, minimum available memory 6,956 MB, storage
amplification 1.045, main-thread maximum stall 0.1 ms. No `madeira.cfg`, so
in-process sync was off (the default, `patches/madeira-unix` 0014).

## 5. G2 probes: the three unattended probes pass

`harness/g2/tools/g2.py run --backend ios --pool-mb 896 --steps
g2-graphics/1,g2-audio/1,g2-input/1`. Files: [`g2/`](2026-09-24-bootstrap/g2/).

| Step | Verdict | Main-thread max stall |
| --- | --- | --- |
| g2-graphics/1 (D3D11) | pass | 0.6 ms |
| g2-audio/1 | pass | 0.4 ms |
| g2-input/1 | pass | 0 ms |
| g2-session/1, g2-pad/1 | not tested: they need a person at the phone | — |

G2 as a whole therefore still has no verdict (the tool exits 1 for that
reason).

## 6. Hollow Knight

**Staging.** `harness/titles/stage-title.py push` sent the owned copy
(1,785 files, 5,231,995,691 bytes) in 135 s; `check --sample 8` read it back:
`1785 listed, 0 bad, 0 unlisted`. After the ladder had created the prefix,
`place` moved it to `C:\Games\Hollow Knight`, and the backed-up save files,
`AppConfig.ini` and the FEX per-app config (`{"Config": {"SMCChecks": "full"}}`)
were pushed back.

**Launch.** `harness/device/title-device-run.py --pool-mb 896
'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'`.
Key lines: [`hollow-knight/s1-host-key-lines.txt`](2026-09-24-bootstrap/hollow-knight/s1-host-key-lines.txt),
[`hollow-knight/player-key-lines.txt`](2026-09-24-bootstrap/hollow-knight/player-key-lines.txt).

- The JIT pool was placed inside the executable's reservation; activation
  5.76 s; `wine_host_run_exe -> 0`. Unity 6000.0.61f1 came up on
  `Apple A19 Pro GPU` under Direct3D 11.0, borderless at the panel's native
  2736x1260, guest monitor 120 Hz.
- `WINEDLLOVERRIDES` carried `windows.gaming.input=d`, and Unity logged
  `Windows.Gaming.Input failed to initialize (Might not be available),
  fallback to XInput` / `Using XInput`.
- It loaded the restored save (`Loaded saved language code 'EN'`), and the
  captain played King's Pass on the DualShock 4: pad state reached the guest's
  XInput DLL (`hostio: input pad0 …`), and the screen showed the Knight in
  King's Pass with the Metal HUD at about 55 fps, GPU 13.1 ms, Game Mode on
  (screen-kings-pass.jpg (screenshot not published)).

**Finding: a pad connected after the game starts is not picked up.** In the
first launch the DualShock connected after Unity had loaded XInput. The host
published every press and the XInput DLL returned them, but the game stayed on
its first-run language menu. The captain reported it as "the gamepad doesn't
work". After a relaunch with the pad already connected, the pad drove the game
from the start. The app, the XInput DLL and the overrides are the same in
both launches, so this is Unity not rescanning for a controller that appears
after its input initialisation, not a fault in this build. Until the app
handles it, connect the controller before launching a title.

An exception from `JsonSharedData.Save` is still logged at start-up (Unity's
persistent-data path is empty in this prefix); the game carries on and the
save loads.

## 7. Open items

- Controller hot-plug after a title has started (§6).
- DXMT PE DLLs are not byte-reproducible between runs (§2).
- `g2-session/1` and `g2-pad/1` need a person at the phone.
- `tools/upstream-sync` is a stub; the full tool is the next task.
- No patch has been offered upstream yet (`Offered-upstream: no` throughout).
