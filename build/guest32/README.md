# 32-bit (i386) titles: host-side FEX build

The work toward 32-bit titles follows [the Portal 2 plan](../../docs/PORTAL2-PLAN.md).
Nothing here is shipped, and no 32-bit title runs yet.

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
and executes nothing. It is the base for the plan's step 4 coverage test, which
checks that every 32-bit guest memory access in the IR goes through the window
base.

The earlier software-checked memory, PE32 loader and simulator experiments are
retired by the plan. They are kept on the `portal2-guest32-experiment` branch.
