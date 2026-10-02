# Portal 2: raw scalar ARM emission gate

## Verdict

Real FEX native ARM emission preserves the independently checked scalar address,
width, direction, value and partial-register contract for 153 blocks / 19584
simulator inputs. Native CPU-state reads remain distinct from guest data
accesses. All 585 existing IR corruption controls, 38 new post-export controls
and three static-address upper-bit precondition experiments pass.

**Portal 2 remains unplayable.** This is a raw-emission baseline, **not a checked
memory emitter**. No runtime/app source, upstream patch, pin, IPA or build record
changes. **Not checked on the phone**; there is no device-run IPA SHA256. The
optional host audit adds no app entry point.

## Scope and method

`native_decode_audit.py --memory-simulate` implies `--memory-allocate`, separate
from all register-only modes. It retains the [allocated-memory gate's](2026-10-02-fex-allocated-memory-ir.md)
pre/post-RA inspections and checked C adapter tests. Native configuration,
ABI-neutral frontend byte-source seam and real dispatch lifecycle are unchanged.
The real Dispatcher, per-thread PassManager/LookupCache and Arm64JITCore now
emit the 17 scalar MOV/FNSTCW forms at three guest PCs and three host backing
granules. No FEX method is replaced. The nine FXCH graphs still check native
pointer provenance at IR level; **no FXCH ARM block executes** here.

The C++ exporter validates bounded entry/prologue/body/exit/tail/debug layouts,
then exports unmodified code, real static-register mapping, native context
slots and independent x86 results. The separate simulator independently
recomputes addresses and register/store results rather than accepting export
results alone. Unicorn 2.1.4 executes the complete entry prologue, scalar body
and initial unlinked exit thunk. Only the native linker literal is replaced
with a high capture address in a private copy; the real linker/dispatcher do
not execute. Simulator installation remains [hash pinned](../../build/guest32/arm_simulator_requirements.txt).

For each input:

- Base/displacement, scaled SIB, 16-bit truncation, absolute and wrapping FS
  effective addresses match independent x86 formulas, including null, page and
  top-of-space boundaries plus randomized states.
- Exactly one guest read/write has the expected byte/word/dword width. Loaded
  bytes are concrete little-endian sentinel data, not an IR-modeled load;
  stores use the expected low EAX bits or native FCW value. Partial AL/AX loads
  preserve other EAX bits, and all other guest GPRs remain unchanged.
- Native header publication, optional native FS/FCW reads and the exit-linker
  literal read are separately checked at high addresses. No native context
  pointer is mapped as guest memory or sent to g32.
- The exact instruction/access sequence, complete guest and CPU-state byte
  canaries, code bytes, STATE, SP and NZCV are checked. Exit PC, X0 and link
  register match the capture/thunk contract.

## Deliberate raw-emission limitations

Simulator data mappings are placed at the numeric guest address, **not at the
separated g32 backing**. They are disposable read/write mappings even where
g32 rejects access. A multi-byte access starting at `0xffffffff` gets a mapped
page above 4 GiB so its raw linear width can be observed. This is not correct
guest permission/overflow behavior: checked C adapter tests separately reject
it, but emitted code still does not consult that adapter. Host granules cover
decoder/IR fixture construction, not simulator VM granularity or translated
data permissions.

This confirms the unchecked baseline across the ARM boundary without claiming
it is usable on iOS. It does not prove translation, native/guest provenance
metadata in emitted code, faults or transactional rejection. No failure path
preservation can be inferred from private corrupted simulator executions.
The generic native x87 memory counterexample is retained but its emitted
vector accesses are deferred.

A newly observed emitter precondition is important for future helper entry and
return ABIs: direct base-only scalar memory operands use the native X register
holding EBX. They rely on its upper 32 bits already being zero. Poisoning those
bits in the base load, base store and FNSTCW store causes an unintended high
address and is rejected by the observer. Computed SIB/displacement/FS addresses
instead pass through W-register arithmetic. The normal audit therefore
zero-extends architectural guest GPR inputs, while poisoning temporary
registers. This is an explicit bounded precondition, not evidence that all
future bridge paths maintain it.

## Controls and validation

Private post-export controls cover wrong memory base, width, data register,
missing prologue publication, self-branch, BR instead of BLR, guest exit record
and altered oracle address/register output for a base load/store, FS load and
FNSTCW store. Native context-offset corruptions are also checked in the latter
two. All 38 controls fail for their intended reasons, separately from the three
upper-bit precondition experiments. Normal and unmapped data hooks are both
needed: an LDAR/STLR on a wrong unmapped base can fault before the ordinary
read/write hook fires.

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-simulate
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-simulate --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
./pp test --quick
```

Optimized and ASan/UBSan exporters pass, including repeated real backend/RA
construction. Sanitizers cover the audit, frontend and g32, not other FEX
archives or the simulator. Scalar pre/post-RA regressions, the 144-block / 18432
register-simulator regression and all quick host tests pass. Python syntax,
FEX-style clang-format, incompatible-mode rejection and git whitespace checks
pass. No background process was started; no commit was made in this iteration.

Source/archive hashes are printed by the runner. Frontend SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`;
simulator native-library SHA256 remains
`ddb196ec82b52e502c18e4a34478bf7b9f61c83c2ebaa95c74d8ded45a95da9c`.
Exports stay under `.work/guest32/separated-memory-emission/{optimized,sanitized}/`.
Validation logs are `.work/guest32/iteration26-{memory-emission,memory-emission-sanitized,memory-ra,memory-ir,register-simulate,quick}.log`.

## Next boundary

The next bounded gate must introduce a checked scalar helper/lowering ABI that
validates the complete guest width before reading/writing translated backing,
keeps native CPU-state pointers untouched, maintains zero-extended guest GPRs
and proves bytes/registers are preserved on rejection. Raw baseline emission
and modeled IR provenance cannot substitute for those requirements.

Other guest-memory families, auxiliary code readers, concurrent VM changes,
Wine i386/WoW64 marshalling, graphics/audio/input and Portal 2 menu/play/save/
reload remain unresolved. Real ARM64EC/iOS validation and a Hollow Knight phone
regression are still required. Any phone experiment must enter through the UI.
