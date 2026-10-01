# On-device JIT through StikDebug: a Home Screen launch runs a title with no workstation

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-24. **Tree:** the commit that adds `app/Sources/S1Probe/JitProvider.swift`;
this record's commit adds only this record, its files and the docs.
**Result:** a Home Screen tap on Playport, then a tap on Hollow Knight, opened
StikDebug by URL. StikDebug showed its "Enable JIT?" confirmation, and the
captain tapped it: one manual tap inside StikDebug, besides the taps on Playport
and the title. After that tap StikDebug brought Playport back to the front by
itself, attached, blessed the 896 MiB pool in 4.11 s and detached. Hollow Knight
started and was played. The workstation drove nothing. It only installed the apps, made the
pairing file and recorded logs. The workstation debugger path still passes on the
same build. A second, cold run after a reboot, with no DDI mounted (§4), showed
that StikDebug mounts the DDI itself inside its step. That run took 9.84 s from
the tap to guest code, including the mount and the "Enable JIT?" tap, and Hollow
Knight ran. In both runs the LocalDevVPN tunnel was started by hand in Settings,
so whether its on-demand rule starts the tunnel by itself is still unverified.

## 1. Build and device

- **IPA:** `Playport-26.5-9299943f.ipa`, sha256
  `9299943feae3f668bcc65add74f7a130daace35fe99856281b12676064faf5df`, built by
  `build/build-from-pins --from app`. The unchanged earlier stages come from the
  run in [the bootstrap record](2026-09-24-bootstrap.md). verify-ipa: 50 checks, 0 failures.
  Installed over the existing Playport (in-place upgrade), so the prefix and the
  staged Hollow Knight were kept.
- The tested IPA predates the later change that returns a failed or ended in-app
  launch to the title list with its outcome. That path was never exercised on the
  device (§6); the JIT and launch path measured here is unchanged by it.
- **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0 (lockdown `BuildVersion` 24A437),
  free developer team, over netmuxd Wi-Fi. Developer Mode on.
- **StikDebug:** the upstream release `StikDebug-3.1.11.ipa` (13,515,131 bytes,
  sha256 `e3f9b6553f143c0a9f130ab459f7e83bd7d95b8ce8fc816a890ddbbe63bf2ff0`), re-signed
  and installed by `xtool install` as `XTL-TEAMIDXXXX.com.stik.stikdebug`. xtool
  signed it with no errors, even though the app asks for an App Group, which a free team cannot have.
  StikDebug uses the group only for app icons and script favourites.
- **LocalDevVPN:** 1.3.0 from the App Store, already installed.
- **Slots:** all three free-team slots were in use (Playport, Port22, Port22-dev).
  Port22-dev was uninstalled on the operator's decision to make room for StikDebug.
  Its container is gone. Port22 and Playport were not touched.

## 2. Pairing file

`idevice-tools rppairing pair <hostname> <file>`, from jkcoxson/idevice `d32c818`
(the `idevice-tools` binary built from `tools/`), ran over the netmuxd Wi-Fi
connection through a local socat bridge. It went CoreDeviceProxy, then RSD
(85 services), then the untrusted tunnel service, then RPPairing, and printed
`Paired!` with **no Trust prompt on the phone**. The file is an idevice
`RpPairingFile` plist: `public_key`, `private_key`, `identifier` and `alt_irk`,
501 bytes. It is a secret and stays out of the repository.

**Import:** `pymobiledevice3 apps push XTL-<team>.com.stik.stikdebug <file>
Documents/pairingFile.plist`. StikDebug sets `UIFileSharingEnabled`, and
`PairingFileStore.prepareURL` adopts a `Documents/pairingFile.plist` at startup.
Pulled back, the file was byte-identical. StikDebug then used it
**unchanged**: the tunnel and the JIT below ran on it. No tap is needed on the
phone, and no document picker is needed in Playport, because the workstation that
makes the file can also place it.

## 3. The attended run

The captain ran it. Times are the phone's clock and are taken from
`syslog-milestones.txt` and
`s1-host-key-lines.txt`.
Offsets are from the moment Playport opened the URL: `t0` ≈ 15:13:47.6, back-computed from the
10.93 s total that the acquire line logs at 15:13:58.56.

