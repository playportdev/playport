#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the separately built low-VA CEF input, without building or fetching it."""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys

REPO = Path(__file__).resolve().parents[2]
RECORD = REPO / 'build/generated/cef-143.0.14.sha256'
NOTICES_RECORD = REPO / 'build/generated/cef-143.0.14-notices.sha256'
VERSION = '143.0.14'


def read_record(record, payload=True):
    """Read a checksum record, rejecting ambiguous or escaping paths."""
    paths = {}
    for line in record.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match:
            raise ValueError('malformed CEF payload record')
        digest, name = match.groups()
        path = PurePosixPath(name)
        if (not path.parts or path.is_absolute() or '..' in path.parts or str(path) != name
                or '\\' in name
                or (payload and (len(path.parts) < 2 or path.parts[0] not in ('Release', 'Resources')))
                or (not payload and len(path.parts) != 1)
                or name.lower() in {p.lower() for p in paths}):
            raise ValueError(f'invalid CEF payload path: {name}')
        paths[name] = digest
    if not paths:
        raise ValueError('empty CEF payload record')
    return paths


def verify_payload(source, record=RECORD, payload=True):
    """Return recorded relative paths only after every file's digest matches."""
    paths = read_record(record, payload)
    for name, digest in paths.items():
        file = source / name
        if source.is_symlink() or any(p.is_symlink() for p in (file, *file.parents) if p == source or source in p.parents):
            raise ValueError(f'CEF payload symlink: {name}')
        if not file.is_file():
            raise ValueError(f'CEF payload missing: {name}; supply the separately built out-stage-c input')
        with file.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual != digest:
            raise ValueError(f'CEF payload hash mismatch: {name}: expected {digest}, got {actual}')
    return list(paths)


# Linked with 16 KiB sections (patches/cef 0003, patches/chromium 0017-0018), so that Wine on
# iOS maps their sections from the file instead of reading each DLL into every process (PLA-415).
SECTIONS_16K = ('Release/libcef.dll', 'Release/libGLESv2.dll', 'Release/vk_swiftshader.dll')
PAGE_16K = 0x4000


def unaligned_sections(data):
    """The PE image's alignments and sections that a 16 KiB-page host cannot map from the file."""
    if data[:2] != b'MZ':
        raise ValueError('not a PE image')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('not a PE image')
    count, optional_size = struct.unpack_from('<H12xH', data, pe + 6)
    optional = pe + 24
    section_alignment, file_alignment = struct.unpack_from('<II', data, optional + 32)
    bad = []
    if section_alignment % PAGE_16K or file_alignment % PAGE_16K:
        bad.append(f'alignment {section_alignment:#x}/{file_alignment:#x}')
    table = optional + optional_size
    for i in range(count):
        name, _, rva, raw_size, raw_offset = struct.unpack_from('<8sIIII', data, table + 40 * i)
        if rva % PAGE_16K or (raw_size and raw_offset % PAGE_16K):
            label = name.rstrip(b'\0').decode(errors='replace')
            bad.append(f'{label} rva {rva:#x} file {raw_offset:#x}')
    return bad


def verify_16k_sections(source, names=SECTIONS_16K):
    """Raise unless every named DLL has 16 KiB-aligned sections in memory and in the file."""
    for name in names:
        bad = unaligned_sections((source / name).read_bytes())
        if bad:
            raise ValueError(f'CEF payload not 16 KiB-aligned: {name}: {", ".join(bad[:4])}')
    return list(names)


def runtime_entries(record=RECORD, notices_record=NOTICES_RECORD):
    """Flatten the recorded runtime and notices, never the import library."""
    entries = {}
    for name, digest in read_record(record).items():
        if name == 'Release/libcef.lib':
            continue
        dest = name.split('/', 1)[1]
        if dest.lower() in {p.lower() for p in entries}:
            raise ValueError(f'CEF flattened path collision: {dest}')
        entries[dest] = digest
    for name, digest in read_record(notices_record, payload=False).items():
        dest = f'notices/{name}'
        if dest.lower() in {p.lower() for p in entries}:
            raise ValueError(f'CEF notice path collision: {dest}')
        entries[dest] = digest
    return entries


def verify_runtime(directory, record=RECORD, notices_record=NOTICES_RECORD):
    entries = runtime_entries(record, notices_record)
    got = {p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file()}
    if got != set(entries) or any(p.is_symlink() for p in directory.rglob('*')):
        raise ValueError('CEF runtime file set differs from the records')
    for name, digest in entries.items():
        with (directory / name).open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                raise ValueError(f'CEF runtime hash mismatch: {name}')
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(os.environ.get('PLAYPORT_BUILD', REPO / '.work')) / 'cef-src/out-stage-c')
    args = parser.parse_args()
    try:
        paths = verify_payload(args.source)
        verify_16k_sections(args.source)
    except (OSError, ValueError) as error:
        print(f'cef-payload: {error}', file=sys.stderr)
        return 1
    print(f'cef-payload: 143.0.14: {len(paths)} files verified, {len(SECTIONS_16K)} DLLs with 16 KiB sections')
    return 0


if __name__ == '__main__':
    sys.exit(main())
