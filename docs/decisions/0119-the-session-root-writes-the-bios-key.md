# 0119: The session root writes wineboot's BIOS key

**Status:** accepted, 2026-10-19, by the agent working
[PLA-401](https://linear.app/playportdev/issue/PLA-401). Amends
[0080](0080-prefix-wineboot-parity.md) (what wineboot gives a prefix that the app writes itself).

## Context

The app never runs wineboot (0080). At each Wine session's start, wineboot's
`create_hardware_registry_keys` writes the volatile `HKLM\Hardware\Description\System` keys. The
host already writes the processor part (WineHost `prefix_registry_machine_values`), but not the
`BIOS` subkey, which wineboot fills from the SMBIOS table:
- BIOS (type 0): vendor, version and release date, and the BIOS and EC release numbers;
- system (type 1): manufacturer, product name, version, SKU and family;
- baseboard (type 2): manufacturer, product and version.

The Rockstar Games Launcher reads the SMBIOS table after sign-in. A moment later its last call
before it ends is a `RegOpenKeyExA` on `HKEY_LOCAL_MACHINE` that fails with
`ERROR_FILE_NOT_FOUND` ([evidence](../evidence/2026-10-19-rockstar-physicaldrive.md)). On desktop
Wine and Proton the key exists.

## Decision

- **The session root writes the key.** At its start, before it reports ready, `playport-session.exe`
  runs wineboot's code for those three structures. It reads `GetSystemFirmwareTable('RSMB')`, the
  same table any program reads, and writes `Hardware\Description\System\BIOS` as a volatile key
  with wineboot's 15 values.
- **Every title gets it,** as on desktop Wine. Under desktop Wine 11.19 the key matches
  wineboot's own for the same table, value for value.

## Costs and limits

- One firmware query and 15 registry writes per app process, in the x86-64 session root.
- The values are whatever the iOS SMBIOS table holds (ntdll's `__APPLE__` path). Nothing is
  invented here.
