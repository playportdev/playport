# 0118: Wine's mount manager for a play that runs services

**Status:** accepted, 2026-10-19, by the agent working
[PLA-401](https://linear.app/playportdev/issue/PLA-401) under the owner's goal for Red Dead
Redemption 2 (reach its menu). Amends [0107](0107-windows-services-for-a-flagged-play.md) (one more
service entry) and [0080](0080-prefix-wineboot-parity.md) for that entry.

## Context

After sign-in the Rockstar Games Launcher opens `\\.\PhysicalDrive0` to `\\.\PhysicalDrive9`.
When none opens, it executes a HLT, which FEX reports as `0xc0000096`, and the launcher ends
([evidence](../evidence/2026-10-19-rockstar-physicaldrive.md)). That stops RDR2's Steam copy
before the game starts.

In Wine these names come from the mount manager, `mountmgr.sys`, a kernel driver that the SCM
starts with itself (wine.inf `[MountMgrService]`: type 1, boot start) in `winedevice.exe`. Its
`disk_driver_entry` always creates `\Device\Harddisk0` with the link `\??\PhysicalDrive0`. It also
makes a `\Device\HarddiskVolumeN` for each dosdevices drive and `\??\MountPointManager`. Desktop
Wine and Proton always run it.

Playport ran none of it:
- the prefix seed holds no service entry (0080);
- a play with services (0107) wrote only RpcSs's entry;
- the driver could not have started anyway, because its `DriverEntry` first binds its unix side and
  the one-process host had no table for it.

## Decision

- **Its unix side ships** (`patches/madeira-unix` 0163). mountmgr's `unixlib.c` is compiled into
  `libntdll_unix.a` and found by module name, as nsi's is. Its host back-ends get the bodies Wine
  uses where they are not compiled in:
  - udisks and DiskArbitration loops: none;
  - keychain credentials: `STATUS_NOT_SUPPORTED`, so advapi32 keeps them in the registry, as on
    Linux;
  - CD drives: none.
- **A play with Windows services also tops up wine.inf's MountMgr entry**
  (`WindowsServices.mountmgr`, beside RpcSs's): `Type` 1, `Start` 0, `ErrorControl` 1, `Group`
  "System Bus Extender", `ImagePath` `C:\windows\system32\drivers\mountmgr.sys`. It is written only
  where the prefix lacks it and never removed. The SCM starts it with itself, so it runs only in
  such a play; 0107's stop at the title's end covers its winedevice.
- **Every other play is unchanged.** No services.exe means no driver.

## Costs and limits

- One more pseudo-process, `winedevice.exe`, with ntoskrnl and the driver. It is ARM64EC code but
  takes pool head for its images, and the Rockstar launcher's margin is thin (PLA-399).
- In such a play the drive links that Madeira's wineserver publishes now point at real volume
  devices. Opening `\\.\C:`, mount-point queries and `GetVolumeNameForVolumeMountPoint` now get
  mountmgr's answers, as on desktop Wine, instead of failing.
- Harddisk0 has no unix device behind it. Its storage queries answer with mountmgr's generic data,
  as on desktop Wine for a disk with no udisks entry.
