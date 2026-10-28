# iOS NSI: one interface snapshot, reused for a second (PLA-460)

**Linear:** [PLA-460](https://linear.app/playportdev/issue/PLA-460), from
[PLA-455](https://linear.app/playportdev/issue/PLA-455).
**Result:** the repeated-call mechanism is removed; host checks, the final iOS
build, HK smoke and W3 gameplay/profile checks pass. MainThread's share of the
Linux-driven profile falls from 27.4% to 22.3%, and its `__sysctl` leaf share
from 3.23% to 0.09% of all samples. Sustained FPS is essentially unchanged;
this is not proof of a general frame-rate or hitch improvement.
**Scope:** remove the repeated adapter-table system calls, not fabricate connectivity
or change a game's network behavior. Built, signed and installed on Linux; the Mac
was used only to attempt an Instruments recording.

## Change

`patches/wine-unix/0201-nsiproxy-iOS-one-interface-snapshot-per-table-read-k.patch`
(`Class: ios-port`) follows 0019. Under `if_list_lock`, refresh one `getifaddrs`
snapshot at the start of a read and reuse it for one second:

- `AF_LINK` rows provide name, index, type, physical address, flags, MTU, link speed
  and counters. They replace `if_nameindex` as well as the socket/two ioctls and
  `getifaddrs` previously taken per dynamic row. Physical-address initialization
  borrows the same list.
- Enumeration, keyed reads and name/index/LUID conversions all check freshness,
  even on a lookup hit. Removed/replaced entries are skipped after refresh;
  their allocated names remain alive for callers retaining those pointers.
- Row filling cannot refresh or free the list mid-enumeration, including across
  a TTL boundary. Failed refreshes discard stale data and do not retry per row.
  Successful empty lists and failed reads also have the one-second TTL.
- Each family's routing dump has that TTL under a separate mutex, including
  empty, sandbox-denied and failed results. Existing parsing, three-attempt
  growth-race retry and interface-mapping checks remain. Route-to-interface is
  the only nested lock order.

Topology and counters can therefore be up to one second old when the next read
starts. There are no notifications or proactive refresh timer. IPv4/IPv6 unicast
address reads remain uncached; this is not one snapshot for an entire
`GetAdaptersAddresses` call. Non-iOS paths, pins and title defaults are unchanged.

## Caller: the game's Galaxy service, not ModioThread

Workstation evidence already available before the fix:

- `.work/perf/w3-prof1/profile.txt` attributes 2.7% inclusive to
  `witcher3.exe+0x2546470`; this is a saved guest call site, not a native symbol.
- The saved 4.x executable `.work/agent-notes/pla-452/pull/witcher3.exe` has sha256
  `2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101`.
  Its `WININET!InternetGetConnectedState` import is at IAT RVA `0x298d850`.
  The wrapper at `0x2546460` calls through that slot at `0x2546470`.
- Its pointer at vtable RVA `0x39c8b80` belongs to `services::Galaxy`
  (MSVC RTTI type descriptor `.?AVGalaxy@services@@`). These are ordinary
  `llvm-objdump`/PE-layout observations, not recovered original source.
- Wine's `dlls/wininet/internet.c:InternetGetConnectedStateExW` implements that
  query with `GetAdaptersAddresses`; `iphlpapi` asks NSI for the NDIS table,
  unicast addresses and forwarding tables. The IP interface provider also asks
  for individual NDIS rows.

Together the sampled call site and import/vtable identify a game-embedded
Galaxy-service caller. They do **not** establish its exact polling rate or prove
that it calls once per frame. Only executable/DLL subsets, not a runnable full
W3 4.x installation, are present on this workstation. The bounded desktop
call-rate experiment remains [PLA-470](https://linear.app/playportdev/issue/PLA-470);
no desktop rate or per-title workaround is claimed here.

## Host checks

- `python3 -m unittest tools.tests.test_nsi_ios -v`: four checks pass.
  `nsi_snapshot_test.c` compiles the exact shipped snapshot helper **and iOS
  dynamic-row filler**, with interposed `getifaddrs`/`freeifaddrs`, ASan and UBSan.
  A 36-interface enumeration makes one `getifaddrs`, not 36. It checks flags,
  MTU, speed and counters, missing rows/data, TTL edges, renamed/missing rows,
  backward time, failed refresh, recovery, successful empty snapshots and frees.
- `nsi_forward_test.c` compiles the exact forwarding enumerator by applying its
  headers in series order. Mock time/sysctl exercise IPv4/IPv6, count-only,
  short-buffer and fill reads, row fields, cached interface mapping checks,
  expiry, four concurrent readers, empty/denied/error results, bounded growing
  table retries, malformed data and recovery. ASan/UBSan pass.
- Deliberately restoring per-row refresh makes the snapshot test fail its
  `calls == 1` assertion. Disabling caching for empty routing snapshots makes
  the route test fail its sysctl-count assertion. Scratch experiment:
  `.work/agent-notes/pla460/mutation-check.py`.
- These Linux tests stub Darwin/Wine types; they are not Darwin ABI tests or an
  execution of the complete Wine `GetAdaptersAddresses` entry point. The iOS
  build and phone table results complement them. The dispatcher/WoW64 and route
  decoder/fuzz checks remain in the suite.
- Full `./pp test`: passed (776 tooling tests, host C checks and all Swift
  packages); `.work/pla460/test-final.log`. Names, secrets and patch checks pass.
- `./pp build --keep-outputs 12`: passed, including 90 IPA checks;
  `.work/pla460/build-final.log`. The normal `.work/run` build changed only
  `app/artifacts.tsv`'s `libntdll_unix.a` row among committed build records.

## Phone setup and builds

Phone: iPhone18,4, iOS 27.0.1, charging. Upgrades in place; no uninstall.

| Arm | Dev IPA sha256 | Run under `$PLAYPORT_BUILD/` |
| --- | --- | --- |
| Baseline (before 0201) | `94917fa7ac4128e51f08fd89e47d525b1fa196f797929f1ea1ad625a5a3edfc0` | `perf/pla460-base1` |
| Final 0201 | `2a13a59fe37277cbb9cd5771f0d5805ad7125bb3977899d2423377045d75f8eb` | `perf/pla460-final1` |

The baseline IPA was built at `e3423b3`; changes through this task's base
`46d63bc` are workstation tooling/docs, not app/runtime code. Both arms use
**today's** pad scripts. Each run uses `pp perf --title app-292030 --secs 150
--cool 6 --cool-max 15 --cpu-prof --pad first-frame+10:witcher3-continue
--pad first-frame+50:witcher3-walk --shot first-frame+60 --shot first-frame+140`
and an explicit `--expect-ipa`. Compare only +60 to +150 seconds after first
frame (`pp perf --compare ... --window 60:150`). Defaults keep PAUSE as YIELD;
`dx12user.settings` retains 1302x600 (the swapchain log, not the host HUD's
1564x720). This is Kaer Morhen's bedroom save, not an arbitrary benchmark scene.

### Sustained performance (+60 to +150 s)

| Arm | FPS | p50 ms | p99 ms | p99.9 ms | Frames ≥50 ms | ≥100 ms | ≥150 ms | GPU ms | CPU Mi/frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 20.8 | 41.68 | 108.37 | 216.74 | 833 | 58 | 5 | 27.21 | 400.3 |
| Final 0201 | 21.1 | 41.68 | 91.70 | 383.47 | 846 | 14 | 7 | 30.10 | 360.3 |

This one pair does **not** establish an FPS gain (only +1.4%). The 100 ms count
and p99 improve, but the 150 ms count and p99.9 worsen; no general hitch win is
claimed. CPU instructions/frame fall about 10%, consistent with less redundant
work. Both runs are almost entirely E-core-bound in this window. The final run
reached Serious thermal state (pressure 20, first pressure +40 s), the baseline
only Fair (pressure 10, first pressure +60 s); GPU time also differs. Both began
at 80% battery on the charger. The screenshots show the same room and active
Witcher Senses tutorial, but different camera/character positions after the
scripted walk: this is matching input, not a pixel-identical replay. Thermal
and scene variability limit the comparison.

### CPU sampling (whole run, not just the sustained window)

| `% of all running samples` | Baseline (13,703 samples) | Final (13,279 samples) |
| --- | ---: | ---: |
| MainThread | 27.4 | 22.3 |
| MainThread / `__sysctl` leaf | 3.23 | 0.09 |
| Saved guest call site `witcher3.exe+0x2546470`, inclusive | 5.5 | 2.1 |

Values come from `tools/sampleprof.py`'s burst-weighted tables (already rounded
within each burst), not new native stack traces. `MainThread/getifaddrs` is 0.10%
in the baseline table and not reported in the final table; absence from the
bounded sampling tables is not proof of zero calls. Together with the host
call-count test, the results support removal of the hot path, not elimination
of all network-query overhead.

### Smoke and adapter-table check

- **HK:** `.work/ui-runs/20261028T173202`, final IPA above, first frame +10.79 s,
  reached first-frame+10. `screen-stop.png` shows the normal menu. Smoke only,
  no new HK gameplay/performance claim.
- **W3:** `.work/perf/pla460-final1`, first frame +18.91 s, reached
  first-frame+150. Shots at +60 and +140 show Geralt in Kaer Morhen's bedroom,
  not a menu or a blocked Welcome panel. Baseline first frame was +19.34 s.
- W3's final log has successful NSI reads for 33 NDIS interfaces, 5/31 IPv4/IPv6
  unicast rows and 20/36 forwarding rows. Adapters/addresses/routes still return;
  this is the real WinInet/GAA consumer path, not a synthetic LAN override or
  a separate standalone `GetAdaptersAddresses` probe.
- All results above use the final IPA; the run's `installed` event records its
  full SHA. Screenshots, logs and raw metrics stay under `.work/`; no artwork is
  committed. `site/compatibility/games.json` remains `issues` for W3 and `works`
  for HK, matching their Linear title records.

## Verification limits and follow-ups

The initial implementation's IPA `aadf8334f2ab6d67d8238f854960fc9c6a6a7b3bee07f311b15bc49c3d70d813`
passed HK and a W3 profile (`perf/pla460-prof1`), but it is **not** the final patch
and is not used as the final performance result. The older `w3-prof1` run also
used an older pad script and different thermals: its FPS is not the A/B baseline.

A new native before/after `getifaddrs` sample count was attempted on the Mac.
`pp gpu live` played W3 through first-frame+105, but `xctrace` exited 13,
"Timed out waiting for device to boot"; no trace was produced, so the scripted
session stopped before installing the final IPA. Mac artifacts:
`$PLAYPORT_BUILD/mac/pla460/base2.jsonl` and `base2/apple-tools.txt`.
The first attempt stopped before launching because the non-interactive SSH
PATH omitted the pymobiledevice3 launcher; setting PATH fixed that prerequisite,
not the Instruments connection. Follow-up: [PLA-469](https://linear.app/playportdev/issue/PLA-469).
**No claim that native `ifinfo`/`getifaddrs` samples fell to zero is made.**

For context, re-reading the original `mst1` trace with both stack **and frame**
id/ref resolution gives `getifaddrs` in 1,951 of 6,825 MainThread running samples
(28.6% inclusive). This differs from the prior evidence's first-named-frame
classification; it is not a new before/after measurement. Scratch parser:
`.work/agent-notes/pla460/trace-summary.py`.

## Operational notes

Owner-authorized cleanup removed only the three identified leftover `.gputrace`
bundles: two captures in the app's `tmp/` (about 4.00 and 4.05 GB), and HK's old
545 MB capture. File/byte/link counts were checked; no game, prefix, Steam
session or shader-cache file was removed. Reported free space rose from 0.0 to
8.5 GB. The Mac retains the profiled W3/HK artifacts; the abandoned first W3
capture was discarded at the owner's request.

Signing initially hit Apple's 409 "no current IOS devices". Following
`docs/DEVICE.md`, Linux made an unsigned release IPA and `xtool install`
registered the phone by upgrading that same app; `pp install` then restored
the dev IPA. This was registration/upgrade, not a release distribution or an
uninstall. Private account/device data and captures remain uncommitted.