| Time | Offset | What happened |
| --- | --- | --- |
| 15:13:14.6 | | StikDebug opened by hand (setup step: VPN and DDI check) |
| 15:13:28.5 | | LocalDevVPN tunnel started **from Settings** (`start command from Preferences`) |
| 15:13:44.9 | | Playport launched from the Home Screen (pid 14154), no launch environment |
| ≈15:13:47.6 | 0 | the captain tapped `Games\Hollow Knight\hollow_knight.exe`; Playport opened `stikdebug://enable-jit?bundle-id=XTL-TEAMIDXXXX.dev.playport.app&pid=14154&script-name=universal.js` |
| 15:13:48.08 | +0.45 | SpringBoard allowed the open (`allowed=1`), with no system "Open in…?" prompt |
| 15:13:48.13 | +0.5 | **a new StikDebug process** (pid 14155): the captain had swiped it away, so the URL started it cold; it showed "Enable JIT?" and the captain tapped to confirm |
| | +1.23 | Playport in the background |
| 15:13:53.0 | +5.37 | after that tap, **Playport back in front without another tap** (`willEnterForeground`), before any attach |
| 15:13:54.34 | +6.7 | Playport sees `CS_DEBUGGED`; it frees the pool range and issues `brk` x16=1 |
| 15:13:58.44 | +10.8 | `prepare(NULL, 0x38000000) -> 0x119000000 in 4.11 s`, inside the reservation |
| 15:13:58.56 | +10.93 | RW alias, `brk` x16=0, **debugger detached**; `acquire(896 MiB) via stikDebug -> 0` |
| 15:13:58.66 | | `wine_host_init -> 0`, `__wine_main C:\Games\Hollow Knight\hollow_knight.exe`, `wine_host_run_exe -> 0` |

The captain's report: "Everything worked, the game came back automatically."
He reported afterwards that he had to tap StikDebug's "Enable JIT?" confirmation
before StikDebug returned him to Playport; "automatically" is the return after that tap.
Hollow Knight loaded and ran. DXMT's command stream was still advancing when
the log was pulled at 15:15.

### Answers to the scout's device-only questions

1. **StikDebug 3.1.11 on iPhone18,4 / iOS 27.0: JIT works, and so does its DDI
   mount.** In this run the mount was not exercised: one personalized Developer
   Disk Image (`27A5228h`) was already mounted at `/System/Developer`, most likely
   by the workstation's pymobiledevice3 during earlier `dvt` work this boot. The
   cold run after a reboot (§4) started with no image mounted, and StikDebug
   mounted the cryptex DDI itself, about 3.2 s after the URL opened.
2. **Stock `universal.js` against Playport's handshake: works end to end, unchanged.**
   x16=1 with x0=NULL got an 896 MiB RX region at the reservation's floor
   (`0x119000000`), and x16=0 detached. No script edits and no `script-data` were needed.
3. **Bless time over this path: 4.11 s** for 896 MiB (57,344 pages), against
   2.93 s over Wi-Fi with the patched `bless` on the same build (§5). From the tap
   to guest code took 10.93 s: 5.4 s app switch, the "Enable JIT?" tap and return,
   1.3 s until the attach landed, 4.1 s bless.
4. **LocalDevVPN on-demand: unverified.** In this run the tunnel came up because
   the captain turned it on in Settings. nesessionmanager logged `Received a start
   command from Preferences`. `Matched on demand rule` appears only in the
   re-evaluation that the toggle itself caused. The cold run (§4) had the same
   manual Settings start (`Preferences[519]`). No run was made with the VPN off
   and nobody touching it, so whether the on-demand rule starts the tunnel by
   itself, or Playport needs the `localdevvpn://enable?scheme=` fallback, stays
   open. The fallback was not built.
5. **A workstation-made pairing file imports unchanged: yes** (§2).

### Where the run differed from the scout's read-only predictions

- **The return to Playport happens before the attach, as the code read said.**
  Playport was in front for about 1.3 s before `CS_DEBUGGED` appeared, and stayed
  in front for the whole bless. The main thread was suspended with the rest of the
  process for those 4.1 s. `didBecomeActive` was delivered only after the detach
  (+10.76 s). No watchdog kill happened.
- **The URL cold-starts StikDebug.** StikDebug does not need to be running or
  in the switcher.
- **No system prompt came before the switch.** SpringBoard logs the open as an
  "untrusted user action request" but allows it at once.
- **"Enable JIT?" prompt: appears, and needs one manual tap.** StikDebug's default
  is to ask, and the captain confirmed he tapped it before StikDebug returned him to
  Playport. The about 4.1 s between StikDebug appearing (+1.2 s) and Playport
  returning (+5.4 s) includes that tap. SpringBoard marked StikDebug's scene
  `systemModalAlert` as it left at 15:13:53.07. Only the return to Playport after
  the tap is automatic.
- **The pairing needed no Trust tap**, and it worked over Wi-Fi, not only USB.

### The "stay in front during activation" rule (in-app UI design)

The in-app launch sheet design assumes Playport stays in front for the whole
activation, because a background kill (`0x8BADF00D`) was seen when a
workstation-driven launch was backgrounded during the bless. **This path does
send Playport to the background during activation.** It leaves for StikDebug about
0.4 s after the URL opens and returns 5.4 s later, after the "Enable JIT?" tap. That is during the *wait* for
the debugger, though, not during the bless: nothing is attached and no thread is
suspended while Playport is in the background. The attach and the whole bless
happened with Playport in front, and nothing was killed. So the conflict is real
but benign in this run. A launch sheet using this vehicle must expect one trip to
StikDebug and back before the bless, and must not treat that background
transition as a failure. The Built-in StikJIT extension would remove the switch
completely.

## 4. Cold run after a reboot

