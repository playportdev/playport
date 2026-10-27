# The Witcher 3 on the phone with the ARM64EC host answering AVX: its AVX fault is gone, its boot is still blocked (PLA-451, PLA-43)

**Linear:** [PLA-451](https://linear.app/playportdev/issue/PLA-451) (the iOS FEX host's AVX128 path);
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (The Witcher 3, Compatibility).
**Question:** with `patches/fex-port` 0064 giving the ARM64EC host `SupportsAVX`, does The Witcher 3's
installed 4.x payload get past the `vmovaps [rsp+0x50], xmm6` store that ended the previous launch 1 s
after game start, and does Hollow Knight still boot on the same IPA?
**Result:** the AVX answer is on the phone and it moved the fault: every FEX module now prints
`FEX: iOS host AVX=1`, there is no `Invalid instruction in entry block` and no
`[generated-fault-window]` line in either log, and the guest now faults 0x2005 bytes later in the same
module with an access violation instead of the illegal instruction. The title still ends 1.48 s after it
starts with `exit=0xc0000005` and no first frame, so PLA-43 stays **Broken**; its Best known stays the
classic 1.32 branch, which Steam's `install:` still cannot ask for (PLA-450). Hollow Knight booted again
with a first frame on the same IPA, so the change did not regress the runtime's known-good boot.

IPA: `.work/out/20261027-164801-097bb2cc/Playport-26.5-097bb2cc.ipa` (dev), sha256
`097bb2ccb5626a108524ad3a9861d84f15f21edc4489645c49032d1057bf4831`; built from superproject
`6068836` with the chunk-2a marker patch as local changes (that patch committed as `28a323c` during the
build), installed in place over `0107f809…` and recorded against checkout `833a172`
(`.work/install-runs/20261027-165336/summary.txt`, installed 2026-10-27 16:54:06, profile expires 2026-11-03
15:47). The logs themselves prove the installed IPA carries the change: both print `rev=ml538b` and
`AVX=1`, which the earlier IPAs never did.
Phone: iPhone18,4, iOS 27.0.1, `dev.playport.app`; `./pp phone status` before and after both report
`holder: null`, battery 80 % unplugged, 14443 MB free before and 14.3 GB after
(`.work/agent-notes/witcher3-avx/chunk2b-phone-status-before.txt`, `…-after.txt`). Runs:
`.work/ui-runs/avx-2026-10-27-witcher3-avx/hollow-knight` and
`.work/ui-runs/avx-2026-10-27-witcher3-avx/witcher-3`. Screenshots stay in those run directories: a
game's artwork is not ours to publish.

## What this proves and what it does not

It proves the installed IPA answers AVX for every FEX module on the phone, that Hollow Knight's known-good
boot survived the change, and that The Witcher 3's 4.x guest instruction is no longer rejected by the
decoder. It does **not** prove The Witcher 3 runs: it never reached a first frame, no person played it,
and nothing about its menu, input, rendering or saves was seen. It does not prove gameplay for Hollow
Knight either — that run stopped 10 s after its first frame. PLA-43's status and
`site/compatibility/games.json` stay unchanged by this record.

## The marker on both runs

Both runs print the same four lines per module group. The mask itself stayed at the boot sweep's
`32`/`288` (the `enableavx` experiment's IPA `4c65e2e7` printed `36`/`292`), so the mask does not
separate the builds: what separates them is the new `rev=ml538b` marker and the `FEX: iOS host AVX=`
line, which the previous IPAs printed nowhere (`iOS host AVX=` and `rev=ml538b` both appear 0 times in
`.work/ui-runs/regression-2026-10-27/27-witcher-3-play2` and in `.work/ui-runs/avx-2026-10-27/witcher-3-enableavx`,
whose marker still claims `DISABLEAVX expected`):

```
I 24 FEX: iOS host AVX=1 AFP=0 LRCPC2=0 RCPC=1 atomics=1 FlagM=1 FlagM2=1 FCMA=1 crypto=1 (FEX_HOSTFEATURES=32)
I 24 FEX: HostFeatures=32 (ml538b: the FEX_HOSTFEATURES mask only; the iOS host's AVX answer is on its "FEX: iOS host" line) rev=ml538b
I 68 FEX: iOS host AVX=1 AFP=0 LRCPC2=1 RCPC=1 atomics=1 FlagM=1 FlagM2=1 FCMA=1 crypto=1 (FEX_HOSTFEATURES=288)
```

`iOS host AVX=1` and `rev=ml538b` appear 4 times each in each new log — 4 FEX module groups, one per
tid — and `AVX=0`, `DISABLEAVX`, `Invalid instruction` and `generated-fault-window` appear 0 times in
either. The two previous 4.x Witcher 3 runs printed `Invalid instruction in entry block` twice and 1/4
`generated-fault-window` lines.

## Hollow Knight (app-367520) — the smoke run

`ok`, exit 0, `until_reached` at `first-frame+10`: surface ready +0.79 s, `jit: acquire(896 MiB) -> 0
after 3.04 s`, runtime started +5.25 s, game started +6.09 s, **first frame +11.80 s**. Self-check ok
(`pool=0x107f90000+896MiB rw=0x7008000000`), limits clean
(`wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0`), band and pool healthy at the stop
(`band: … free_mb=15013 … refused=0`, `pool: … room_mb=632 exhausted=none`), the controls sheet was
shown (`controls: shown (Gamepad, 60%, d-pad on, right stick below)`), `thermal: nominal at launch`,
and neither run reported a `crash-reports` event. Its faults are the JIT pool's known RW-alias writes
(`[fault_rip] … kr=2(PROTECTION_FAILURE) … region=0x70447c0000+0x4000`), the same ones the previous
IPA logged; the screen-stop screenshot is a lit, varied game image (1600x737, distinct thumbnail
colours 1712).

## The Witcher 3 (app-292030) — still blocked, not by AVX

`ok: false`, exit 1, `until_reached: false`. Surface ready +0.79 s, `jit: acquire(896 MiB) -> 0 after
3.73 s`, runtime started +5.84 s, game started +6.79 s, then
`session: title 3: ended, exit code c0000005 after 1480 ms` and `title: done nonce=c1a60145
exit=0xc0000005 after_s=1`. `bin\x64_dx12\witcher3.exe` mapped at `0x144470000` (read `0x567f600` of
`0x6402000`); limits clean; memory plan `the title needs 6246 MB … fits`; `thermal: nominal at launch`;
neither run reported a `crash-reports` event and the run's `crashes/` directory is empty; no `first frame`, no `[guest-window]`, no
`win-pos` line. The stop screenshot is a dark, low-detail frame (1600x737, distinct thumbnail colours
905) — no guest UI.

The guest fault, with the host-side detail FEX prints around it:

```
[fault_rip] cnt=3 rip=0x146c6493f pc=0x13eb7db64 addr=0x10 kr=1(INVALID_ADDRESS) entryprot=5 nowprot=5 region=0x1047b4000+0x4254000 [first] rev=ml555
[x86_live] State.RIP=0x146c6493f callret_sp=0x7ffc87cca0
0068:err:seh:segv_handler   [guest-exact] ml885 block=0x13eb7dad0 rip=0x146c5eff4 x86=48 8b 43 10 49 8d 3c 2b 44 8b 60 20 75 03 44 89
D 68 Exception: Code: C0000005 Address: 13EB7DB64 AV READ of 10
D 68 Exception: Code: C0000005 Address: 146C5EFF4 AV READ of 10
```

The guest RIP Wine raises on is `0x146c5eff4` = `witcher3.exe` RVA `0x27eeff4`, whose bytes
`48 8b 43 10` are `mov rax, [rbx+0x10]`; the register view carries `RBX=0x0`, so it is a read through a
null pointer, and FEX's `[store-noalias]` / `[av-detail]` lines agree: `addr=0x10 … NO pool/anon alias`
and `p0=READ p1=0x10 hostpc=0x13eb7db64 rcx=0x0`. FEX's own `[fault_rip]` RIP is `0x146c6493f`
(RVA `0x27f493f`).

Against the runs this replaces: the previous 4.x Witcher 3 launches on this phone died on the same
guest instruction. `.work/ui-runs/avx-2026-10-27/witcher-3-enableavx` (IPA `4c65e2e7`) printed
`E 68 Invalid instruction in entry block: 146858FEF` and
`[generated-fault-window] module=witcher3.exe rva=0x27e8fef type=0x1000000 protect=0x20 before=cc48895c24084889742410574883ec60 at=c5f829742450…`,
then `session: title 3: ended, exit code c000001d after 1319 ms`; the boot sweep's
`.work/ui-runs/regression-2026-10-27/27-witcher-3-play2` (IPA `0107f809`) printed the same
`rva=0x27e8fef` and `at=c5f829742450`, ending after 1269 ms. `c5 f8 29 74 24 50` is
`vmovaps [rsp+0x50], xmm6`, the first VEX store in `witcher3.exe`'s startup path. This run is 0x2005
bytes of guest code further on (RVA `0x27eeff4`), 161 ms later, and the instruction it dies on is a
load, not a VEX store.

Ruled out for PLA-43 by this run: the AVX/AVX128 decode absence (`AVX=1`, no invalid instruction, the VEX
store at `0x27e8fef` executed), and the `enableavx` launch switch being the only lever (the boot sweep
said it did not move the fault). Still open: the guest reaches a null pointer 0x2005 bytes into the same
startup path — the log's last actions before it are three failed `NtAllocateVirtualMemory` reservations
(`out of memory for allocation, base 0x0 size 1000000000`, `800000000`, `1f400000`) retried as
`[big-reserve]`, so the memory plan or the game's own huge reservations are the next candidate; and the
known PLA-446 JIT-pool dump fired again here too (`[mach_exc] UNHANDLED #1 pc=0x10b60305c addr=0x7047a30080`,
`DUMPED JIT pool RW alias (939524096 bytes)`). Neither was fixed in this run; the supervisor files them.

## Command shape

One `pp phone lock -- sh -c '…'` session for the install and the Hollow Knight smoke, the Witcher 3 play
in its own session, no settings touched, `--wait` left at its 1800 s default:

```sh
./pp phone lock -- sh -c '
  ./pp install --no-build
  ./pp ui --out .work/ui-runs/avx-2026-10-27-witcher3-avx/hollow-knight \
           --play app-367520 --until first-frame+10 --shot'   # exit 0
./pp ui --out .work/ui-runs/avx-2026-10-27-witcher3-avx/witcher-3 \
        --play app-292030 --until first-frame+10 --shot        # exit 1, 0xc0000005
```

`./pp secrets` and `./pp names` were clean before this record was committed.
