#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble the recorded CEF distribution layout from existing ninja outputs."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location('cef_payload', Path(__file__).with_name('verify-payload.py'))
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


def assemble(source, destination, record=payload.RECORD):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cef-assemble-', dir=destination.parent) as tmp:
        tree = Path(tmp)
        for name in payload.read_record(record):
            relative = name.split('/', 1)[1]
            if name == 'Release/libcef.lib':
                relative = 'libcef.dll.lib'
            src = source / relative
            if any(p.is_symlink() for p in (src, *src.parents) if p == source or source in p.parents):
                raise ValueError(f'CEF build output symlink: {relative}')
            dest = tree / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
        paths = payload.verify_payload(tree, record)
        if destination.exists():
            shutil.rmtree(destination)
        tree.rename(destination)
    print(f'cef-payload: assembled and verified {len(paths)} files')


def main():
    build = Path(os.environ.get('PLAYPORT_BUILD', payload.REPO / '.work'))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=build / 'cef-src/src/out/Release_GN_x64_lowva')
    parser.add_argument('--destination', type=Path, default=build / 'cef-src/out-stage-c')
    args = parser.parse_args()
    assemble(args.source, args.destination)


if __name__ == '__main__':
    main()