Times are the phone's clock, from
`cold-syslog-milestones.txt` and
`cold-s1-host-key-lines.txt`.
Offsets are Playport's own `jit:` offsets, counted from when it starts asking
for JIT, just before the URL opens at 17:27:35.65.

- **IPA:** `Playport-26.5-bb83494c.ipa`, sha256
  `bb83494c8ed0c5540baf028d7d20b981972425962d46a5462e7d76f25840bc11`, built from
  the app code at commit `785d596`. It includes the return-to-list failure
  handling, but nothing failed in this run, so that handling never ran (§6); the
  later change that reports a refused StikDebug URL by name came after it. Installed in place at 17:14:41, with a DDI mounted at `/System/Developer`.
- **Reboot:** the workstation restarted the phone (`pymobiledevice3 diagnostics
  restart`) at 17:15. After the reboot and unlock, `pymobiledevice3 mounter list`
  showed no mounted images (`[]`). From then on the workstation only recorded the
  syslog; it drove nothing.

| Time | Offset | What happened |
| --- | --- | --- |
| 17:16:24-17:16:25 | | LocalDevVPN tunnel connected, via `Received a start command from Preferences[519]`: the captain had opened Settings, VPN |
| 17:17:39 | | StikDebug started (pid 633) with nobody opening it, most likely a background launch (it declares `UIBackgroundModes` audio, location, fetch). It mounted nothing then |
| 17:27:33 | | Playport launched from the Home Screen (pid 692); the captain tapped Hollow Knight |
| 17:27:35.65 | 0 | Playport opened `stikdebug://enable-jit?...&pid=692&script-name=universal.js`; SpringBoard `allowed=1` |
| | +0.41 | Playport resigns active; StikDebug, already running, comes to the front and shows "Enable JIT?", which the captain confirmed (one tap) |
| | +1.22 | Playport in the background |
| 17:27:38.85-17:27:38.88 | | about 3.2 s after the URL opened, **cryptexd mounts the DDI** (`com.apple.MobileAsset.DDI: custom mount path`; apfs `disk5s1 mounting volume Xcode_iOS_Cryptex_DDI, requested by: cryptexd`, then `mount-complete`) |
| | +5.24 | Playport back in front, debugger not attached yet |
| 17:27:41.63 | | Playport sees `CS_DEBUGGED`, frees the pool range |
| 17:27:44.99 | | `prepare(NULL, 0x38000000) -> 0x119000000 in 3.36 s`, inside the reservation |
| | +9.70 | Playport active (debugger attached) |
| 17:27:45.07 | +9.84 | **debugger detached**; `acquire(896 MiB) via stikDebug -> 0 after 9.84 s`; `wine_host_init -> 0`, activation 9.84 s |

Afterwards `mounter list` showed a Personalized DeveloperDiskImage
(ProductBuildVersion `27A5228h`) at `/System/Developer`. So StikDebug 3.1.11's
cryptex DDI mount works cold on iPhone18,4 / iOS 27.0, inside the StikDebug step.
The cold run, including the DDI mount and the "Enable JIT?" tap, took 9.84 s from
the tap to guest code, faster than the first run's 10.93 s (bless 3.36 s against
4.11 s). The captain's report: "Game ran properly": Hollow Knight launched and ran.

The tunnel was again brought up by hand in Settings, so LocalDevVPN's on-demand
rule reconnecting it by itself remains unverified.

## 5. Workstation path on the same build

`harness/ladder/tools/ladder.py run --backend ios --pool-mb 896 --rungs cpu-jit`
(`dvt launch` with a ladder step, then `stik_universal_debug.py`): **pass**.
`JitProvider` took the workstation vehicle because the launch carried a step, so
it opened no URL and waited for the attach as before:
`jit: acquire(896 MiB) via workstation -> 0 after 5.53 s`, bless 2.93 s
(`workstation-key-lines.txt`).
With StikDebug installed, a workstation launch still never calls it.

## 6. Open items

- LocalDevVPN on-demand start with the tunnel off and no manual toggle (both
  runs had a manual Settings start), and so whether Playport needs the
  `localdevvpn://enable?scheme=` fallback.
- Whether turning the "Enable JIT?" prompt off in StikDebug's settings removes
  the tap, which would make the flow tap Playport, tap title.
- A second launch in the same session.
- For Built-in StikJIT: the bless ran inside StikDebug's own process on the
  phone. An extension in Playport's bundle would do the same work, so 3.4-4.1 s is
  the bless cost to expect there too.

### Verified by code review only, not live

Nothing failed in either live run, so none of these paths has run on the device:

1. Any in-app launch failure returning to the title list with the "The title
   launch ended" alert and "Back to titles": this screen never appeared.
2. StikDebug not installed: the "StikDebug is not installed" message and a retry
   from the list.
3. The system refusing the StikDebug URL (for example, StikDebug's free-team
   profile expired): the "the system did not open the StikDebug URL" message. This
   change (commit `de804e4`) is in no built or installed IPA.
4. A launch marked spent after a failure past the attach, so that another title
   needs Playport relaunched.
