#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reads a Metal .gputrace bundle (Settings' GPU capture, dev builds; `pp phone
pull` fetches it) on this workstation, without Xcode: what the captured frame
asked of the GPU, with no timings (nothing here replays it; GPU time per pass
is Diagnostics' other switch, tools/passprof.py).

  gputrace.py BUNDLE              the frame: its command buffers, each render
                                  pass's targets (size, format, load/store),
                                  pipelines and draws; then each pipeline's
                                  shaders with Apple's compiler statistics
  gputrace.py BUNDLE --calls      every recorded call, named, in order
  gputrace.py BUNDLE --json       the summary as JSON
  gputrace.py names DSC_DIR       build the call-name table from the phone's
                                  shared cache (below)

A capture names its calls by number. The numbers are GPUToolsCapture's
enumeration, whose names the phone's own libraries carry in that order
(kDYFE<class>_<selector>, from 0xffffc000): `names` reads them from the shared
cache `pymobiledevice3 developer fetch-symbols download DIR` fetches (7.5 GB for
iOS 27.0) into $PLAYPORT_BUILD/cache/gputrace-names.txt. Without that table,
calls show as their numbers.

The bundle (reverse engineered from iOS 27.0 captures; see
docs/evidence/2026-09-29-metal-tools-without-a-mac.md):

  capture, device-resources-*   "MTSP", then records: u32 size, i32 call
                                number, 24 bytes, u32 flags (bit 0: a return
                                value follows the arguments), the argument
                                signature (NUL-terminated, padded to 4: C a
                                receiver, t an object, ul/l 8 bytes, ui/i/f 4,
                                U/S a string, @N an array of N), the arguments,
                                the return (u32 type, u64 value), a backtrace
  index, store0                 a keyed store: index is "xdic", u32 version,
                                slot count S, entry count N, N; S 12-byte hash
                                slots; N entries (u32 size, stored size,
                                offset in store0, 0, kind: 1 zlib in store0, 2 a
                                file of the bundle, 0); a u16 table; the N keys,
                                NUL-separated, to the end. A U argument is a key: a
                                descriptor (tag 0xe1, 8-byte fields) or an
                                NSKeyedArchiver plist
"""

import json
import os
import plistlib
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.environ.get("PLAYPORT_BUILD", os.path.join(HERE, "..", ".work"))
NAMES = os.path.join(BUILD, "cache", "gputrace-names.txt")
BASE = -16384            # the first Metal call number (0xffffc000)
TOK = re.compile(r"<b>|@\d+|u?[a-zA-Z]")
WIDTH = {"t": 8, "ul": 8, "l": 8, "q": 8, "uq": 8, "w": 8, "uw": 8, "d": 8,
         "ui": 4, "i": 4, "f": 4, "us": 2, "s": 2, "uc": 1, "c": 1, "b": 1}
PIXEL = {10: "R8", 25: "R16F", 55: "R32F", 70: "RGBA8", 71: "RGBA8_sRGB", 80: "BGRA8",
         81: "BGRA8_sRGB", 90: "RGB10A2", 92: "RG11B10F", 93: "RGB9E5", 115: "RGBA16F",
         125: "RGBA32F", 252: "D32F", 250: "D16", 253: "S8", 255: "D24S8", 260: "D32FS8"}
LOAD = {0: "x", 1: "L", 2: "C"}          # MTLLoadAction: don't care, load, clear
STORE = {0: "x", 1: "S", 2: "R", 3: "SR", 4: "U"}   # MTLStoreAction


class Call:
    __slots__ = ("num", "sig", "args", "ret")

    def __init__(self, num, sig, args, ret):
        self.num, self.sig, self.args, self.ret = num, sig, args, ret


def records(path):
    """Each record of an MTSP stream as a Call; a record this parser cannot
    read keeps its number and signature with no arguments."""
    with open(path, "rb") as f:
        b = f.read()
    if b[:4] != b"MTSP":
        raise ValueError(f"{path}: not an MTSP stream")
    off = 8
    while off + 8 <= len(b):
        size, num = struct.unpack_from("<Ii", b, off)
        if size < 0x28 or off + size > len(b):
            break
        yield parse(num, b[off:off + size])
        off += size


def parse(num, rec):
    flags = struct.unpack_from("<I", rec, 0x20)[0]
    end = rec.index(b"\0", 0x24)
    sig = rec[0x24:end].decode("latin1")
    o = (end + 4) & ~3
    args, ret = [], None
    try:
        if sig.startswith("C"):
            args.append(struct.unpack_from("<Q", rec, o)[0])
            o += 8
        count = None
        for t in TOK.findall(sig[1:] if sig.startswith("C") else sig):
            if t.startswith("@"):
                count = int(t[1:])
                continue
            if t == "<b>":
                continue
            if t in ("U", "S"):
                k = rec.index(b"\0", o)
                args.append(rec[o:k].decode("latin1"))
                o = (k + 4) & ~3
                continue
            w = WIDTH.get(t, 8)
            fmt = "f" if t == "f" else {8: "q" if t in ("l", "q") else "Q", 4: "i" if t == "i" else "I",
                                        2: "H", 1: "B"}[w]
            if count:
                args.append(list(struct.unpack_from(f"<{count}{fmt}", rec, o)))
                o += w * count
                count = None
            else:
                args.append(struct.unpack_from("<" + fmt, rec, o)[0])
                o += w
        if flags & 1:
            ret = struct.unpack_from("<IQ", rec, o)[1]
    except (struct.error, ValueError):
        pass
    return Call(num, sig, args, ret)


def load_store(bundle):
    """The keyed store: key -> bytes (the zlib entries in store0)."""
    with open(os.path.join(bundle, "index"), "rb") as f:
        b = f.read()
    magic, _, slots, n, _ = struct.unpack_from("<4sIIII", b, 0)
    if magic != b"xdic":
        raise ValueError(f"{bundle}/index: not an xdic")
    base = 0x14 + 12 * slots
    entries = [struct.unpack_from("<6I", b, base + 24 * i) for i in range(n)]
    # then a table of u16s, then the keys, NUL-separated, to the end of the file
    keys = [k.decode("latin1") for k in b[base + 24 * n:].rstrip(b"\0").split(b"\0")][-n:]
    with open(os.path.join(bundle, "store0"), "rb") as f:
        store = f.read()
    out = {}
    for key, (size, stored, off, _, kind, _) in zip(keys, entries):
        if kind == 1:
            out[key] = zlib.decompress(store[off:off + stored])
    return out


def unarchive(data):
    """An NSKeyedArchiver plist as plain dicts and lists."""
    p = plistlib.loads(data)
    objs = p["$objects"]

    def res(x):
        if isinstance(x, plistlib.UID):
            x = objs[x.data]
        if isinstance(x, dict):
            if "NS.keys" in x:
                return {res(k): res(v) for k, v in zip(x["NS.keys"], x["NS.objects"])}
            if "NS.objects" in x:
                return [res(v) for v in x["NS.objects"]]
            if "NS.string" in x:
                return x["NS.string"]
            return {k: res(v) for k, v in x.items() if k != "$class"}
        return None if x == "$null" else x
    return res(p["$top"]["root"])


def call_names():
    try:
        with open(NAMES) as f:
            return [l.strip() for l in f if l.strip()]
    except OSError:
        return []


def name_of(names, num):
    i = num - BASE
    return names[i] if 0 <= i < len(names) else f"#{num}"


def words(blob):
    return struct.unpack_from(f"<{len(blob) // 8}Q", blob) if blob else ()


def texture_desc(blob):
    """A texture descriptor's type, format, size, usage."""
    q = words(blob)
    if len(q) < 12 or q[0] != 0xE1:
        return None
    return {"format": PIXEL.get(q[2], str(q[2])), "width": q[3], "height": q[4],
            "samples": q[7], "usage": q[11]}


def attachment(q, at):
    """A depth or stencil attachment at word AT: the texture, then its load and store
    actions 8 and 9 words on (17 words in all)."""
    return {"texture": q[at], "load": LOAD.get(q[at + 8], str(q[at + 8])),
            "store": STORE.get(q[at + 9], str(q[at + 9]))} if q[at] else None


def pass_desc(blob):
    """A render pass descriptor: from word 2 the colour attachments, each its index
    and 16 words as a depth one's, to a word of all ones; then depth, stencil, 4
    words, the render target's width and height (0 when unset)."""
    q = words(blob)
    if len(q) < 3 or q[0] != 0xE1:
        return None
    colors, i = {}, 2
    while i < len(q) and q[i] != 0xFFFFFFFFFFFFFFFF:
        colors[q[i]] = attachment(q, i + 1)
        i += 17
    i += 1
    if i + 17 * 2 + 6 > len(q):
        return None
    return {"colors": colors, "color0": colors.get(0), "depth": attachment(q, i),
            "stencil": attachment(q, i + 17), "width": q[i + 38], "height": q[i + 39]}


def summarize(bundle):
    names = call_names()
    store = load_store(bundle)
    with open(os.path.join(bundle, "metadata"), "rb") as f:
        meta = plistlib.load(f)
    res = next(f for f in sorted(os.listdir(bundle)) if f.startswith("device-resources-"))
    functions, pipelines, textures, stats = {}, {}, {}, {}
    for c in records(os.path.join(bundle, res)):
        n = name_of(names, c.num)
        if n == "MTLLibrary_newFunctionWithName" and len(c.args) > 1:
            functions[c.ret] = c.args[1]
        elif n.startswith("MTLDevice_newRenderPipelineState") and len(c.args) > 1:
            pipelines[c.ret] = store.get(c.args[1], b"")
        elif n.startswith("MTLDevice_newTexture") and len(c.args) > 1 and isinstance(c.args[1], str):
            textures[c.ret] = texture_desc(store.get(c.args[1], b""))
        elif c.sig == "CiUul" and len(c.args) > 2 and isinstance(c.args[2], str):
            data = store.get(c.args[2], b"")
            if data.startswith(b"bplist"):   # a pipeline's compiler statistics
                stats[c.args[0]] = unarchive(data)
    shaders = {}
    for addr, blob in pipelines.items():
        found = [functions[w] for w in words(blob[:len(blob) // 8 * 8]) if w in functions]
        shaders[addr] = found
    buffers, passes = [], []
    cur = None
    for c in records(os.path.join(bundle, "capture")):
        n = name_of(names, c.num)
        if n.startswith("MTLCommandQueue_commandBuffer"):
            buffers.append({"passes": 0, "presents": 0})
        elif n == "MTLCommandBuffer_renderCommandEncoderWithDescriptor":
            d = pass_desc(store.get(c.args[1], b"")) if len(c.args) > 1 else None
            cur = {"buffer": len(buffers), "kind": "render", "desc": d, "pipelines": [], "draws": 0,
                   "elements": 0, "resources": 0, "fence_waits": 0}
            passes.append(cur)
            if buffers:
                buffers[-1]["passes"] += 1
        elif re.match(r"MTLCommandBuffer_(blit|compute)CommandEncoder", n):
            cur = {"buffer": len(buffers), "kind": n.split("_")[1][:4], "desc": None, "pipelines": [],
                   "draws": 0, "elements": 0, "resources": 0, "fence_waits": 0}
            passes.append(cur)
        elif n == "MTLCommandBuffer_presentDrawable" and buffers:
            buffers[-1]["presents"] += 1
        elif cur is None:
            continue
        elif n.endswith("setRenderPipelineState") or n.endswith("setComputePipelineState"):
            if len(c.args) > 1 and c.args[1] not in cur["pipelines"]:
                cur["pipelines"].append(c.args[1])
        elif "_draw" in n and len(c.args) > 3:
            cur["draws"] += 1
            count = c.args[2] if "Indexed" in n else c.args[3]
            inst = c.args[6] if "Indexed" in n and len(c.args) > 6 else (c.args[4] if len(c.args) > 4 else 1)
            if isinstance(count, int) and isinstance(inst, int):
                cur["elements"] += count * max(inst, 1)
        elif n.startswith("MTL") and "dispatch" in n:
            cur["draws"] += 1
        elif n.startswith("MTLBlitCommandEncoder_copy") or n.startswith("MTLBlitCommandEncoder_fill"):
            cur["draws"] += 1   # a copy; its elements are the texels a texture copy moves
            size = next((a for a in c.args if isinstance(a, list) and len(a) == 3 and a[0]), None)
            if size:
                cur["elements"] += size[0] * size[1] * size[2]
        elif "_useResource" in n or "_useHeap" in n:
            cur["resources"] += 1
        elif "_waitForFence" in n:
            cur["fence_waits"] += 1
        elif n.endswith("_endEncoding"):
            cur = None
    return {"device": meta.get("DYCaptureSession.deviceId"), "named": bool(names),
            "buffers": buffers, "passes": passes, "shaders": shaders, "stats": stats, "textures": textures}


def target(a, textures):
    if not a:
        return "-"
    t = textures.get(a["texture"])
    fmt = t["format"] if t else "?"
    return f"{fmt} {a['load']}/{a['store']}"


def report(s):
    out = []
    if not s["named"]:
        out.append(f"(no call-name table at {NAMES}: run `gputrace.py names DSC_DIR`; calls show as numbers)")
    out.append(f"{len(s['buffers'])} command buffers, {len(s['passes'])} passes, "
               f"{sum(p['draws'] for p in s['passes'])} draws")
    out.append(f"{'#':>3} {'cb':>2} {'kind':<6} {'size':<10} {'colour 0':<16} {'depth':<16} "
               f"{'draws':>5} {'elements':>8} {'res':>4} {'fw':>3}  pipelines")
    pipe_ids = {}
    for i, p in enumerate(s["passes"]):
        d = p["desc"] or {}
        size = f"{d['width']}x{d['height']}" if d.get("width") else "-"
        ids = []
        for a in p["pipelines"]:
            ids.append(pipe_ids.setdefault(a, f"P{len(pipe_ids)}"))
        out.append(f"{i:>3} {p['buffer']:>2} {p['kind']:<6} {size:<10} "
                   f"{target(d.get('color0'), s['textures']):<16} {target(d.get('depth'), s['textures']):<16} "
                   f"{p['draws']:>5} {p['elements']:>8} {p['resources']:>4} {p['fence_waits']:>3}  {' '.join(ids)}")
    out += ["", "(L load, C clear, x don't care / S store; draws: a blit's copies; elements: indices or",
            " vertices times instances, a blit's texels copied;",
            " res: useResource calls; fw: fence waits)", "", "pipelines"]
    keys = ("Instruction count", "ALU instruction count", "FP16 instruction count", "Temporary register count",
            "Spilled bytes", "Texture reads instruction count", "Device load instruction count",
            "Compilation time in milliseconds")
    out.append(f"{'':<4} {'stage':<9} {'instr':>6} {'alu':>5} {'fp16':>5} {'regs':>4} {'spill':>5} "
               f"{'tex':>4} {'load':>4} {'ms':>6}  shader")
    for a, pid in pipe_ids.items():
        fns = s["shaders"].get(a, [])
        st = s["stats"].get(a, {}) or {}
        for stage, prefix in (("Vertex Shader", ("vs_",)), ("Fragment Shader", ("ps_", "fs_"))):
            v = st.get(stage) or {}
            fn = next((f for f in fns if f.startswith(prefix)), "?")
            vals = [v.get(k) for k in keys]
            cells = [f"{x:>6}" if i == 0 else (f"{x:>6.1f}" if isinstance(x, float) else f"{x!s:>4}")
                     for i, x in enumerate(vals)]
            out.append(f"{pid:<4} {stage.split()[0]:<9} {vals[0]!s:>6} {vals[1]!s:>5} {vals[2]!s:>5} "
                       f"{vals[3]!s:>4} {vals[4]!s:>5} {vals[5]!s:>4} {vals[6]!s:>4} "
                       f"{(vals[7] or 0):>6.1f}  {fn}")
    return "\n".join(out) + "\n"


def calls(bundle):
    names = call_names()
    for c in records(os.path.join(bundle, "capture")):
        args = " ".join(hex(a) if isinstance(a, int) and a > 0xFFFFFF else str(a) for a in c.args)
        ret = f" -> {c.ret:#x}" if c.ret else ""
        print(f"{name_of(names, c.num)} {args}{ret}")


def build_names(dsc_dir):
    """The kDYFE table from the shared cache under DSC_DIR, in its order."""
    first = b"kDYFEMTLBlitCommandEncoder_setLabel\0"
    for root, _, files in os.walk(dsc_dir):
        for f in sorted(files):
            path = os.path.join(root, f)
            with open(path, "rb") as fh:
                data = fh.read()
            at = data.find(first)
            if at < 0:
                continue
            table = []
            for s in data[at:].split(b"\0"):
                if not s.startswith(b"kDYFE"):
                    break
                table.append(s[5:].decode())
            os.makedirs(os.path.dirname(NAMES), exist_ok=True)
            with open(NAMES, "w") as out:
                out.write("\n".join(table) + "\n")
            print(f"{len(table)} call names from {path} to {NAMES}")
            return 0
    sys.exit(f"{dsc_dir}: no kDYFE table in any file (fetch the shared cache: "
             "pymobiledevice3 developer fetch-symbols download DIR)")


def main(argv):
    if len(argv) == 2 and argv[0] == "names":
        return build_names(argv[1])
    if not argv or not os.path.isdir(argv[0]):
        sys.exit(__doc__)
    if "--calls" in argv:
        calls(argv[0])
        return 0
    s = summarize(argv[0])
    if "--json" in argv:
        s["shaders"] = {hex(k): v for k, v in s["shaders"].items()}
        s["stats"] = {hex(k): {st: {kk: vv for kk, vv in v.items() if kk != "Remarks"} for st, v in d.items()}
                      for k, d in s["stats"].items() if isinstance(d, dict)}
        s["textures"] = {hex(k): v for k, v in s["textures"].items() if k}
        print(json.dumps(s, indent=1, default=str))
        return 0
    print(report(s), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
