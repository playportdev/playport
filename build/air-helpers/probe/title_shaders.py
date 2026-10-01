#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run every DXBC shader a title ships through a host airconv.

    title_shaders.py SCAN TITLE_DIR OUT [--match REGEX] [--llvm BIN] [--jobs N]

SCAN is air-helper-port.sh's `host` output `scan-port` (probe/airconv_scan.cpp).
The script finds DXBC containers inside the title's files (engines keep them
in their own cache formats; a container carries its own size at offset 24;
--match limits the search to relative paths matching REGEX), keeps one copy
of each (by sha1) under OUT/dxbc as <kind>-<sha1>.dxbc, and converts them the way DXMT does on the device: vertex, pixel and compute
shaders alone, geometry shaders through both halves of the geometry mesh
pipeline, hull and domain shaders through the tessellation pipeline. With
--llvm (an LLVM 15 bin directory with llvm-dis and opt) every standalone
result's AIR module also goes through LLVM's verifier.

Offline, a title's real shader pairings are not known, so a geometry, hull or
domain shader counts as converted when it converts with any first-stage
shader of the title. Compressed caches are not searched: the summary lists
which files held containers. Writes OUT/summary.json; exit 1 on any failure.
"""
import argparse
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

KINDS = {0: 'ps', 1: 'vs', 2: 'gs', 3: 'hs', 4: 'ds', 5: 'cs'}
MAX_FILE = 1 << 30  # shader caches are small; skip texture and sound caches


def containers(data):
    """Yield (offset, blob, kind) for each well-formed DXBC container."""
    o = data.find(b'DXBC')
    while o >= 0:
        if o + 32 <= len(data):
            size, nch = struct.unpack_from('<II', data, o + 24)
            if 32 + 4 * nch <= size <= len(data) - o and 0 < nch < 64:
                blob = data[o:o + size]
                kind = None
                for i in range(nch):
                    co = struct.unpack_from('<I', blob, 32 + 4 * i)[0]
                    if co + 12 > size:
                        kind = None
                        break
                    if blob[co:co + 4] in (b'SHDR', b'SHEX'):
                        tok = struct.unpack_from('<I', blob, co + 8)[0]
                        kind = KINDS.get((tok >> 16) & 0xffff)
                if kind:
                    yield o, blob, kind
                    o = data.find(b'DXBC', o + size)
                    continue
        o = data.find(b'DXBC', o + 4)


def extract(title, out, match=None):
    os.makedirs(out, exist_ok=True)
    seen, sources = {}, collections.Counter()
    for dp, dns, fns in os.walk(title):
        dns.sort()
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            if match and not re.search(match, os.path.relpath(p, title)):
                continue
            try:
                if os.path.getsize(p) > MAX_FILE:
                    continue
                with open(p, 'rb') as f:
                    data = f.read()
            except OSError:
                continue
            if b'DXBC' not in data:
                continue
            for _, blob, kind in containers(data):
                h = hashlib.sha1(blob).hexdigest()[:16]
                name = f'{kind}-{h}.dxbc'
                if h not in seen:
                    seen[h] = name
                    with open(os.path.join(out, name), 'wb') as f:
                        f.write(blob)
                sources[os.path.relpath(p, title)] += 1
    return sorted(seen.values()), sources


def run_scan(scan, args):
    r = subprocess.run([scan] + args, capture_output=True, text=True, errors='replace')
    if r.returncode not in (0, 1):
        raise SystemExit(f'{scan} {args[0]}: exit {r.returncode}\n{r.stderr[-2000:]}')
    return r.stdout.splitlines()


def verify(llvm, lib):
    """LLVM's verifier on the metallib's bitcode, retargeted to the host."""
    data = open(lib, 'rb').read()
    # MTLBHeader (airconv metallib_writer): BitcodeOffset and BitcodeSize at
    # 72 and 80. The module starts with LLVM's 0x0B17C0DE wrapper header,
    # which llvm-dis needs: cut at the raw 'BC' magic instead and about a
    # quarter of the modules read as "Malformed block".
    off, size = struct.unpack_from('<QQ', data, 72)
    bc = data[off:off + size]
    dis = subprocess.run([os.path.join(llvm, 'llvm-dis'), '-opaque-pointers=0', '-', '-o', '-'],
                         input=bc, capture_output=True)
    if dis.returncode:
        return dis.stderr.decode(errors='replace')[-300:]
    ir = re.sub(rb'(?m)^target triple = .*$', b'target triple = "x86_64-unknown-linux"', dis.stdout)
    opt = subprocess.run([os.path.join(llvm, 'opt'), '-opaque-pointers=0', '-verify', '-o', '/dev/null'],
                         input=ir, capture_output=True)
    return opt.stderr.decode(errors='replace')[-300:] if opt.returncode else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('scan')
    ap.add_argument('title')
    ap.add_argument('out')
    ap.add_argument('--match', help='only search files whose relative path matches this regex')
    ap.add_argument('--llvm', help='LLVM 15 bin directory (llvm-dis, opt) for the AIR verifier')
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    a = ap.parse_args()
    dxbc, lib = os.path.join(a.out, 'dxbc'), os.path.join(a.out, 'lib')
    os.makedirs(lib, exist_ok=True)
    names, sources = extract(a.title, dxbc, a.match)
    by = collections.defaultdict(list)
    for n in names:
        by[n.split('-')[0]].append(os.path.join(dxbc, n))

    def listfile(tag, items):
        f = tempfile.NamedTemporaryFile('w', dir=a.out, prefix=tag + '-', suffix='.txt', delete=False)
        f.write('\n'.join(items) + '\n')
        f.close()
        return f.name

    plain = by['vs'] + by['ps'] + by['cs']
    chunks = [plain[i::a.jobs] for i in range(a.jobs) if plain[i::a.jobs]]
    jobs = [['plain', listfile('plain', c), lib] for c in chunks]
    for mode, first, second in (('gs', 'vs', 'gs'), ('hull', 'vs', 'hs'), ('domain', 'hs', 'ds')):
        if by[second]:
            jobs.append([mode, listfile(first, by[first]), listfile(second, by[second])])
    results = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for lines in ex.map(lambda j: run_scan(a.scan, j), jobs):
            results += lines
    for j in jobs:
        for p in j[1:]:
            if p.endswith('.txt'):
                os.unlink(p)
    ok = collections.Counter()
    failures = []
    for line in results:
        st, path, *rest = line.split(' ', 2)
        kind = os.path.basename(path).split('-')[0]
        if st == 'ok':
            ok[kind] += 1
        else:
            failures.append({'shader': os.path.basename(path), 'status': st, 'error': ' '.join(rest)})
    bad_air = []
    if a.llvm:
        libs = sorted(os.path.join(lib, f) for f in os.listdir(lib) if f.endswith('.metallib'))
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            for f, err in zip(libs, ex.map(lambda f: verify(a.llvm, f), libs)):
                if err:
                    bad_air.append({'shader': os.path.basename(f), 'error': err})
    summary = {
        'title': os.path.abspath(a.title),
        'shaders': {k: len(v) for k, v in sorted(by.items())},
        'converted': dict(sorted(ok.items())),
        'failed': failures,
        'air_verified': None if not a.llvm else len(os.listdir(lib)) - len(bad_air),
        'air_failed': bad_air,
        'sources': dict(sources.most_common()),
    }
    with open(os.path.join(a.out, 'summary.json'), 'w') as f:
        json.dump(summary, f, indent=1)
    print(f"shaders: {summary['shaders']} ({len(names)} unique)")
    print(f"converted: {summary['converted']}")
    print(f"failed: {len(failures)}" + ''.join(f"\n  {x['shader']}: {x['error'][:200]}" for x in failures[:20]))
    if a.llvm:
        print(f"AIR verified: {summary['air_verified']}, failed: {len(bad_air)}")
    print(f"containers from {len(sources)} files; summary: {os.path.join(a.out, 'summary.json')}")
    return 1 if failures or bad_air else 0


if __name__ == '__main__':
    sys.exit(main())
