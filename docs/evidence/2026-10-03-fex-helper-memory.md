# Helper-owned FEX data backing: real game use

**Date:** 2026-10-03. Branch `research/extended-memory`, isolated worktree from
main `2f2240e`; follows the [4 GiB allocation proof](2026-10-03-helper-owned-memory.md).
**Measured IPA:** `Playport-26.5-ee58265b.ipa` (dev), SHA256
`ee58265b5fdbb728863d510586cb1b8748b0bec7c5181290aca42903022e57a2`.
iPhone18,4, iOS 27.0. Upgraded in place; no uninstall or container replacement.
Paths below are worktree-relative. Screenshots remain local.

## Usable interface and bounded scope

Settings › Developer › Memory → **Extra FEX RAM (experiment)** enables the
provider for the next Play. Default is off. The dev in-game menu reads and
shows the app and helper footprints. Settings' Probes can also read usage.
The workstation calls those UI capabilities with `set:helperOwnedFEXMemory`
and `probe:memory-status`, not a launch mode or runtime environment switch.

Madeira-unix 0049 adds an optional host hook for fixed anonymous RW mappings
in FEX's host data band `[0x7c00000000,0x8000000000)`. Only power-of-two
1–256 MiB requests with no extra mmap flags qualify. The broker obtains a
ledger-tagged anonymous memory object from the helper over XPC and maps it
at Wine's exact address without copy-on-write. Neither the helper nor the
app retains the transport handle after mapping; the app's VM mapping holds
the object. Wine's existing unmap/replacement lifetime therefore reclaims it.
The helper does not accumulate an array of runtime allocation handles.

The provider starts after JIT activation/detach, before Wine/FEX starts. It
never supplies JIT code, PE images, guest heaps, reserve-only or executable
mappings. The power-of-two constraint excludes FEX's guard-page-adjusted
stacks and hot call-return-stack resets. A rejected allocation uses ordinary
mmap. Each request is capped at 256 MiB, keeps 128 MiB helper headroom, and
has a three-second RPC timeout; transport failure disables future RPCs.
The broker and transport are excluded from release; release explicitly
rejects the hook and uses ordinary mmap. No new entitlement is used.

## Paired game runs

Same measured IPA, same game, same 20-second sample point after Play:

```sh
pp ui --expect-ipa SHA256 --action set:helperOwnedFEXMemory=false \
  --action play:app-367520 --action wait:20 --action probe:memory-status \
  --until first-frame+25 --shot --out .work/hk-memory-off-final
pp ui --expect-ipa SHA256 --action set:helperOwnedFEXMemory=true \
  --action play:app-367520 --action wait:20 --action probe:memory-status \
  --action menu:open --until first-frame+25 --shot --out .work/hk-memory-on-final
```

Both result events are `ok: true`. The off run reached first frame at 9.39 s;
the on run at 9.90 s. The on run continued beyond first-frame+10, opened the
in-game menu, and completed its actions normally. Its screenshot shows the
Hollow Knight game surface behind the menu and the measured footprints.

| At the explicit runtime report | Off | On |
| --- | ---: | ---: |
| App footprint | 2,401,671,976 B | 2,369,903,304 B |
| Helper footprint | no broker | 46,663,400 B |
| Successful mapping requests | none | 144 |
| Cumulative requested backing | none | 786 MiB |
| Refusals/fallbacks | none | 0 |

These logs are each run's `pull/s1-host.log`. The app-footprint difference
is **30.3 MiB**, not 786 MiB. Requested bytes are cumulative virtual backing,
not resident data, live bytes or extra physical RAM. The helper footprint
includes its ordinary roughly 8 MiB baseline. This is a modest useful
redistribution, not a large memory win for this title. One pair is not a
statistical performance or memory comparison.

## Gameplay, not just a launch surface

Under one phone-lock session, enabled the same UI setting, then ran:

```sh
pp perf --secs 100 --pad first-frame+25:hk-new-game \
  --shot first-frame+70 --no-hud --expect-ipa SHA256 \
  --out .work/hk-helper-gameplay
```

Result `ok: true`; first frame at 8.74 s; stopped normally after 100 seconds
beyond first frame. The scripted pad loaded the existing save. The screenshot
at first-frame+70 shows the Knight jumping beside the Dirtmouth bench, with
five masks and 19 geo. Runtime logs show real helper-backed FEX allocations;
the measured run remained alive throughout. The report counts 6,018 frames
in 102.9 seconds, mean 58.6 fps; thermal state stayed nominal. This mixed
startup/menu/gameplay average is not a controlled speed comparison.

## Final installed build confirmation

After adding the release-only rejecting stub, rebuilt dev IPA
`Playport-26.5-05971459.ipa`, SHA256
`0597145977ce4ee7770ef6fe8a9b79071fe2651eaabfab05ed19fb8af2d10905`,
verified all 71 checks, and upgraded the phone again. The original 64 MiB
full-buffer probe passed (`.work/device-memory-final-64`). The final code
also passed another Hollow Knight run with the experiment on
(`.work/hk-memory-final-ipa`): first frame at 8.87 s, sampled after 25 seconds
from Play, 148 mapping requests, 794 MiB cumulative requested backing,
helper footprint 54,871,784 B, zero fallbacks. It continued past
first-frame+10 and showed its measurements in the in-game menu. Both result
events were `ok: true`. This is the dev IPA left installed.

## Rejected first version and limitations

An initial wider size filter intercepted repeated 16 MiB-minus-16 KiB
call-return-stack clears, generating over 18,000 RPCs during a short launch.
The game survived, but that is not a suitable hot path. Those sizes are now
excluded. The final paired/gameplay runs above use the narrowed filter.

**Proved:** real game allocations backed by helper-owned anonymous RAM, an
opt-in UI and readable in-game measurements, successful launch and gameplay.
The prior allocation probe separately proves 4 GiB of incompressible data
verified in both processes without charging the app's footprint.

**Not proved:** aggregate resident use above 8 GiB, access to all phone RAM,
performance improvement, long-session stability, helper-loss recovery under
system pressure, or applicability to every game's allocator. Guest heaps
and GPU allocations are unchanged. System-wide memory pressure still
applies; do not add the two processes' RSS as though they were distinct RAM.

Checks: dev IPA verification passed all 71 checks; release `pp check` passed
and release IPA verification passed all 75 checks. Full `pp test` passed:
482 Python tests, host C tests (including pad ThreadSanitizer), and all three
host Swift package suites. The release-only rejecting hook stub was required
by the static linker. No dev allocation semantics changed between the
paired/gameplay IPA and the final confirmed IPA. Names and secrets gates passed.
