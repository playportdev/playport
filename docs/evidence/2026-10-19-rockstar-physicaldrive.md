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
