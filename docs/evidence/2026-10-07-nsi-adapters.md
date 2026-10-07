# iOS NSI adapter and IP tables (PLA-58)

**Date:** 2026-10-07. **Result:** PLA-58's adapter-table follow-up passes;
limitations below remain outside that fix. **Phone:** dev IPA
`232b7020ce87ddfce8a442c4a9b38b8a6e7d2882f1e544542f1f7889c77355ff`,
iPhone18,4, iOS 27.0, upgraded in place. No release build or draft.

## Change

The missing `\\.\Nsi` device no longer limits the in-process fallback to TCP
connection enumeration. Madeira-unix 0095 compiles Wine's NDIS/IP providers
into the unix archive and dispatches enumeration, all-parameter and individual
parameter reads. Wine-pe 0030 forwards the two keyed query entry points too:
`GetAdaptersAddresses` needs LUID-to-GUID conversion as well as the initial
interface table. i386 calls have a separate table converting pointers through
the owner's WoW64 window, with span checks. TCP keeps wineserver's socket owner
information.

Wine-unix 0019 adapts the providers to the iOS SDK: link metadata/counters come
from `getifaddrs`, addresses from Wine's existing IPv4/IPv6 provider, and IPv4
**and IPv6** routes from a bounded Darwin `NET_RT_DUMP` decoder. Route masks may
be compressed; host routes need no mask; network prefixes are normalized;
IPv6's embedded link-local zone is represented by the interface LUID. Malformed
messages, sockaddr overruns and noncontiguous masks are rejected. A routing-table
size race retries up to three times, with a 16 MiB snapshot limit. Removed
interfaces are excluded from subsequent enumerations and stale/replaced identities
from keyed lookups. IPv6 interface rows do not apply Linux's address-class filter
to Darwin's interface-index scope IDs. The new diagnostic logs
only module/table/status/count, not addresses or hardware identifiers.

Wine-pe 0030 also retires wine-pe 0029's unconditional LAN workaround. GOG
sign-in must now use the adapter/address/route data rather than pretend the
missing adapter table is a connection. No store credentials or session design
changes, no achievements/stat writes and no sign-out.

## Host checks so far

- Targeted cross-compile of both NDIS/IP providers against the iOS SDK: passes.
- `python3 -m unittest tools.tests.test_nsi_ios -v`: passes. It compiles the exact
  decoder extracted from the shipped patch under AddressSanitizer and UBSan.
  Cases include compressed IPv4 masks, default/host routes, IPv6 gateways with
  embedded scope, normalization, unaligned messages, truncation, invalid masks,
  sockaddr overruns, skipped multicast/down routes and 20,000 random inputs.
  The shipped dispatcher/WoW64 adapters are also compiled with synthetic providers:
  count-only/sizing/fill, keyed reads, wrong sizes, unknown tables, overflowing
  parameter offsets, owner-window pointer/span checks and PE32 layouts pass.
- `pp names` and `pp secrets`: clean. Non-patch diffs pass `git diff --check`;
  new format-patch files contain their required single-space blank context lines.
- `pp test --quick`: passes before the final IPv6 interface/index refinements.
- First full `pp test`: its Swift suites passed, but a GStreamer-notices fixture's
  temporary Git directory failed cleanup (`Directory not empty`). The exact fixture
  passed immediately on its own; no unrelated code was changed. The subsequent
  full `pp test` rerun passed, including 512 tooling tests, host C tests and all
  Swift packages.
- First and final full IPA builds: all 80 checks pass; the final IPA is the one
  identified above.

## Phone check

All runs used the app's Play button through `pp ui` with `--expect-ipa` and no
pad input. Screenshots remain in the run directories; no artwork is committed.

| Title / run under `$PLAYPORT_BUILD/ui-runs/` | Result |
| --- | --- |
| Moonscars (`gog-2106173825`), `pla58-moonscars`, `first-frame+60` | JIT 2.41 s, first frame +5.54 s; screenshot is the title screen, “Press Space to Start”. `AUTH_INFO -> 200`, token minted in 0.19 s; Player.log has one `OnAuthSuccess`, one `GOG_SERVICES_CONNECTION_STATE_CONNECTED`, no `OnAuthFailure`. Three web-broker subscriptions; connection held. Gameplay not tested. |
| Monster Train (`gog-1304291300`), `pla58-monstertrain`, `first-frame+60` | JIT 2.45 s, first frame +4.32 s. `AUTH_INFO -> 200`, mint 0.22 s; stats and achievements **reads** return 200. logfile.log has `GOG State. Signed in: True. Logged On: True.`, no authentication-failure line. Screenshot is still black; existing `GraphicsSettingsManager` / `Sequence contains no elements` fault (PLA-54) remains, not fixed here. |
| Hollow Knight (`app-367520`), `pla58-hk`, `first-frame+10` | JIT 2.49 s, first frame +9.45 s; screenshot shows the normal menu. No gameplay/performance measurement in this run. |

