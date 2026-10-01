# Kingdom Come: Deliverance under the 8 GB limit: the JIT pool, not the game's budgets

**Date:** 2026-10-01. **Phone:** iPhone18,4, iOS 27.0, limit 8,192 MB with
Game Mode. **Branch:** `kcd`. **Title:** Kingdom Come: Deliverance (Steam
app 379430), at its lowest settings: every `sys_spec_*` is 1 and HD textures
are off (the profile's `attributes.xml`), "Machine class 1".
**Decision:** [0036](../decisions/0036-one-512-mib-jit-pool.md).

## Where it stood

After [the system environment fix](2026-10-01-kcd-system-environment.md) the
game plays, but it runs at the limit.

- **A person played it** (IPA `dae42043…`, 896 MiB pool). The footprint
  peaked at 8,038 MB and the Metal HUD showed 230 MB available.
- **The next play** (`madeira.cfg inproc-sync = 1`, 896 MiB pool) was killed
  by jetsam while loading the save in Rattay. The log stops mid-line at
  `fpMB=8080`; there is no crash report and no exit line.

At that load the footprint was:

| part | size |
|---|---|
| the game's heap (the guest band) | 4.2 to 4.5 GB |
| Metal (`currentAllocatedSize`) | about 1.4 GB: textures 1.2 GB, buffers 0.6 GB |
| the JIT pool, dirty in full from the bless | 896 MiB |
| FEX's code cache, Wine and the host | about 1 GB |

## 1. Telling the game less does not shrink it

These runs used the dev build's new *Runtime keys* row (Game options ›
Developer; the driver's `--settings 'ID:{"runtime":"..."}'`). It writes
madeira.cfg keys over the game's own. Run mem-a set `vram-mb=1024
totalphys=6144`:

- **The game read both.** `kcd.log` shows `6144MB physical memory installed`
  and `Dedicated video memory: 1024 MB`.
- **It did not shrink.** Its heap stayed at 4.5 GB and its textures reached
  1.79 GB live, past the 1,024 MB budget. The peak footprint was 8,156 MB,
  higher than before.
- **It reads the budget once** (`ml1075 ... 1 queries so far`), so the
  runtime's dynamic trim (ml1075) never takes effect.

## 2. A 512 MiB pool gives back 384 MB

All runs: `.work/kcd/drive.sh`, which skips the intros with the pad,
Continues the same save, walks with `tools/pad/kcd-walk` and pulls the log.
Peak `fpMB` is from the runtime's `[xp]` lines.

| run | pool | runtime keys | peak footprint | pool use |
|---|---|---|---|---|
| (a person's play) | 896 | none | 8,038 MB | head 182, tail 161 |
| (killed) | 896 | inproc-sync=1 | 8,080 MB, then killed | head 182, tail 161 |
| mem-a, 60 s walk | 896 | vram-mb=1024 totalphys=6144 | 8,156 MB | |
| mem-b, 60 s walk | 512 (`jitPoolSimulatedMB`) | none | 7,787 MB | head 182, tail 161, room 170 |
| mem-c, 240 s walk | 512 (the default after 0036) | none | 8,014 MB | head 182, tail 161, room 170 |

In mem-c the footprint was 7.7 GB when the load ended, then climbed while
Henry walked Rattay's streets: 7,765 MB at +173 s, 7,900 at +272 s, 7,967
at +371 s. The game was still running when the run ended it.

## Result

- **The pool is the one lever that works** without changing the game. At
  512 MiB Kingdom Come loads Rattay and keeps playing. The pool still had
  170 MiB of room, and FEX was granted its 128 MiB code buffer.
- **The margin is thin.** It is about 200 MB after four minutes of walking,
  and still falling. A longer play, or a busier part of the map, may still
  be killed. The next savings would come from the runtime's other ~1 GB,
  or from Metal's copies of the game's textures.

IPA (dev, mem-c): `Playport-26.5-66ded8cf.ipa`, sha256
`66ded8cf1380e535e6c77e2ec7f62974d20d7e16ac03e145567f8a40db1607fc`.
