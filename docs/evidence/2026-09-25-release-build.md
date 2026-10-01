# The release build: no harness, a quiet runtime, one capped log

**Date:** 2026-09-25. **Tree:** the commit that adds this record, [decision
0009](../decisions/0009-dev-and-release-builds.md),
[madeira-unix 0018](../../patches/madeira-unix/0018-ntdll-skip-the-diagnostic-samplers-and-censuses-when.patch)
and [dxmt 0007](../../patches/dxmt/0007-dxmt-report-no-memory-census-when-MADEIRA_NO_DIAGNOS.patch).
**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, with the
whole session run under `flock $PLAYPORT_BUILD/device.lock` after
`tools/phone-busy` said idle.

**Result:** both variants build from one set of trees and pass
`verify-ipa`. The release IPA carries no harness code, test program or
guest. It launches from the Home Screen into the library, built-in JIT
reports ready, and Steam signs in. With the release build's runtime
switches, a 90 s Hollow Knight run writes 486 KB of log instead of 5.9 MB,
and none of it is a sampler or census line.

## 1. The IPAs

Built in the lane `$PLAYPORT_BUILD/lanes/variants`. `run/unix` is a reflink
copy of the `merge-w3` lane's tree with the series rebuilt (18 patches;
`libntdll_unix.a` `d9a2c7ce…`). `pe` and `fex` are hard links to that lane's
trees. DXMT, the XInput DLLs and the app were rebuilt in the lane. The
committed `app/artifacts.tsv` is this lane's record: the `libntdll_unix.a`
row (0018) and the seven DXMT PE rows (0007, and the lane's build root) change.

| Variant | IPA | sha256 | Bytes | verify-ipa |
| --- | --- | --- | --- | --- |
| dev | `out/20260925-093645-487c2af1/Playport-26.5-487c2af1.ipa` | `487c2af17e99a0d98b8a6d01ed16a51ac2f6c481628821106858ec737d2f92b7` | 609,143,961 | 61 passed, 0 failed |
| release | `out/20260925-093718-release-488a6c22/Playport-26.5-release-488a6c22.ipa` | `488a6c2283d32de601bc15e9e221cd5b24391210ca4db817900c511e11fec855` | 606,097,977 | 63 passed, 0 failed |

The release IPA holds `Payload/Playport.app/Playport`. No entry matches
`proc-test`, `child-test`, `ladder-` or `g2-`, against 15 in the dev IPA.
Negative controls: checked as `--variant release`, the dev IPA fails 6 checks
(its executable name, the manifest, the 13 guests, the `S1Probe` and
`LadderKit` symbols, 12 harness environment and file names, and no
`playport.log`). Checked as `--variant dev`, the release IPA fails 2 (its
executable name and the manifest).

## 2. The log on the phone

Two driven runs of Hollow Knight from the dev IPA (`title-device-run.py
--no-hud --pool-mb 896 --title-wait 90`), each after `rotate-host-log.py`,
both ending `running after_s=90 (TITLE_WAIT_S reached)`. Run C adds the
release build's four switches with `--env`:
`MADEIRA_NO_DIAGNOSTICS=1 MADEIRA_QUIET=1 WINEDEBUG=-all DXMT_LOG_LEVEL=error`.

| Lines in `s1-host.log` | A: dev default | C: release switches |
| --- | --- | --- |
| bytes | 5,897,197 | 486,028 |
| lines | 60,343 | 5,148 |
| `[xp` | 749 | 0 |
| `[thread-sample` | 289 | 0 |
| `[span-census` | 1,160 | 0 |
| `[valloc` / `[vfree` | 3,000 / 3,000 | 0 / 0 |
| `[buf-site` | 3,106 | 0 |
| DXMT `census]` lines (all kinds) | 10,403 | 67 |
| Wine `:err:` / `:fixme:` | 32,138 / 231 | 0 / 0 |

In C the 67 `census]` lines are other one-off reports (`[dc-census]`,
`[bc-census]`, `[sync-census]`), not the DXMT memory census. Most of what C
still writes comes from thread start-up and FEX: `[CB_SUMMARY]`, one line per
16,384 translated blocks, and `[vname] FEXAllocator`. A first attempt at the
release switches, with only the samplers off, wrote 2.65 MB in the same 90 s,
most of it the DXMT memory census (590 reports) and the first 3000 `[valloc]`
and `[vfree]` lines. That is why 0018 also covers the census and 0007 exists.

## 3. The release IPA from the Home Screen

The release IPA was installed over the dev one (same bundle ID, container
kept) and launched with `dvt launch` and no environment, the way the Home
Screen launches it. After 25 s the screen showed the library with both staged
titles (release-home.png (screenshot not published)).
`Documents/playport.log` held 1,318 B: the built-in JIT readiness check
(`jit: helper: ready, TXM present`) and the Steam session's scrubbed `[ui]`
lines, prefixed `steam:`. There was no `s1-host.log` line and no
`steam-drive.log` write. The IPA installed before the session
(`merge-w3` `8a2128c3`) was reinstalled at the end.

## 3b. The release Settings screen

A player on the first release IPA still saw the dev build's JIT panel: the
Built-in/StikDebug picker, "Readiness: ready (TXM …)", the helper's raw
reason and "Reset Developer Disk Image". The release build now has the
built-in helper only. Its `Info.plist` no longer queries `stikdebug`, and its
JIT section is a plain status with the pairing file import. "Check again" and
"Download the disk image again" appear only after a failed check. Its result
screen gives what to do instead of the helper's reason or an exit code.

The rebuilt pair is dev `out/20260925-095406-e8516652` (sha256
`e8516652596c0e561a1f753c74d1e9a1a29375bbd447f52fa161f76289343d54`,
`verify-ipa` 61 passed) and release
`out/20260925-095418-release-8518b01e` (sha256
`8518b01e1f2e7465a9095b079183fdb2c129b30d54338c32e4152afc79112b42`,
64 passed, including the new `Info.plist` check). The release IPA was
installed over the first one (container kept) and Settings opened through
the accessibility inspector. It showed Storage, then JIT with "Status: Ready"
and "Replace pairing file" only.

The game pages followed: dev `out/20260925-095840-68d5f6a9` (sha256
`68d5f6a966750114fedf0c40ff454d48ed9237d2cb56186560f166c084dd4ced`, 61
passed) and release `out/20260925-095852-release-956d0fd9` (sha256
`956d0fd947b4174db88cf06e9e1b2cc38bbdd46c127ccf0aab320e6b138fe698`, 64
passed), installed in place. The release executable holds none of the
detail pages' removed labels (`strings`). The page itself was not opened
remotely: the accessibility press opens Settings, but not a list row.

## 4. Host checks

- `app/tools/hostio-selfcheck.sh` passes, including the new
  `app/tests/host_log_test.c`: unlimited appends, a limit reached by direct
  appends and a limit reached through stderr.
- `verify-ipa.py --app` on unsigned builds of both variants.
- `tools/check-names`, the series check and the `tools/tests` suite pass.

## 5. Not yet done

- **A title started from the release build's Play button.** Nothing can drive
  a release build, by design, so this needs someone at the phone. The runtime
  side (the switches) is what run C measured; the launch path is the same
  `LaunchCoordinator` as the dev build's library Play.
- **The session limit on the phone.** `host_log.c`'s stop is tested on the
  host. `wine_host.c`'s watchdog, which cuts the runtime's stderr off at
  4 MB, is not tested anywhere yet. At run C's volume a session reaches the
  limit only after many minutes.
- **The steady-state rate under the release switches.** The FEX lines carry
  no timestamps, so this log cannot show it.
