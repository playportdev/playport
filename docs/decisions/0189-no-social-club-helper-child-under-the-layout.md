# 0189: No Social Club helper child under the layout

**Status:** accepted by the owner, 2026-11-13: "we had it before and we still need it". Built ahead of acceptance by
[PLA-865](https://linear.app/playportdev/issue/PLA-865) (madeira-unix 0298, commit `dddd51be`). Amends
[0150](0150-dev-single-process-social-club.md)'s child policy ("Other executables and unverified helper
children keep today's policy") and [0169](0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md)'s
multi-process fallback, both under the Social Club layout only. The policy text PLA-865 first wrote into
0150 and 0169 as amendments of 2026-11-13 is this record's; those records point here.

## Context

- **The layout holds one CEF process's pools.** Under it ([0169](0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md),
  as built by madeira-unix 0299) the router gives the verified helper's PartitionAlloc pools, metadata,
  Oilpan and V8's cage their slots, and a second helper cannot take the first one's. A child's 32 GiB
  PartitionAlloc ask is refused, and its chrome_elf traps.
- **0150 refused only a verified helper's children.** A helper the guard does not verify ran
  multi-process, its children included. With Social Club 2.4.0.302, a build the guard does not verify
  ([PLA-866](https://linear.app/playportdev/issue/PLA-866)), the multi-process browser started its
  storage service 1,237 times in 90 s, each child dying as above, and the dead children's memory ended
  the Play (`$PLAYPORT_BUILD/ui-runs/pla841-rdr2-census4`).

## Decision

- **Under the Social Club layout every `SocialClubHelper.exe` child started with `--type=` is refused**
  at `NtCreateUserProcess` with `STATUS_ACCESS_DENIED` (madeira-unix 0298), whether or not the helper is
  verified and whether or not single-process is on. So under the layout the multi-process fallback runs
  a browser with no child.
- **The refusals are logged and counted**: the first four, then every 256th
  (`[sc-layout] refusing helper --type= child #N`), the count kept atomically.
- **Without the layout nothing changes**: 0150's policy stands (a verified helper's `--type=` children
  are refused when it runs single-process; other executables and other children as before).

## Costs and risks

- **A helper the guard does not verify gets no renderer, GPU or storage process under the layout.** What
  Social Club shows then has not been measured; until its build is verified (PLA-866) it may show no page.
- **Not yet seen on the phone.** `$PLAYPORT_BUILD/ui-runs/pla841-rdr2-census5` ran an IPA with 0298, but
  its helper ran single-process (the PLA-866 trial bridge) and started no child, so nothing was refused.
  The refusal and its log cadence are proven by `tools/tests/test_sc_child.py`, which compiles
  `pp_sc_child.h` from the patch; a phone run of an unverified helper under the layout is owed.
