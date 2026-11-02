# 32-bit (i386) titles: host-side FEX audits

32-bit titles run as WoW64 children of the session root through a 4 GiB guest
window, with FEX's `xtajit.dll` translating each memory access inline as
`B + zext32(EA)` ([decision 0047](../../docs/decisions/0047-i386-titles-on-vulkan.md)).
The two audits here check that translation on the workstation. Nothing in this
directory is shipped.

## Native FEX build (host audit only)

fex 0012–0014 let a series-applied FEX tree build natively on the workstation
with FEX's allocator disabled. Configure the build as in
[the allocator evidence](../../docs/evidence/2026-10-01-fex-native-allocator.md),
then run:

```sh
python3 build/guest32/native_link_audit.py .work/guest32/decode-audit/native
```

The audit constructs and destroys a real `ContextImpl` and links the real
FEXCore, FEXCore_Base, JemallocDummy, cephes and softfloat
([link evidence](../../docs/evidence/2026-10-01-fex-native-context.md)). It decodes
and executes nothing.

## Window coverage

```sh
python3 build/guest32/window_coverage_audit.py .work/guest32/decode-audit/native
```

`window_corpus.s` lists i386 instructions that access memory (every address
form, stack, string, locked, x87, MMX/SSE, state save, prefetch). The audit
assembles them with `llvm-mc`, translates each one in 32-bit mode with a window
base set (the real frontend, dispatcher and FEX's default passes, including
register allocation; nothing is emitted or run) and requires every guest load,
store, atomic and string op to address the window: `[B, wEA, uxtw]` or
`B + zext32(EA)`. It runs four configurations (TSO on and off, full SMC checks,
reduced-precision x87), then a control without a window that must be rejected
([evidence](../../docs/evidence/2026-10-04-portal2-inline-translation.md)).

The earlier software-checked memory, PE32 loader and simulator experiments were
replaced by the inline translation. They are kept on the `portal2-guest32-experiment` branch.
