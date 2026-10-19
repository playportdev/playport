# The Rockstar launcher's HLT: no physical drive (PLA-401)

**Linear:** [PLA-401](https://linear.app/playportdev/issue/PLA-401). Follows
[the generated fault](2026-10-18-rockstar-generated-fault.md). Change: decision
[0118](../decisions/0118-the-mount-manager-for-a-play-with-services.md), `patches/madeira-unix`
0163, `WindowsServices.mountmgr`, WineHost `link_drivers`.

## Cause, from the existing call ring (run `20261018T224153`, IPA `3671f980`)

Chunk 9 recorded Launcher.exe's main-thread x64↔EC calls (fex 0051). Its last 512 transitions end
like this:

- three `LdrLockLoaderLock`/`LdrUnlockLoaderLock` pairs;
- ten `kernelbase.CreateFileA` calls from the same call site, about 1 ms apart, each returning
  `INVALID_HANDLE_VALUE`;
- 2.7 ms after the tenth, the HLT.

All ten calls pass the same name buffer (`rcx`), which is `rsp+0x90` in the fault frame. The host
log's guest-stack dump holds the ASCII text `\\.\PhysicalDrive:` there. The launcher tries
`PhysicalDrive0` to `PhysicalDrive9`, and its digit is left one past `9` (`'0'+10` is `:`). With
no physical drive found, it halts.

In Wine these devices come from `mountmgr.sys`: `disk_driver_entry` always creates
`\Device\Harddisk0` and its `\??\PhysicalDrive0` link. Desktop Wine and Proton always run it. In
Playport it never ran:
- the prefix had no MountMgr service entry;
- the driver's `DriverEntry` fails when its unix side cannot bind, and the one-process host had no
  table for it.

## Phone (IPA `1bbc4f129b6954e460a2c543c2eb88639ccf1c66e6b1f057e604723183b47c49`)

`./pp build` passed 89 of 89 IPA checks; `./pp test --quick` passed. All runs were in one lock
session. RDR2 used its compatibility defaults (Vulkan, Steam client, Windows services, 896 MiB
pool). No authentication or game input was given.

| Game | Run under `.work/ui-runs/` | Observation |
| --- | --- | --- |
| Hollow Knight (367520) | `20261019T102847` | first frame +9.37 s, first-frame+10 reached |
| RDR2 (1174180) | `20261019T103006` | see below |

RDR2:
- **The driver runs.** `system32/drivers` got 19 links. services.exe started `winedevice.exe`,
  which loaded `mountmgr.sys`, and the session listed `Winedevice1: running`.
- **The launcher's disk query reaches it.** The launcher signed in from its remembered session and
  reached its main window (`Active`). mountmgr then logged `Faking StorageDeviceProperty data`,
  the answer to the launcher's disk-property query.
- **The HLT is gone.** There was no generated #GP and no `0xc0000096`.
- **A new fault follows.** 467 ms after `Active` (the HLT came at 189 ms), the launcher's main
  thread jumped to `0x18092842d`, an address no module or view covers (NOEXEC, then
  `c0000005`, unhandled). Rockstar's own log reports `Exception: 0xc0000005` with that frame.
- **Then the pool ran out.** Playport's pool rule ended the play at +63 s (`head_exhausted=6`,
  room 0). It happened while the launcher's processes were being torn down, after the fault.
- On Linux, Wine's udisks back-end adds only volumes, so desktop Proton's `PhysicalDrive0` is the
  same identity-less Harddisk0. The disk's missing serial is therefore not by itself a difference
  from desktop.

**Status:** the PhysicalDrive check passes as on desktop Wine. RDR2 is still Broken, now on the
jump to an unmapped address after the main window.

## The next call: `HKLM\Hardware\Description\System\BIOS` (decision 0119)

A second run on the same IPA had the call ring armed for Launcher.exe (`20261019T104312`). It
shows:
- The jump target is `Launcher.exe + 0x400b842d` in both runs, under different image bases: a
  computed address, not a stale pointer.
- The last call before the jump, 8.4 ms earlier, is `kernelbase.RegOpenKeyExA(HKEY_LOCAL_MACHINE,
  …)`, which returns `ERROR_FILE_NOT_FOUND`. Before it came loader-lock pairs, and before those
  the SMBIOS read.
- wineboot writes the volatile `Hardware\Description\System\BIOS` key from that SMBIOS table at
  every session start. The app never runs wineboot, and the host wrote only the processor part of
  that key.

The session root now writes that key (`playport-session.c` `bios_key`). Under desktop Wine 11.19
in a scratch prefix it wrote 15 values that match wineboot's own for the same table, value for
value.

Phone, IPA `4232943d87d4793aca626218e08afa24eac7129190902d04b9a92d6d190967ba` (89 of 89 IPA checks):

| Game | Run | Observation |
| --- | --- | --- |
| Hollow Knight (367520) | `20261019T105528` | first frame +9.30 s, first-frame+10 reached |
| RDR2 (1174180) | `20261019T105650` | see below |

RDR2:
- **No crash.** `session: bios key: 15 values from SMBIOS`. The launcher signed in, showed its main
  window ("Rockstar Games Launcher") and made its disk query. There was no jump, no `c0000005` and
  no `c0000096`.
- **Then the FEX band filled.** 197 emulator threads used 16,274 of 16,384 MiB, 718 rpmalloc spans
  of 16 MiB, and 24 requests were refused.
- **Two Social Club helpers then spun.** They are the CEF children the main window starts. Their
  FEX code (`libarm64ecfex.dll` +0x10aad0) stores through `0x800000` and handles the fault, about
  150,000 times per thread. The screen stayed on the launcher's logo until the run was stopped at
  about 10 minutes.
- `RDR2.exe` was not started.

**Next blocker:** the FEX host band's per-thread cost, now that the signed-in launcher runs its main
window's CEF processes. RDR2 stays Broken.
