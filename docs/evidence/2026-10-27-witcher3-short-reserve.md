# The Witcher 3 4.x reaches a first frame on short reservations and a KosmicKrisp buffer-view guard (PLA-452, PLA-43)

**Linear:** [PLA-452](https://linear.app/playportdev/issue/PLA-452) (the 64/32 GiB reservations);
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (The Witcher 3, Compatibility);
[PLA-451](https://linear.app/playportdev/issue/PLA-451) (AVX128, the branch this builds on).
**Question:** the installed 4.x Remastered payload (Steam build 25773555, `bin\x64_dx12\witcher3.exe`)
died 1.48 s in, in its own `PoolOOMHandlerBreak`, after Wine refused its unhinted 64 GiB and 32 GiB
`MEM_RESERVE` asks (no gap that size in the task's 64 GiB usable window;
[2026-10-27-witcher3-avx.md](2026-10-27-witcher3-avx.md)). Is that refusal what stops it, and what
stops it next?
**Result:** the refusal was causal. Granted as *short reservations* (a real prefix, the full size
reported), the title runs on. With two further fixes found on the way, it reaches its **first frame at
+23.20 s**: the opening cinematic, rendering through vkd3d-proton and KosmicKrisp, and was stopped
10 s later by the run bound. Hollow Knight's first frame came at +10.91 s on the same IPA. Nobody played
either game: PLA-43 stays **Playable with issues** on the classic 1.32 branch's play, and
`site/compatibility/games.json` is unchanged.

Phone: iPhone18,4, iOS 27.0.1, `dev.playport.app`, battery 73–80 % unplugged, ~14 GB free; each IPA
installed in place (`pp install --no-build`) inside one `pp phone lock` session with both plays. The
Witcher 3's runs set its Runtime keys to `jumbo-mb=0 short-reserve-mb=6144` through
`pp ui --settings` (undone at the app's next launch outside the session); Hollow Knight ran on page
defaults. Screenshots stay in the run directories under `.work/ui-runs/pla452-2026-10-27/`: a game's
artwork is not ours to publish.

## The change

- `patches/madeira-unix/0222` (Wine unix, `Class: feature`): with madeira.cfg `short-reserve-mb = N`,
  an unhinted reserve-only ask that the kernel pick, the cage and the jumbo hold cannot place gets a
  view of N MiB plus a 256 MiB guard, top-down in `[0x7400000000, 0x7c00000000)` (else anywhere), and
  the caller is told it got its full size. Commits within the real part are served. Commits in the
  guard, or where no view is inside the claim, get `STATUS_NO_MEMORY`, a full pool's failure. Each event
  is logged as `[short-reserve]`. Off without the key. Pure rules in `pp_short_reserve.h`, host test
  `tools/tests/test_short_reserve.py`.
- `jumbo-mb=0` drops everyGame's 8,960 MB hold (sized for RDR2, an ask this title never makes), so both
  6.25 GiB grants fit in the 16 GiB slot above the game's own 16 GiB pool.
- `patches/mesa/0126` (KosmicKrisp, `Class: upstream-bug`): `kk_CreateBufferView` refuses a format that
  has no texel-buffer entry with `VK_ERROR_FORMAT_NOT_SUPPORTED`, and logs it as `[kk-bufview]`. Before
  this it read the NULL entry.

The static basis is `witcher3.exe`'s red::memory, read from the binary pulled from the phone. Its pools
hand out memory by bumping a cursor up from their base (`0x1427f3240`), and they accept a failed
reserve silently (flag bit 0x100), leaving an empty range that fails the pool's first allocation.

## The three runs

| Run | IPA (sha256) | Outcome |
| --- | --- | --- |
| `witcher-3-short` | `9f51b7be90686cbeac3fecaada838d62ff57a7c50724851bc69ab6ecf91b6e2f` | Both asks granted bottom-up (64 GiB at `0x77ffff0000`, 32 GiB at `0x798fff0000`). It reached vkd3d-proton device creation, then `exit=0xc0000005` at 6 s. |
| `witcher-3-short2` | `45d0678d04b550a5cea4712676e4466780d6890488739e51553c308658cb193f` | Grants top-down (64 GiB at `0x7a70000000`, 32 GiB below at `0x78e0000000`). It ran 22 s with 57 threads, then a SEGV in `kk_CreateBufferView+0x50` → `exit=0x3`. Hollow Knight (`hk-smoke`): first frame +10.13 s. |
| `witcher-3-short3` | `58dded057c7c11f3b5b905329685589170c5dab7450b70ed6f3263f035cd82a0` | **First frame +23.20 s**, `until_reached: true`. Hollow Knight (`hk-smoke3`): first frame +10.91 s. |

**Run 1's fault was the placement.** The phone loads the image +0x80000 above the file's VAs, and every
logged return address matches a call site at −0x80000. The crash was a NULL unlink in a TLSF free list
(`0x1427f89c0`, reached from the game's general free `0x140bcaa70` → `0x1427e72f0` → `0x1427f8cf0`).
- `0x140bcaa70` picks the pool **by address range, first match**: registry+0xc900's pool, then the
  64 GiB pool, and anything else goes to the 32 GiB pool.
- Placed bottom-up, the 32 GiB grant sat inside the 64 GiB grant's claimed range, so a block of it was
  freed into the 64 GiB pool.
- Placing grants top-down puts each later grant below the earlier ones. The earlier pools' claims, which
  are checked first, then never cover it.

**Run 2's fault was the driver.** vkd3d-proton's `vkd3d_create_vk_buffer_view` passes D3D12's typed
format through unchecked. In run 3 the guard named the one format:
`[kk-bufview] refused VkFormat 106 (PIPE_FORMAT_R32G32B32_FLOAT): no texel buffer format; offset=262144
range=12288 elements=1024 buffer usage=0x21bff features=0x40`. That is a vertex-buffer-only format:
Metal has no 96-bit texture format. It was refused once and the game went on.

**Memory in run 3.**
- The 64 GiB pool took its 1 GiB initial commit at +0.
- The 32 GiB pool's logged commits rose linearly to +77 MB.
- No `[short-reserve] REFUSED` line.
- At the first frame the FEX band held 2,995 MB (76 threads, `refused=0`), and the JIT pool was not
  exhausted.
- The footprint peaked at 4,184 MB phys (`[footprint] rev=ml358`).

## What this proves and what it does not

It proves that the refused 64/32 GiB reservations were what ended the 4.x build at 1.48 s, that a 6 GiB
prefix of each is enough to reach the opening cinematic, and that Hollow Knight still boots with both
patches.

It does **not** prove:
- that the title is playable;
- that 6 GiB is enough past the cinematic (a deeper commit would be refused and end in the game's OOM
  handler);
- that the missing `R32G32B32_FLOAT` texel view does not cost a visible effect;
- anything about input, saves, frame rate or the menu.

Not checked: how the game reacts to `VirtualQuery` on a short grant, which reports the real size; and
whether any other range-dispatch in the game checks the 64 GiB claim before the 500 MiB pool steered
into the FEX band, which that claim covers.
