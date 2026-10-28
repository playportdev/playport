# W3's path-lookup cost is repeated probes of an absent NSI device (PLA-461)

**Linear:** [PLA-461](https://linear.app/playportdev/issue/PLA-461), under
[PLA-455](https://linear.app/playportdev/issue/PLA-455); the session-control polling is
[PLA-468](https://linear.app/playportdev/issue/PLA-468).

## Measurement

The [Metal System Trace breakdown](2026-10-28-witcher3-trace-breakdown.md) attributed
MainThread's `stat` samples to repeated drive resolution, and another thread's
`find_file_in_dir` samples to wrong-case game filenames. Reading the pinned Wine
code contradicts the first interpretation: `nt_to_unix_file_name_no_root` explicitly
skips the prefix existence check for ordinary DOS-drive paths. `get_dos_device`
handles plain device names, not those paths. Volume case-sensitivity is already
cached after a directory's device/fsid query.

No complete W3 desktop copy was available on this workstation. Instead, Linux drove
the installed dev app through its UI with the existing diagnostics (no Mac):

```sh
./pp perf --title app-292030 --secs 120 --no-hud \
  --settings '{"runtime":"env.WINEDEBUG=+file,+timestamp"}' \
  --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk \
  --shot first-frame+60 --shot first-frame+115 \
  --out .work/perf/pla461-file-trace
```

Baseline dev IPA: `2a13a59fe37277cbb9cd5771f0d5805ad7125bb3977899d2423377045d75f8eb`
(PLA-460's interface snapshot cache included). First frame +20.81 s; the run ended
successfully at first-frame+120. Raw log: 93,341,745 bytes. The earlier
`.work/perf/pla461-file-base` run mistakenly passed the literal value `%2Bfile`
instead of `+file` and captured no file trace; it is not a path baseline.

Count `get_nt_and_unix_names` and `NtCreateFile` records by Wine thread and NT name
in first-frame+60..120 s. The nearest preceding Wine trace timestamp to the host's
first-frame marker is 23591.632 s; records cover +60.005..119.999 s. Script and raw
counts remain in `$PLAYPORT_BUILD/agent-notes/pla461/file_summary.py` and
`file-summary.json`. Both operations give these same counts; there are no other
resolved paths in that window:

| Thread | NT path | Calls in 60 s | Name-resolution status |
| --- | --- | ---: | --- |
| `0068`, W3 MainThread | `\??\Nsi` | 25,533 (425.6/s) | `c00000cb`, `STATUS_BAD_DEVICE_TYPE` |
| `0024`, Playport session root | `\??\C:\users\playport\AppData\Local\Playport\session\control` | 1,066 (17.8/s) | `c0000034`, `STATUS_OBJECT_NAME_NOT_FOUND` |

The NSI name-resolution failure falls through to `server_open_file_object`, then
`nsi.dll` uses the working in-process Unix fallback. Its `get_nsi_device` caches
successful handles but retries **every failed open**. Every NSI query therefore
stats the absent `dosdevices/nsi` and tries a server open before using the fallback.
This is not config/save/mod-file polling by the game.

The other path is `app/SessionRoot/playport-session.c:control()`: Playport polls
for an absent file, so Wine attempts a case-insensitive lookup. This measurement
supports missing-control polling, not a wrong-case asset. Its fix stays in PLA-468.
The old trace alone did not establish which filename its worker was looking for.

## Change and host regression

`patches/wine-pe/0054` remembers `ERROR_FILE_NOT_FOUND` / `ERROR_PATH_NOT_FOUND`
separately for synchronous and asynchronous NSI opens, **only after confirming the
in-process fallback is available**. Each subsequent call restores the original
Win32 error; unsupported tables and notifications keep that error. An existing
real device still wins, desktop configurations without this fallback still retry,
and access/transient failures are not cached. Concurrent first probes may race;
the missing-device error is published atomically. This state belongs to the loaded
NSI DLL, not the filesystem.

There is **no drive-mapping, filename or volume cache** in this change. Therefore
there is no new filesystem invalidation rule and no drive-symlink invalidation
test to pass. The fallback is the iOS transport replacing a device that is not
provided there; this is not an upstream filesystem performance defect.

The host harness compiles the actual `get_nsi_device` function with Win32 transport
stubs, rather than a second implementation. Against the original PE source:

```text
python3 .work/agent-notes/pla461/host_probe.py .work/run/pe/wine/dlls/nsi/nsi.c
1000 fallback queries: 1000 device opens
Assertion `atomic_load(&opens) == 1' failed.
```

With the patch: **1,000 fallback queries, one open**. The committed test extracts
the function's context and added lines from the patch, supplying only its final closing
brace (outside the standard diff context). Run:

```sh
python3 -m unittest tools.tests.test_nsi_device tools.tests.test_nsi_ios
```

Five tests pass, including the existing NSI dispatcher/table tests. The new harness
uses ASan/UBSan and covers missing file/path, preserving each original error despite
unixlib initialization changing LastError, independent sync/async errors, concurrent
callers, successful device caching, real-device precedence, retry without a fallback
(including a driver appearing later), and retry on access/transient failures.

Repository gates: `./pp test --quick` and `./pp test` pass (777 Python tests,
host C tests and all six Swift package suites; the SteamClient suite skips one
test). A final `pp test --quick` also passes against the built records (`test-final.log`).
Logs: `$PLAYPORT_BUILD/agent-notes/pla461/test-quick.log` and `test-full.log`.
The first build rejected a nonstandard function-context patch export at the
series-ID gate, before compilation. Re-exporting with normal diff context made
`check_series` pass; no build-gate change was needed.

## Phone: target probes removed, smoke passed

The patched dev IPA is
`cb61f71d8bce1ad9ab399f3bacbcdb8942239e6a65aee46058112bd48d50a00a`,
`$PLAYPORT_BUILD/out/20261028-181511-cb61f71d/Playport-26.5-cb61f71d.ipa`.
`pp build` passes all 90 IPA checks; the changed build records contain only NSI
outputs for the three PE architectures. Installed in place on iPhone18,4,
iOS 27.0.1. Install log: `$PLAYPORT_BUILD/agent-notes/pla461/install.log`.

The same file-trace command, with this IPA pinned by `--expect-ipa`, writes
`.work/perf/pla461-file-final`. First frame +21.37 s, completed first-frame+120.
The +115 screenshot shows Geralt and the Kaer Morhen room, with the Witcher Senses
tutorial and objective; no launcher or error dialog. The count covers
first-frame+60.004..119.983 s:

| Path / call | Before | Patched |
| --- | ---: | ---: |
| MainThread opens of `\??\Nsi`, +60..120 s | 25,533 | **0** |
| Session root's absent `control`, +60..120 s | 1,066 | 1,007 |
| `Nsi` opens, entire trace including startup | 57,587 | **1** |

The one patched NSI probe occurs during startup on MainThread; no other thread
reprobes it. The once-only fallback diagnostic still reports `status 0`. Session
control polling remains intentionally unchanged. This proves removal of the
measured device-probe traffic, not a general filesystem acceleration.

Hollow Knight (`app-367520`), defaults: first frame +11.65 s, completes
`first-frame+10`, normal title-menu screenshot. Run
`.work/agent-notes/pla461/hk` (`screen-stop.png`); smoke only, not new gameplay or
performance qualification. Screenshots remain under `.work`, not in the evidence
repository.

## Untraced CPU/frame comparison

Both profiles use the PLA-455 arms: `pp perf --title app-292030 --secs 150
--cool 6 --cool-max 15 --cpu-prof --pad first-frame+10:witcher3-continue
--pad first-frame+50:witcher3-walk --shot first-frame+60 --shot first-frame+140`,
with the respective IPA pinned by `--expect-ipa`. No `WINEDEBUG` override. Runs:

- `.work/perf/pla461-base-profile`, baseline IPA `2a13a59f…`;
- `.work/perf/pla461-final-profile`, patched IPA `cb61f71d…`.

Both reach first frame at +19.17 s and finish first-frame+150; their screenshots
show Kaer Morhen gameplay. Both start at 80% battery, externally powered, thermal
Nominal, with the same 2,874 mW initial budget; both reach Serious. The camera and
final power budget differ. In the +140 screenshots the baseline faces the room's
fireplace from its right, while the patched run faces the bookcase with the
fireplace to the left. These are not identical rendered scenes.

`pp perf --compare` over +60..150 s reports:

| Metric | Before | Patched |
| --- | ---: | ---: |
| FPS | 20.2 | 23.6 |
| Frame time p99 / p99.9, ms | 100.04 / 383.47 | 75.03 / 333.45 |
| Frames ≥100 ms | 21 | 4 |
| GPU time, ms/frame | 27.62 | 34.14 |
| GPU utilization, % | 71.67 | 84.89 |
| Server requests/frame | 74.65 | 19.47 |
| Minimum power budget, mW | 769 | 404 |

Whole-run CPU profiles (`tools/sampleprof.py`, emitted rounded sample tables):

| Metric | Before | Patched |
| --- | ---: | ---: |
| Running samples | 13,204 | 12,398 |
| MainThread share of all samples | 21.49% | 20.18% |
| MainThread `stat` leaf share of all samples | 1.37% | no entry in emitted tables |

Do not interpret an absent entry in the profiler's bounded tables as an exact
zero-sample count. The independent file trace establishes that the NSI probes
were removed. The lower server traffic is consistent with that removal. **This
one pair does not establish a sustained FPS/hitch improvement:** budgets, GPU
work, P-core use and camera position differ. Further frame-rate qualification
remains PLA-455's work; the desktop caller-rate question remains PLA-470.

Comparison and profile summaries: `$PLAYPORT_BUILD/agent-notes/pla461/` files
`profile-comparison.json`, `profile-base.txt`, `profile-final.txt`,
`stat-samples.json`. All three completed patched plays (Hollow Knight and both W3
runs) use the full patched IPA hash above.

## Unrun gates and handoff

The optional Portal 2 save/load run **did not start**: its preflight inventory
found that Portal 2 is not installed. The phone has only Hollow Knight, W3 and
the shared redistributables. That unstarted gate wrote or changed no saves. The owner explicitly
chose to leave the additional save/load gate unrun rather than start another title
or install one. W3 did load the existing Kaer Morhen save during the measured runs;
this is not a save-write test. There is no filesystem cache/invalidation change.

No release-variant phone test or Mac session was run. The final device status
confirms the patched IPA hash, no lock holder and no running app. Compatibility
remains W3 **Playable with issues** and Hollow Knight **Works**; the existing
`site/compatibility/games.json` statuses already match. The session-control path's
remaining polling work is recorded in PLA-468, not fixed here.

## Limits

The file trace is diagnostic and perturbs timing; its frame rate is not a performance
comparison. The old Mac trace and this run are different executions. Neither proves
that all future W3 scenes resolve only these paths. No general case-correction cache
or filesystem behavior change is justified by this measurement.
