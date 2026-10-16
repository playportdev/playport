#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the separately built low-VA CEF input, without building or fetching it."""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import sys

REPO = Path(__file__).resolve().parents[2]
RECORD = REPO / 'build/generated/cef-143.0.14.sha256'


def verify_payload(source, record=RECORD):
    """Return recorded relative paths only after every file's digest matches."""
    paths = []
    for line in record.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match:
            raise ValueError('malformed CEF payload record')
        digest, name = match.groups()
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or str(path) != name
                or path.parts[0] not in ('Release', 'Resources') or name in paths):
            raise ValueError(f'invalid CEF payload path: {name}')
        file = source / name
        if not file.is_file():
            raise ValueError(f'CEF payload missing: {name}; supply the separately built out-stage-c input')
        with file.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual != digest:
            raise ValueError(f'CEF payload hash mismatch: {name}: expected {digest}, got {actual}')
        paths.append(name)
    if not paths:
        raise ValueError('empty CEF payload record')
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(os.environ.get('PLAYPORT_BUILD', REPO / '.work')) / 'cef-src/out-stage-c')
    args = parser.parse_args()
    try:
        paths = verify_payload(args.source)
    except (OSError, ValueError) as error:
        print(f'cef-payload: {error}', file=sys.stderr)
        return 1
    print(f'cef-payload: 143.0.14: {len(paths)} files verified')
    return 0


if __name__ == '__main__':
    sys.exit(main())
