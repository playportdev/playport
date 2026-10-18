# Rockstar launcher's generated FEX exception (PLA-401)

**Linear:** https://linear.app/playportdev/issue/PLA-401

## Existing observation

The preceding [Steam bridge round 4](2026-10-18-steam-bridge-rdr2.md) used IPA
`7f0caa62f5825054dd1f6549109e4e975e01dbf4eefe7ed58b4286c9a74ae06f`,
RDR2 run `.work/ui-runs/20261018T114545`. After sign-in, the launcher ended
on `0xc0000096`. No authentication input was supplied by this worker.

Public FEX source explains the fault mechanism, not yet the root cause:

- `FEXCore/Source/Interface/Core/JIT/MiscOps.cpp`, `Break`: stores the
  generated fault's signal, trap and error in `SynchronousFaultData`.
- `FEXCore/Source/Interface/Core/Dispatcher/Dispatcher.cpp`,
  `GuestSignal_SIGSEGV`: spills registers and deliberately loads from zero.
  This matches the host fault sequence in the existing log.
- `Source/Windows/ARM64EC/Module.cpp`, `RethrowGuestException`: reconstructs
  guest context and calls `Source/Windows/Common/Exception.h`,
  `HandleGuestException`. Generated SIGSEGV/#GP with a non-IDT error maps to
  `EXCEPTION_PRIV_INSTRUCTION`. The initial host null read alone does not
  establish a guest null dereference or a translator defect.
- The public translator's candidates are `PermissionRestrictedOp` and
  `INTOp`. Existing logs do not identify the selected producer.

## Bounded diagnostic scope

Supervisor approved implementation telemetry only: record the FEX handler
already selected by normal translation, generated fault fields, and deliberate
fault provenance. No extra decoder pass, guest bytes, instruction listing,
closed-binary analysis, or tracing of surrounding guest code. No privilege,
authentication or protection check is suppressed.

FEX patch 0048 carries a diagnostic producer tag through Break IR into the
former two padding bytes of the eight-byte synchronous fault record. On iOS,
the ARM64EC exception path logs at most 16 generated faults per process.
The signal, trap, error, conversion and delivery are unchanged. This is a
diagnostic, not a crash fix. Existing detach patch 0047 remains intact.

## Diagnostic round 1

IPA: `32b9122003bd05ec6cea991e661b7e4ae0fca49c76f104f8ca21e315aca4a08e`.
`./pp build` passed 89/89 IPA checks. `./pp test --quick` passed (646 Python
tests and the host C suites), as did `./pp names` and `./pp secrets`.
The build also checks the fault record remains eight bytes and its diagnostic
tag occupies only the former padding at offset six. No standalone functional
regression test was added: no behavior fix is established.

One `pp phone lock` session installed this IPA, ran Hollow Knight, restored
RDR2's compatibility defaults for the session, then launched RDR2. The script
uses `set -eu` and exact-IPA checks; every command succeeded. The UI driver's
success means the observation interval completed, **not that RDR2 worked**.
Unattended mode was enabled; the preflight showed 80% charge, external power,
and 6.2 GB free. No authentication input or gameplay input was supplied.

| Game | Run under `.work/ui-runs/` | Observation |
| --- | --- | --- |
| Hollow Knight (367520) | `20261018T120512` | First frame +10.09 s, first-frame+10 reached; no generated-fault telemetry |
| RDR2 (1174180) | `20261018T120626` | Vulkan/client, first window +28.13 s, observed through first window+240; launcher still terminates with `0xc0000096` |

RDR2 screenshots: 45 s shows Connecting to Rockstar Games Services; 60 s shows
the launcher's patterned loading window; 90, 150 and 240 s show PlayRDR2's
Unable to launch game dialog. Screenshots remain in the run directory.
No new launcher-log pull was made, so this round does not independently date
or confirm the authentication transition from the launcher's own log.

The single generated-fault line in RDR2's host log (line 61789) reports:

```text
producer=INTOp generated=1 signal=11 trap=13 si_code=128 error=0x0
```

The private guest address is omitted here. Lines 61792–61797 show conversion
to `c0000096` and unhandled delivery. The observed fields match the deliberate
#GP producer in public `OpcodeDispatcher.cpp:4970–4975`, not
`PermissionRestrictedOp`. `Common/Exception.h:40–73` maps this record to the
reported exception. This establishes FEX's chosen path and consistent
conversion, **not why the application reached it**, nor that the translator's
input or guest control flow was correct. No instruction was reconstructed from
the closed executable. No exception should be suppressed on this evidence.

Pool: 29 MiB room, no head exhaustion, tail refusal or fatal; band peak
15,176 MiB, zero refusals. No pool or allocator changes were made.

## Blocker and possible next evidence

PLA-401 remains unresolved. The supervisor approved stopping after this round:
there is no demonstrated semantic defect or missing Steam contract that would
justify changing behavior. More identical phone rounds would not explain why
the application enters this path. Any next fix needs a causal public-source or
log contract failure, or a self-owned reproducer of an exception-delivery bug.

The two logged unserved calls were checked against the pinned public SDK using
`build/steamclient-vtables.py`'s MSVC layout probe in scratch:
`SteamInput006` slot 3 is `void RunFrame(bool)`, and `SteamController008` slot 2
is `void RunFrame()`. Therefore the shim's generic "answers 0" line does not
establish a failed boolean return for these calls. Their missing input-state
updates are only a hypothesis, with no demonstrated causal link to the crash.
UserStats012 had no logged method call. Do not implement these interfaces merely
because the names appeared in this run.

