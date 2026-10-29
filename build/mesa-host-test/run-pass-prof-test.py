#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build/run the actual profiler regression; mock timestamps are synthetic."""
import os
from pathlib import Path
import subprocess
import sys

here = Path(__file__).resolve().parent
build = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(here / 'run-cmd-pool-test.py'),
                str(build), 'kk-pass-prof-test'], check=True)
sys.path.insert(0, str(here.parent.parent / 'tools'))
import passprof  # noqa: E402

for mode in ('on', 'off', 'capture', 'read-fail'):
    env = dict(os.environ)
    for key in ('MESA_KK_PASS_PROF', 'MESA_KK_GPU_CAPTURE', 'MESA_KK_GPU_CAPTURE_FRAME',
                'KK_MOCK_COUNTER_READ_FAIL', 'KK_MOCK_REFUSE_COUNTER_HEAP'):
        env.pop(key, None)
    if mode == 'read-fail':
        env['KK_MOCK_COUNTER_READ_FAIL'] = '1'
    run = subprocess.run([str(build.parent / 'kk-pass-prof-test'), mode],
                         env=env, capture_output=True, text=True, timeout=30, check=True)
    (build.parent / f'pass-prof-{mode}.log').write_text(run.stdout + run.stderr)
    frames = passprof.parse(run.stderr.splitlines())
    assert len(frames) == (6 if mode == 'on' else 0), (mode, run.stderr)
    if mode == 'on':
        assert [f['present'] for f in frames] == [600, 601, 600, 3000, 4200, 5400]
        assert all(len(f['passes']) == 1 for f in frames)
        assert abs(frames[3]['gpu'] - .01) < 1e-9  # known mocked dispatch
        assert [f['untimed'] for f in frames] == [1, 1, 1, 0, 1, 1]
        assert all(f['passes'][0]['ms'] is None for f in frames if f['untimed'])
        assert 'unavailable=native-copy' in frames[4]['passes'][0]['key']
        assert 'unavailable=no-dispatch' in frames[5]['passes'][0]['key']
        assert 'PARTIAL' in passprof.report(run.stderr.splitlines())
        assert run.stderr.count('discarded KosmicKrisp') == 2  # overflow, tail
    if mode == 'capture':
        assert 'GPU capture armed; profiling off' in run.stderr
    print(f'ok pass-prof {mode}: queue lifecycle and parsed synthetic reports')
