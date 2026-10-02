# Helper-owned anonymous RAM: measured on the phone

**Date:** 2026-10-03. Branch `research/extended-memory`, from main `2f2240e`.
**IPA:** `Playport-26.5-48af86b2.ipa` (dev), SHA256
`48af86b2489057ea0d631e5cea3d8b22d8b5ba984fe5925a86c38e7cd0317faa`.
iPhone18,4, iOS 27.0, 11,734 MiB physical RAM. Installed in place; the container
and installed games were preserved. All paths below are worktree-relative.
The explicitly requested isolated worktree has its own reflinked run tree;
only the tool caches and the device lock/install record are shared.

## Mechanism, not attribution

This is Playport's own experiment, not a claim to have inspected another
emulator's unreleased implementation. The reported [multiprocess RAM
workaround](https://www.reddit.com/r/EmulationOniOS/comments/1wtcj5m/iosipados_ram_limit_workaround/)
was an investigation lead; direct access to the announcement was blocked.

[XNU's memory-entry implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_memory_entry.c)
provides the useful distinction:

- `mach_make_memory_entry_64` with `MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED`
  creates anonymous backing owned by the calling task.
- A memory object's Mach send right can cross XPC (`NSXPCCoder`,
  `xpc_dictionary_set_mach_send` / `copy_mach_send`). Its port number is not
  sent as an integer. The receiving task maps the same object with `vm_map`.
- The owner's ledger pays for dirty pages, even when the other task writes
  them. No private ownership-transfer or no-footprint entitlement is requested.
- As an authorization control, asking for `VM_LEDGER_FLAG_NO_FOOTPRINT` returned
  **8, KERN_NO_ACCESS**, on every run. Hiding the footprint is not this mechanism.

`app/Sources/SharedMemory` implements the capability transport, bounded
allocation, mapping and full-buffer deterministic verification. No disk file,
purgable allocation or lazy untouched reservation stands in for RAM. The
helper owns its objects until release. The app checks every byte, the helper
maps the same objects and checks every byte, then the app checks them again
five seconds later. SplitMix64-derived words avoid a compressible zero-fill test.
The developer UI and driver call the same probe; release excludes this experiment.

## Phone runs

```sh
pp ui --expect-ipa SHA256 --action probe:memory-64 --shot --out .work/device-memory-64
pp ui --expect-ipa SHA256 --action probe:memory-2048 --shot --out .work/device-memory-2048
pp ui --expect-ipa SHA256 --action probe:memory-4096 --shot --out .work/device-memory-4096
```

All three result events are `ok: true`. Their logs are in each directory's
`pull/s1-host.log`. Screenshots show Settings' Probes with the verified size.
The screenshots remain local, not published.

| Fully written and verified | App footprint immediately after writes | Helper footprint after verification | App RSS after retention |
| --- | ---: | ---: | ---: |
| 64 MiB | 35,178,480 B | 73,942,712 B | 264,830,976 B |
| 2,048 MiB | 37,522,904 B | 2,157,022,464 B | 2,299,215,872 B |
| 4,096 MiB | 39,113,688 B | 4,305,900,288 B | 4,477,730,816 B |

The exact same locally owned 64 MiB control increased the app's footprint from
29,771,688 B to 96,946,136 B in the 4 GiB run. Releasing it returned the footprint
to 29,394,856 B. So the low footprint is not a broken task-info reading.

During the 4 GiB run some shared pages briefly went through compression
(`TASK_VM_INFO.compressed` around 1 GiB), but full content verification still
passed in both processes. The final sampled object had 64 MiB resident and
dirty, zero swapped pages. After the helper verified all objects, its RSS was
4,391,649,280 B and compressed count 98,304 B. After the app's second full read,
its RSS was 4,477,730,816 B. RSS totals across mappings must not be added: both
processes see the same physical backing.

Releasing both sets of handles reclaimed the allocation: helper footprint
8,587,008 B, app footprint 59,820,064 B. Both readings include ordinary UI/XPC
activity, not an assertion of exact baseline equality.

The helper's available-plus-footprint limit was 6,442,450,944 B (6 GiB);
the app's settled limit was 8,589,934,592 B (8 GiB). The probe refuses a request
that would spend the helper's last 128 MiB, instead of deliberately triggering jetsam.

## Scope and checks

- **Proved:** a directly usable, zero-copy anonymous RAM capability whose
  backing is charged to the helper, with 4 GiB of real data verified on this
  non-jailbroken phone. App Groups and new private entitlements were unnecessary.
- **Not yet proved here:** a game's allocator using this backing, aggregate
  usage above 8 GiB, or access to all phone RAM. System-wide pressure still applies.
  This evidence does not claim a full-RAM unlock or independent verification of
  the reported emulator release.
- `pp check` dev and release passed; `pp build` passed all 71 IPA checks.
- `pp test --quick` passed (481 Python tests and all host C tests), with build,
  output and device overrides cleared for its temporary-repository fixtures.
- The isolated run rebuilt FEX from main's exact declared series after a copied
  tree's extra research commits failed notice provenance. Its changed artifact
  hash is committed with this experiment; no pin or FEX patch changed.