A future scoped investigation could correlate the launcher's own diagnostic log
with Wine API failures before the generated fault, without inspecting its code,
and only implement a public contract supported by that evidence. It was not
started here. Authentication is not a proposed workaround.

Keeping patch 0048 while this issue is unresolved is useful: it distinguishes
translator-generated exceptions from genuine host memory faults without
altering their delivery. It adds no decoder pass or guest-code logging and
uses existing fault-record storage. The added iOS exception log is capped at
16 records per process; ordinary translated instructions have no added log.
It is diagnostic infrastructure, not a compatibility fix or release sign-off.
Private logs and addresses stay under `.work/agent-notes/pla401/` and the UI
run directories. RDR2's compatibility status remains Broken.

## The faulting instruction (fex 0049) and an SMC A/B

On 2026-10-18 the owner authorized logging a bounded guest code window at the
fault: 16 bytes on each side of the rip, for the first four generated faults
per process, with the module and RVA. FEX patch 0049 logs these together with
the region's type and protection. It reads the bytes with
`NtReadVirtualMemory` on its own process. On iOS that call is
`mach_vm_read_overwrite`, so an unreadable page fails the read instead of
faulting. Exception semantics are unchanged. The raw bytes and addresses are
kept only in the private run logs.

IPA `2041ad28a1563305b615f40cdf257d87be1c35ac1ee51bddc818e3f83039cbf3`.
`./pp test --quick`, `./pp names` and `./pp secrets` passed, and `./pp build`
passed 89/89. The phone was at 37% and then 34%, not charging, with
6.0 GB free. Both sessions ran with `set -eu` and exact-IPA checks and exited 0.
No authentication or game input was supplied.

**From source alone, the instruction is HLT.** `INTOp`'s generated #GP has
error 0 only for HLT (`0xF4`). `INT imm8` sets the error to `imm << 3 | 2`,
which is never 0. INTO, INT1, INT3 and UD2 use other traps or signals.

| Game | Run under `.work/ui-runs/` | Observation |
| --- | --- | --- |
| Hollow Knight (367520) | `20261018T192202` | First frame +10.19 s, first-frame+10 reached |
| RDR2 (1174180), default `FEX_SMCCHECKS=none` | `20261018T192315` | First window +28.15 s; the 90 s screenshot shows Unable to launch game; `c0000096` |
| Hollow Knight (367520) | `20261018T193044` | first-frame+10 reached |
| RDR2 (1174180), session-only `env.FEX_SMCCHECKS=mtrack` | `20261018T193203` | First window +62.92 s; no main window by +240 s; pool head exhausted; **inconclusive** |

### The code window in the default run

The fault is in `Launcher.exe` at RVA `0x258cf6`. The same RVA appears in run
`20261018T190814`, where the image was loaded at a different base.

- The region is `MEM_IMAGE` with protection `PAGE_EXECUTE_WRITECOPY` (`0x80`),
  which is a writable code page.
- The byte at the rip, in current memory, is `F4` (HLT). FEX's translation
  therefore matches memory at the rip: this is not a stale or mis-synced
  decode of the faulting instruction.
- The bytes before it decode as the tail of a function: `sete al; ret`, then
  `mov al, 1; ret`.
- After the HLT come filler bytes that are not `int3`. The next 16-byte-aligned
  function starts at RVA `0x258d00`.
- So the HLT sits in a gap between two functions. Execution can reach it only
  by a control transfer into the gap; it cannot fall through into it.

### SMC A/B

The A/B used one session-only setting:
`--settings 'app-1174180:{"runtime":"env.FEX_SMCCHECKS=mtrack"}'`. The game's
key replaces the launcher's (decision 0115), and the run did not use
`--keep-settings`. The log shows `environment FEX_SMCCHECKS=mtrack`, and every
emulated thread's invalidation census reports `smc_off=0`, Launcher.exe's
main thread among them.

**What the A/B showed:**
- **Self-modifying code in Launcher.exe.** FEX handled 83 self-modifying-code
  writes from Launcher.exe's main thread. All of them land on pages of its own
  image, about 27 distinct 16 KiB pages between RVA `0x1c000` and `0x1f3f024`.
  They show that the launcher writes, at run time, to image pages from which
  FEX had already translated code. With `none`, FEX ignores such writes. The
  page granularity means the written bytes need not be code themselves.
- **Run outcome.**
  - No generated fault and no `c0000096` occurred.
  - However, the main window never appeared. The first window came at +62.92 s
    (28 s with `none`) and was then hidden. The screenshots at 90, 150 and
    240 s are black.
  - About 19 s after the first window, the pool head ran out: head 416 MiB,
    tail 481 MiB, room 0, `head_exhausted=75`, `exhausted=head`.
  - After that, a Social Club helper ended with `c0000135` when a DLL load
    failed with `c0000017`, and `rpcss.exe` ended with `c0000017`.
  - Band peak was 11,313 MiB with zero refusals.
- **Not a result.** The run never reached the point where the default run
  faults, which is about 0.3 s after the main window. Under the pool rule set
  for this A/B, it is inconclusive.

### Status

- **Shown:** the fault is a genuine HLT that the launcher reaches through a
  control transfer into a gap between functions. Launcher.exe also modifies
  its own image's code pages at run time.
- **Not shown:** whether stale translations under `FEX_SMCCHECKS=none` send
  control into the gap, or whether the launcher deliberately jumps there.
  Proving the first needs a launcher run with SMC tracking that reaches the
  main window inside the pool.
- **Unchanged:** the default (`none`, decision 0116), every pool setting and
  the exception path. RDR2 stays Broken.
