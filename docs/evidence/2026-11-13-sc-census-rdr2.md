# Social Club committed extents by kind: RDR2 on the forced 8 GB row (PLA-841)

**Run:** `$PLAYPORT_BUILD/ui-runs/pla841-rdr2-census5`, 2026-11-13, iPhone18,4, iOS 27.2.1.

**Settings:** the forced 8 GB row (`set:memoryLimitSimulatedMB=6144`, so planned G / V 6,144 / 2,048), with `donorPoolMB=auto`.

**The IPA:** dev `dfe718e2026efea491f4ca2e6cc235245602fcac1e7b9d5b85564301be9a7e46`, branch `dev/pla-835-m2-sc302-trial` at `b023be57`. It is M2 plus three changes:
- madeira-unix 0298 (PLA-865);
- the Social Club 2.4.0.302 single-process bridge (PLA-866, under decision 0150's proposed amendment);
- the 1.0.110.3150 bootstrap entries (PLA-851).

**Hollow Knight:** reached first-frame+10 on the same IPA (`trial-dfe7-hk`).

## The Play

1. **Layout:** "the Social Club layout is on: verified Rockstar bootstrap Red Dead Redemption 2 (Steam, installer 1.0.110.3150)".
2. **Helper:** `[sc-single] preflight: exact helper build and all SHA-256 ranges accepted`. It ran single-process, the only SocialClubHelper.exe of the Play.
3. **Launcher:** first window at +8.2 s. It signed in from the remembered session, then logged "Launching game..." about 70 s later.
4. **RDR2's own dialog:** RDR2.exe showed "Minimum Recommended Hardware Check Failure" (RAM). On this row the guest's RAM is 6,144 MB, under the game's minimum. OK through the pad dismissed it, and the first frame counted from then, at +379.7 s.
5. **Main menu:** at 59 FPS; Story was chosen and the save started loading.
6. **End:** the dev simulated limit ended the Play during Story's first load: "footprint 6165 MB reached the simulated limit of 6144 MB" (1,215 MB compressed). So the census has `peak` lines but no `exit` lines.

## Each kind's committed peak (last `[sc-census] peak` line)

| Kind | Real range | Committed peak | Highest committed end (offset) |
|---|---|---|---|
| 1 ELF (chrome_elf's pool) | 0x7800000000 + 4 GiB | 4 KiB | 0x5000 |
| 2 CEF (libcef's pool) | 0x7000000000 + 256 MiB | 4 KiB | 0x5000 |
| 3 ELF_META | 0x7400000000 + 6.25 GiB | 81.1 MiB (0x5113000) | 0x7b04000 |
| 4 CEF_META | 0x7590000000 + 1 GiB | 232 KiB | 0x7a04000 |
| 5 OILPAN (upper half) | 0x7c00000000 + 1 GiB | 96.1 MiB (0x6020000) | 0x6420000 |
| 6 CAGE | 0x7a00000000 + 8 GiB | 164.4 MiB (0xa46b000) | 0x100150000 |
| 7 ELF_META2 | — | no commit | — |
| code (V8's code range) | — | not found (V8 runs jitless) | — |
| jit-rw (the JIT pool's RW alias) | 0x7900000000 + 896 MiB | 678 MiB (tail 432 MiB) | 0xf69c000 |

Kinds 1 and 2 are nearly empty. With single-process, PartitionAlloc's large pools are reserved but barely used.

## H1: does libcef use ELF_META's address?

**Inconclusive by the census's own rule, though the evidence points to yes.**
- Every kind-3 commit with a caller names `libcef.dll+0x3c470bb`, at stack word 4.
- No kind-3 commit names `chrome_elf.dll`.
- The other kind-3 commits have `caller=?`.
- None has `word=0`, which the rule requires for "yes".

The four words above the call are not image addresses, so the attribution needs the frame at the call into `VirtualAlloc` to be certain.

## Oilpan's placement

Oilpan commits in **both** halves:
- **Upper half:** up to offset 0x6420000 of its real slot at 0x7c00000000.
- **Lower half:** 16 `[sc-layout] helper … commit 0x7a00000000+0x40000 … in Oilpan's reported lower half … (real slot kind=6)` lines. The lower half of its reported 32 GiB at 0x7800000000 lands in CAGE's real slot, kind 6.

## What this means for the 8 GB row

Under the forced row RDR2 passes the launcher, Social Club and the main menu. Since PLA-847, the simulated limit also ends the process at 6,144 MB, as iOS would on an 8 GB phone. RDR2's Story load passes that limit, so the row's 3-to-5-minute gameplay gate for RDR2 cannot pass on M2 as defined.
