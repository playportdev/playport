**Linear:** PLA-413, PLA-364

# 2026-10-20: RDR2 Story gameplay memory: the launcher's misaligned status block, the game's Social Club restarts, and a Metal command allocator reset that did not help

**Follows:** [rdr2-thread-registry](2026-10-20-rdr2-thread-registry.md) (IPA `82b9cd29`, run r3).
**Decision:** [0135](../decisions/0135-the-session-root-ends-every-restart-of-rdr2s-own-social-club.md).
**Changes kept:** madeira-unix 0174 (`pp_async_iosb.h`, test `tools/tests/test_async_iosb.py`); the
session root's Social Club sweep (`launcher_end.h`, `playport-session.c`, test
`app/tests/launcher_end_test.c`). **Dropped:** mesa 0050 and 0051 (section 3).

The phone was unattended (owner away, then at the phone for part of e1a and e4), on external power
at 80 %, with 4.5–5.6 GB free. Every RDR2 run used `--pad --action set:donorPoolMB=auto --action
set:endGameSocialClubAfterSignIn=true`, Story only. Runs are under `$PLAYPORT_BUILD/ui-runs/`, and
scripts, screenshots, device logs and the game's Social Club logs (which name the account; never
committed) under `$PLAYPORT_BUILD/agent-notes/pla413e/`.

## Builds and runs

| IPA sha256 | What | Hollow Knight first frame +10 | RDR2 runs |
| --- | --- | --- | --- |
| `7078c29464cf4425d56b102b17fb36b3daf7e2a7763cfcbc42ddf6a54b095ebd` | mesa 0050, sweep with 0133's cap | passed (`ui-runs/20261020T085412`) | `…T085541-rdr2-e1a`, `…T090505-rdr2-e1b` |
| `e169bc80c06c5f1b2ff83a21133ff1c39f0bf618cd350d9cc1ca71bdab8b7dea` | + madeira-unix 0174 | passed (`…T091708`) | `…T091813-rdr2-e2a` (translation run), `…T092459-rdr2-e2b` |
| `ac3ceac75ab36489fb73d7ea13dbed3e54fc98469cdd32bbab27053e532d678e` | + mesa 0051 census, sweep with no cap | passed (`…T094436`) | `…T094541-rdr2-e3a` (translation run), `…T095216-rdr2-e3b` |
| `3569a44c27e83358449ade9653a12637f48695ad466b99f52afd45923c12a212` | mesa 0050/0051 dropped: this commit | passed (`…T101535`) | `…T101628-rdr2-e4`, with `--settings 'app-1174180:{"aspect":"16:9"}'` |

## 1. The launcher ended before it started RDR2 (madeira-unix 0174)

- **What showed:** in e1a and e1b PlayRDR2 showed "Unable to launch game" about 57 s in, and
  RDR2.exe was never created. The app sent no `dialog shown` mark, as no game had presented, so
  the run's script waited (the owner closed the box in e1a).
- **Why:** the launcher's log ends with `Exception: 0xc0000005` right after its first cloud-save
  upload with a changed save (`cloudsave.asmx/PostFile`; the autosave changed in r3). In
  `s1-host.log` the launcher thread's `APC_ASYNC_IO` faulted in `invoke_system_apc` on
  `stlr w20, [x19]` with `x19 = 0x1790ece3e`: Wine's `set_async_iosb` writes the status block's
  Status with a release store, which faults on ARM64 at an address that is not aligned.
- **The change:** `ios_set_async_iosb` writes Information, then Status with a release store where
  Status is aligned, else a release fence and a plain store.
- **After it:** e2a, e2b, e3a, e3b and e4 all started RDR2 (no `REFUSED-OTHER` line in e2a).

## 2. The game's Social Club restarts (decision 0135)

- **r3:** the restarted browser and renderer (pids 0748, 0818) were never ended and lived through
  gameplay: image 314/284, private 91/68, fex 667/362 MiB committed (`[proc-mem]`), about 550 MB
  resident plus compressed at the kill.
- **e2b (sweep, cap 8):** 8 restarts ended in 39 s, one every ~5 s; the 9th (pid 078c) ran on.
- **e3b (no cap):** 30 restarts ended in 153 s; at the end no `SocialClubHelper.exe` was left. The
  game went on into gameplay with no box.
- **The game's own log** after the end (fixed text only): `Main browser connection lost!`,
  `Entering State: 'FAILED'`, `Signed out.`, `Entering State: 'WAIT_BROWSER'`, `[ERROR] Browser
  subprocess no longer running, entering error state`, repeated every ~5 s. With 0133's cap the
  9th start connected: `OnChannelConnected`, `Entering State: 'WAIT_IPC'`, `[ERROR] IPC system
  failed to connect to launcher, loading UI.`, `'WAIT_BROWSER_WINDOW'`, `'LOADING'`.

## 3. Metal command allocators: reset at commit completion (mesa 0050, dropped)

0050 let a recording hold its allocator until its commit's completion handler ran, then reset it;
a pool kept at most 8 idle ones. Hollow Knight passed with it. In RDR2 it made things worse:

| Run | Allocators at the landing page | In the Story load and gameplay | Graphics ledger |
| --- | ---: | ---: | ---: |
| r3 (no reset) | 40 / 119 MiB | 48 / 557–634 MiB | 2.7–3.1 GB |
| e2b (0050) | 33 / 81 MiB | 75–83 / 804–890 MiB | 3.1–3.2 GB |
| e3b (0050 + census) | 33 / 79 MiB | 78–88 / 830–999 MiB | 3.2–3.5 GB |

The census (0051, `[kk-alloc]`) shows why: at each submit about 55 primary recordings, about
13 MiB each, are recorded and not yet committed (`recorded=55/738 MiB`, 40 sealed), then all go
in flight at once. The game records about 700 MiB of Metal commands per frame batch; a reset
after completion does not lower that, and the idle cap churned 5,484 allocators in 5 minutes.
Without a reset, upstream holds about the same. So the allocators' size is the game's per-frame
command volume as KosmicKrisp encodes it, not a leak; both patches are dropped (kept under
`agent-notes/pla413e/dropped/`).

## 4. How each Story run ended

| Run | A on Story | Gameplay | End |
| --- | --- | --- | --- |
| r3 (before) | 08:24:32 | 2.5 min, 08:28–08:30:59 | jetsam per-process-limit |
| e2b | 09:29:28 | stick from 09:31:58 | jetsam per-process-limit 09:33:21, phys 7,831 MB, graphics 3,171 |
| e3b | Story started by a second scripted A on the PlayRDR2 box mark (09:55:23) | cabin at 09:58 | jetsam per-process-limit 10:00:48, graphics 3.5 GB |
| e4 | 10:19:46 (script, Story tab underlined) | stick from about 10:21; Arthur on the cabin's porch with the HUD at 10:24:10 | killed by jetsam `highwater` 10:26:52 when the app was put in the background (the 6,144 MB background limit); its host log was not pulled |

## Not shown

- Ten minutes of gameplay: no run reached it.
- e4's footprint: the run was ended from the workstation after the app was killed, so its host log
  was not pulled.
- Whether 16:9 cures the stretched 3D image (owner's report): e4 had it, and the owner reports the
  3D world still stretched and zoomed in, the HUD correct. `system.xml` has no aspect field
  (windowed 1280×720).

Games played: Red Dead Redemption 2 (`app-1174180`), Story only; Hollow Knight (`app-367520`) for
the first-frame checks.
