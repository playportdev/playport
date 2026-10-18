#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stage the verified, separately built CEF payload for the owner-only dev IPA."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location('cef_payload', Path(__file__).with_name('verify-payload.py'))
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


def stage(source, notices, destination, record=payload.RECORD, notices_record=payload.NOTICES_RECORD):
    files = payload.verify_payload(source, record)
    notice_files = payload.verify_payload(notices, notices_record, payload=False)
    payload.runtime_entries(record, notices_record)  # Reject flattened collisions before copying.
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Beside the destination, so the final rename never crosses filesystems;
    # xtool packs only the listed resource directories, never this scratch one.
    with tempfile.TemporaryDirectory(prefix='.cef-stage-', dir=destination.parent) as tmp:
        tree = Path(tmp) / payload.VERSION
        for name in files:
            if name == 'Release/libcef.lib':
                continue
            dest = tree / name.split('/', 1)[1]
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, dest)
        for name in notice_files:
            dest = tree / 'notices' / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(notices / name, dest)
        payload.verify_runtime(tree, record, notices_record)
        if destination.exists():
            shutil.rmtree(destination)
        Path(tmp).rename(destination)
    print(f'cef-payload: staged {len(files) - 1} runtime files and {len(notice_files)} notices (dev only)')


def main():
    build = Path(os.environ.get('PLAYPORT_BUILD', payload.REPO / '.work'))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=build / 'cef-src/out-stage-c')
    parser.add_argument('--notices', type=Path, default=build / 'cef-src/notices')
    parser.add_argument('--destination', type=Path,
                        default=payload.REPO / 'app/Sources/S1Probe/Runtime/cef')
    args = parser.parse_args()
    stage(args.source, args.notices, args.destination)


if __name__ == '__main__':
    main()