Both GOG runs have successful NDIS, IPv4/IPv6 unicast and forwarding-table
queries. Moonscars reports 35 interfaces, 7 IPv4 addresses, 35 IPv6 addresses,
24 IPv4 routes and 71 IPv6 routes. Monster Train's later snapshot reports 34
interfaces, 7/33 addresses and 24/66 routes. These are live OS snapshots, not
fabricated rows. IPv6 exceeds Wine's initial 64-row allocation in both runs:
`STATUS_BUFFER_OVERFLOW` is followed by a successful larger allocation/fill.
The `no adapter table … returning a LAN connection` message is absent, and the
code which produced that fallback is removed by wine-pe 0030. Successful sign-in
therefore no longer rests on wine-pe 0029's workaround.

No achievement/stat write request appears in either service log. No sign-out,
new gameplay, account-token search or performance measurement was performed;
credential-handling code was unchanged. Game logs containing the account's
Galaxy user ID stay only in the gitignored run directories.

## Limits

This does not add a service manager, an NSI device, change notifications, ICMP,
statistics requiring unavailable kernel structures, or complete neighbour tables.
Cached LUID identity follows Wine's index-based convention. Network changes are
observed on later enumerations, not pushed as notifications. No claim about
Mono `NetworkInterface`, netprofm as a whole, offline transitions, or a real i386
caller on the phone. IPv6 interface-table enumeration (distinct from the observed
IPv6 address/route tables) was corrected for Darwin scopes but not directly
exercised by these games' logs. The host mocks test dispatch/ABI validation,
not the OS's interface list or sysctl sandbox policy.

## Review follow-up (PLA-71, 2026-10-08)

Changes after review of `087a202`:

- **Cloned entries.** The route decoder skips `RTF_LLINFO` (ARP/ND) and
  `RTF_WASCLONED` (cloned host) messages, which Windows does not list as routes.
  The parent cloning route (`RTF_CLONING`) stays. Moonscars' IPv6 routes fall
  from 71 to 43; IPv4 stays at 24.
- **Denied routing sysctl.** `EPERM`/`EACCES` from `NET_RT_DUMP` now serves an
  empty route table and logs one line per family. `GetAdaptersAddresses` then
  still lists adapters and addresses, without gateways, instead of failing
  outright. Other errors stay `STATUS_NOT_SUPPORTED`. The phone does not deny the
  sysctl, so this path is reasoned, not exercised.
- **Retry exhaustion.** The second sysctl gets 25 % + 4 KiB slack. Three lost
  races now return `STATUS_NOT_SUPPORTED` (as a failed read), not
  `STATUS_BUFFER_OVERFLOW`. nsi.dll's `NsiAllocateAndGetTable` is bounded at five
  attempts either way.
- **Interface identity.** `if_entry_is_current` reads a `present` flag that each
  `update_if_table` snapshot refreshes, keyed by index *and* name. No
  `if_indextoname` syscall per lookup, so an update is no longer n² syscalls.
  A renamed index gets a new entry. Entries are never freed, because callers keep
  `if_unix_name` pointers; every lookup path (`find_entry_from_*`,
  `convert_*`, `ifinfo_enumerate_all`) skips absent ones.
- **Series.** wine-pe 0029 is dropped and 0030 no longer touches wininet. The
  built `wininet.dll` is byte-identical: only `libntdll_unix.a` and `winetest.exe`
  (it embeds tree commit IDs) changed in the records.
- **Not changed:** the i386 NSI path is still host-tested only.

Host: `test_nsi_ios` adds `RTF_LLINFO`/`RTF_WASCLONED`/`RTF_CLONING` decoder
cases; `pp test --quick` passes; the dev IPA passes all 80 checks.

Phone: dev IPA `3c754e0544da2f84f5614f26b08842b8a0ca514187beacc7d298eedbb748b5d3`,
upgraded in place, iPhone18,4 / iOS 27.0.

| Run under `$PLAYPORT_BUILD/ui-runs/` | Result |
| --- | --- |
| `20261008T011203` Moonscars, `first-frame+60` | JIT 2.39 s, first frame +5.47 s, title screen. `AUTH_INFO -> 200`; Player.log `OnAuthSuccess` and `GOG_SERVICES_CONNECTION_STATE_CONNECTED`, no failure. NDIS 35 interfaces, IPv4 7 addresses / 24 routes, IPv6 35 / 43; every table `status=0`. |
| `20261008T011339` Hollow Knight, `first-frame+10` | JIT 2.43 s, first frame +9.14 s, main menu. |
