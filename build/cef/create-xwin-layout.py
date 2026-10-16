#!/usr/bin/env python3
"""Adapt the owner-downloaded x64 CRT/SDK; no downloads or licence actions."""
import json
import os
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
root = Path(os.environ.get('PLAYPORT_BUILD', repo / '.work')).resolve() / 'cef-src'
source = root / 'tools/xwin-sdk'
layout = root / 'tools/vs-xwin'
msvc = layout / 'VC/Tools/MSVC/14.43.34810'
sdk = layout / 'Windows Kits/10'
links = {
    msvc / 'include': source / 'crt/include',
    msvc / 'lib/x64': source / 'crt/lib/x64',
    sdk / 'Include/10.0.26100.0': source / 'sdk/include',
    sdk / 'Lib/10.0.26100.0': source / 'sdk/lib',
}
for dest, src in links.items():
    assert src.is_dir(), src
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.is_symlink():
        dest.symlink_to(src, target_is_directory=True)
includes = [msvc / 'include'] + [sdk / 'Include/10.0.26100.0' / part for part in ('ucrt', 'shared', 'um', 'winrt', 'cppwinrt')]
libs = [msvc / 'lib/x64'] + [sdk / 'Lib/10.0.26100.0' / part / 'x64' for part in ('ucrt', 'um')]
env = {'VSINSTALLDIR': [['.']], 'INCLUDE': [[str(p.relative_to(layout))] for p in includes], 'LIB': [[str(p.relative_to(layout))] for p in libs], 'PATH': [[str(root / 'src/third_party/llvm-build/Release+Asserts/bin')]]}
(sdk / 'bin').mkdir(parents=True, exist_ok=True)
(sdk / 'bin/SetEnv.x64.json').write_text(json.dumps({'env': env}, indent=2) + '\n')
# Both clang-cl and lld-link understand case-insensitive LLVM VFS overlays.
# Map the alias paths and the real paths, since LLVM may canonicalize symlinks.
def directory(path):
    entries = {}
    for p in sorted(path.iterdir()):
        key = p.name.lower()
        if key in entries:
            assert p.resolve() == entries[key][0].resolve(), p
            continue
        entry = directory(p) if p.is_dir() else {'type': 'file', 'name': p.name, 'external-contents': str(p.resolve())}
        entry['name'] = p.name
        entries[key] = (p, entry)
    return {'type': 'directory', 'name': str(path), 'contents': [v[1] for v in entries.values()]}
roots = [directory(p) for p in includes + libs]
roots += [directory(p) for p in (source / 'crt', source / 'sdk')]
(layout / 'overlay.json').write_text(json.dumps({'version': 0, 'case-sensitive': False, 'use-external-names': True, 'roots': roots}, indent=2) + '\n')
print(layout)
print('SetEnv.x64.json and case-insensitive overlay generated; x64 only')
