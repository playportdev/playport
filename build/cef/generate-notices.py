#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate CEF notices from the pinned source tree; no compiler or SDK is used."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]


def generate(source, output):
    pins = dict(line.split()[:2] for line in (REPO / 'pins.lock').read_text().splitlines()
                if line.strip() and not line.startswith('#'))
    for name, tree in (('chromium', source), ('cef', source / 'cef')):
        actual = subprocess.check_output(['git', '-C', str(tree), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != pins[name]:
            raise ValueError(f'{name} source does not match pins.lock')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cef-notices-', dir=output.parent) as tmp:
        stage = Path(tmp)
        # Same generator and target as components/resources:about_credits.
        subprocess.run([sys.executable, str(source / 'tools/licenses/licenses.py'),
                        'credits', '--target-os=win', str(stage / 'about_credits.html')],
                       cwd=source, check=True)
        for src, dest in (('cef/LICENSE.txt', 'CEF-LICENSE.txt'),
                          ('third_party/ffmpeg/LICENSE.md', 'FFmpeg-LICENSE.md'),
                          ('third_party/ffmpeg/COPYING.LGPLv2.1', 'FFmpeg-COPYING.LGPLv2.1')):
            shutil.copyfile(source / src, stage / dest)
        shutil.copyfile(REPO / 'build/cef/BUILD-NOTICE.txt', stage / 'Playport-BUILD-NOTICE.txt')
        if output.exists():
            shutil.rmtree(output)
        stage.rename(output)


def main():
    build = Path(os.environ.get('PLAYPORT_BUILD', REPO / '.work'))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=build / 'cef-src/src')
    parser.add_argument('--output', type=Path, default=build / 'cef-src/notices')
    args = parser.parse_args()
    generate(args.source.resolve(), args.output.resolve())
    print('cef-notices: generated Chromium credits, CEF BSD and FFmpeg LGPL notices')


if __name__ == '__main__':
    main()
