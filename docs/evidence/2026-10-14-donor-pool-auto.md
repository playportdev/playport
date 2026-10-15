# Donor pool: Auto sizing from P − L, and the JIT helper's own entitlement

**Date:** 2026-10-14. **Branch:** `research/extended-memory`.
**Linear:** [PLA-351](https://linear.app/playportdev/issue/PLA-351) (under
[PLA-216](https://linear.app/playportdev/issue/PLA-216)).
**Plan:** [donor memory](../plans/2026-10-12-donor-memory.md), queue item 2.
The owner was away and the phone was in unattended mode; where there was a choice, the
conservative option was taken (listed under "Choices").

**Setup:**

- iPhone18,4, iOS 27.0.1, 11,734 MiB physical RAM, on battery (40 % → 38 %).
- IPA `Playport-26.5-d2c62e6c.ipa`, SHA256
  `d2c62e6c2652ce7e4c4d738581746221075734f3000a0bb7aec384b56fd5dbf4` (commit `da6fe62`),
  installed with `pp install --no-build`.
- Session scripts, their logs and run directories are under
  `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/pla351/`; the runs are
  `$PLAYPORT_BUILD/ui-runs/20261014T231558` (the first settings shot),
  `20261014T231644` (Hollow Knight) and `20261014T231822` (the settings shot). Each session
  ran as one `pp phone lock -- sh`.

## 1. The helper's entitlements (host, no phone)

Read from the signature of the newest verified IPA before this work (`b3cdca61…`, the one
measured at 6,137 MiB), with `build/verify-ipa.py`'s own `macho`, `signature` and
`cms_content`. Values that identify the team are left out.

| Code | Entitlements in its signature |
|---|---|
| `S1Probe` (the app) | application-identifier, `com.apple.developer.kernel.increased-memory-limit` = true, team-identifier, get-task-allow = true, keychain-access-groups |
| `PlugIns/PlayportJIT.appex` | the same five keys, with `increased-memory-limit` = true |
| `PlayportJIT.appex/Frameworks/StikJIT.framework` | an empty entitlements blob |

- The appex's own `embedded.mobileprovision` grants `increased-memory-limit` as well.
- The patched xtool (`build/toolchain/xtool-1.20.1-increased-memory-limit.diff`) signs the
  extension with the capability, although `xtool.yml` names `entitlementsPath` only for the
  app.
- **So the helper is entitled.** Its 6,137 MiB (6,139 MiB in this run) matches the app's
  entitled limit before Game Mode.
- The helper's limit is therefore not shown to come from the `com.apple.ar.viewer`
  extension point's class. This IPA cannot tell the two causes apart: that needs an appex
  signed without the entitlement.
- `verify-ipa.py` does not check the appex's entitlements: it checks only the code
  directories of the appex and the framework.
- **Nothing was changed in signing.** The appex entitlement is a policy matter.
  Recommendation, not applied:
  - `verify-ipa.py` should print the appex's entitlements, and check that they carry
    `increased-memory-limit`. The donors depend on it: a signer that drops it from the
    appex but keeps it on the app would leave the pool to an unmeasured limit.
  - Do this only if the owner wants the donor pool to depend on it.

## 2. Auto sizing

`PlayportKit/DonorPoolSizing.swift` (pure), used by `Dev/DonorPool.swift` at Play, after the
JIT activation:

- **L** = the app's `os_proc_available_memory()` + footprint, read at the pool's install
  (several seconds after Play: the check before Play waits for Game Mode only when it would
  refuse).
- **P** = `(memorystatus_level − 15) % × hw.memsize` + footprint.
- **Target** = `min(6144, round256 down(P − L + 512 MiB), the level's room)`.
- **Off** when `P − L` < 1 GiB, when the phone has under 7 GiB of RAM (the Settings row is
  then hidden), or when the limit or level cannot be read.
- **Off** when the first donor has under 1 GiB available.
- **Spare floor:** `max(768 MiB, 12 % × RAM)`, which is 1,408 MiB here (it was 1,536).
  - It is now checked before every round and object at Play as well.
  - The fixed sizes keep their level cap and also get the spare and donor checks.
- **Settings › Developer › Donor pool:** Off, Auto, and 2.0/4.0/6.0 GB (fixed), all
  dev-only. The default stays Off.
- `set:donorPoolMB=auto` (stored as the string) and `set:donorPoolMB=<MiB>` both work. In
  Settings, Auto is stored as `-1`.

### Per tier (host tests, `DonorPoolSizingTests`)

Inputs are the research table's numbers. RAM is per tier. L is the measured or public
limit. The level is 60 %, as at a Play here (53–60 % measured). The footprint is 700 MiB.

| Tier | RAM MiB | L (entitled) | Auto (entitled) | L (not) | Auto (not) |
|---|---|---|---|---|---|
| 12 GB | 11,734 | 8,192 with Game Mode; 6,144 before | 0 (P − L = −2,212; −164 before Game Mode) | 3,356 | **3,072** (P − L = 2,624) |
| 8 GB | 7,679 | 6,046 | 0 (P − L = −1,891) | 3,355 | 0 (P − L = 800, under 1 GiB) |
| 6 GB | 5,734 | not public | 0, not offered (under 7 GiB) | 3,064 | 0, not offered |
| 4 GB | 3,662 | not public | 0, not offered | 2,090 | 0, not offered |

Other cases in the tests:

- With the level at 95 % (12 GB, not entitled), the 6,144 maximum caps the target.
- A fixed 6,144 at level 60 is capped to 5,120.
- The spare floor is 1,408 MiB on 12 GB, 921 on 8 GB, and 768 on 6 and 4 GB.

## 3. On the phone

**Settings shot** (`20261014T231822`): the run was `set:donorPoolMB=auto`,
`open:settings#developer`, `pad:a`, then eight `pad:down`. Its last screenshot shows
Settings › Developer › Memory:

- Simulated limit: Off.
- Simulated JIT memory: Off.
- **Donor pool (experiment): Auto**, focused, with the subtitle "Next Play: guest RAM from
  helpers that then end".

The first session's shot used `open:settings#memory`, which opens Setup check's memory
section, not the Developer one. It shows Setup check.

**Hollow Knight** (`20261014T231644`): `set:donorPoolMB=auto`, then
`--play app-367520 --until first-frame+10 --shot`.

- The run reached first frame at +10.19 s, until first-frame+10, ok.
- The screenshot shows the main menu: Start Game, Options, Achievements, Extras, Quit Game,
  with the touch controls.
- The app's limit before Play was 8,192 MB, so Game Mode was on.

The pool's lines:

```
donor-pool: setting=auto target_mb=0 reason="P-L -3751 MiB < 1024" spare_floor_mb=1408 … available=7993538120 … sys_free_mb=3302 sys_inactive_mb=2906 sys_speculative_mb=466 sys_purgeable_mb=178 … sys_level=48 sys_pressure=-1
donor-pool: auto L_mb=8191 P_mb=4440 ram_mb=11734 level=48 footprint_mb=568 donor_limit_mb=6139 target_mb=0 reason="P-L -3751 MiB < 1024"
donor-pool: no room for a pool; ordinary memory
```

- On this entitled 12 GB phone at Play, Auto takes **no pool**. Jetsam's level was 48 %, so
  P was 4,440 MiB, against L of 8,191.
- This matches the research: physical RAM, not the limit, is the wall here.
- One fresh helper reported **6,139 MiB available**, which is the donor's own limit, while
  the app's limit was 8,191.
  - So the helper does not get the app's Game Mode raise. This is one sample.
  - The helper maps nothing when Auto takes no pool. It is started only to record this
    number.

## Choices (owner away)

- **Auto is capped at 6,144 MiB and at the level's room**, as well as by `P − L + 512`.
- **The fixed sizes also get the new checks:** the spare floor during the rounds, the 1 GiB
  donor gate, and no pool under 7 GiB.
- **Rounding:** `round256` rounds down.
- **Auto's donor probe:** when Auto takes no pool on a phone that offers one, a single
  helper is started and stopped to log the donor limit. It allocates nothing.
- **No new regex in `tools/ui.py`:** the generic `set:KEY=VALUE` already carries `auto`. A
  host test (`test_donor_pool_setting_takes_auto_and_fixed_sizes`) and the help text cover
  it.
- **No signing change**, as described in section 1.

## Not shown

- Auto's non-zero path on a phone. Only the host tests cover a target above 0 (the
  unentitled tiers). An unentitled research IPA is deferred by the owner.
- Any tier other than 12 GB.
- Whether the donor's 6,139 MiB rises later, with Game Mode, or on other models.
