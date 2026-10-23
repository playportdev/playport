#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the real emitter with host-only linker seams; use the strict parser."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

here = Path(__file__).resolve().parent
repo = here.parents[1]
sys.path.insert(0, str(repo / 'tools'))
import descriptorprof as dp

build, source, out = map(lambda p: Path(p).resolve(), sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)
entry = next(e for e in json.loads((build / 'compile_commands.json').read_text())
             if e['file'].endswith('/kk_debug.c'))
args = shlex.split(entry['command'])
args = (args[:1] + ['-I' + str(source.parent)] + args[1:args.index('-MD')]
        + ['-O2', '-UNDEBUG', '-ffunction-sections', '-fdata-sections'])
for name, path in [('emitter', source), ('fixture', here / 'kk-descriptor-emission-test.c')]:
    subprocess.run(args + ['-c', str(path), '-o', str(out / (name + '.o'))], cwd=build, check=True)
exe = out / 'kk-descriptor-emission-test'
subprocess.run(['cc', '-pthread', '-Wl,--gc-sections',
                '-Wl,--wrap=write,--wrap=fprintf,--wrap=vsnprintf,--wrap=fpathconf,'
                '--wrap=fstat64,--wrap=fcntl64',
                '-o', str(exe), str(out / 'fixture.o'), str(out / 'emitter.o'),
                str(build / 'src/c11/impl/libmesa_util_c11.a')], check=True)

modes = sys.argv[4:] or ['append', 'pipe', 'max', 'format-error', 'format-overflow',
                         'eintr', 'eintr-limit', 'short', 'newline-short', 'write-error',
                         'pipe-small', 'stress', 'nonappend', 'unsupported-null',
                         'unsupported-type', 'getfl-error', 'nonappend-after-init']
for mode in modes:
    seeds = [1, 431, 0xdeadbeef] if mode == 'stress' else [1]
    for seed in seeds:
        log = out / f'{mode}-{seed}.log'
        with (out / f'{mode}-{seed}.stdout').open('w') as stdout:
            subprocess.run([str(exe), mode, str(log), str(seed)], stdout=stdout,
                           check=True, timeout=15)
        if mode.startswith('pipe'):
            log = out / f'{mode}-{seed}.stdout'
        text = log.read_text()
        records, malformed = [], []
        for line in text.splitlines():
            try:
                row = dp.parse_record(line)
                if row is not None:
                    records.append(row)
            except ValueError as error:
                malformed.append((line, str(error)))
        snapshots = [r for r in records if r['kind'] == 'snapshot']
        if mode in ('append', 'pipe', 'max', 'eintr', 'stress'):
            assert not malformed, (mode, malformed[:2])
            expected = 20 if mode in ('append', 'pipe') else 4010 if mode == 'stress' else 10
            assert len(snapshots) == expected, (mode, len(snapshots), expected)
            assert text.endswith('\n')
            assert len([r for r in records if r['kind'] == 'enabled']) == 1
            assert len([r for r in records if r['kind'] == 'calibration']) == 16
            if mode in ('append', 'pipe'):
                # Real production banner, calibration and two snapshots form a usable interval.
                result = subprocess.run([sys.executable, str(repo / 'tools/descriptorprof.py'),
                                         '--json', str(log)], capture_output=True, text=True)
                assert result.returncode == 0, result.stdout + result.stderr
            if mode == 'max':
                lengths = [len(line) + 1 for line in text.splitlines() if 'kind=snapshot' in line]
                assert max(lengths) < 2048, lengths
                assert all(r['snapshot'] == (1 << 64) - 1 for r in snapshots)
                fixed = dict(v='1', component='kk', kind='snapshot', hz='1000000000')
                maximum = {'op': 'template_update', 'pid': '-9223372036854775808',
                           **{k: '1' for k in ('final', 'clock_ok', 'overflow', 'quiescent')}}
                bound = len('[kk-descriptor]') + 1  # final newline
                for key in dp.schema('kk', 'snapshot'):
                    bound += 1 + len(key) + 1 + len(fixed.get(key, maximum.get(key, '9' * 20)))
                assert max(lengths) <= bound < 2048
                print(f'max u64 payload: observed {max(lengths)} bytes; '
                      f'v1 snapshot conservative bound {bound} bytes including newline')
        elif mode in ('nonappend', 'unsupported-null', 'unsupported-type', 'getfl-error',
                       'nonappend-after-init'):
            assert not snapshots, (mode, snapshots[:1])
            assert len(records) == (17 if mode == 'nonappend-after-init' else 0), mode
            assert len(malformed) == (0 if mode == 'unsupported-null' else 1), (mode, malformed)
            print((out / f'{mode}-{seed}.stdout').read_text().strip())
        elif mode == 'newline-short':
            # Honest terminal edge: all fields survive but final newline/poison do not.
            # With unchanged schema the strict parser CAN accept the final capture.
            assert not malformed and len(snapshots) == 10 and not text.endswith('\n')
            assert snapshots[-1]['op'] == 'push_template' and snapshots[-1]['final'] == 1
        else:
            assert malformed, (mode, 'failure must poison when sink still accepts poison')
            assert len(snapshots) < 10, (mode, len(snapshots))
        print(f'ok actual emitter {mode} seed={seed}: {len(snapshots)} strict-schema snapshot rows, '
              f'{len(malformed)} malformed; {log.relative_to(repo)}', flush=True)
