# SPDX-License-Identifier: GPL-3.0-or-later
"""build/air-helpers/probe/title_shaders.py: finding DXBC containers inside a
title's cache files. No airconv; the conversion itself needs the host build
(build/air-helpers/air-helper-port.sh ROOT host).

  python3 -m unittest discover -s tools/tests
"""

import importlib.util
import os
import struct
import tempfile
import unittest

HERE = os.path.dirname(__file__)
spec = importlib.util.spec_from_file_location(
    "title_shaders", os.path.join(HERE, "..", "..", "build", "air-helpers", "probe", "title_shaders.py"))
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)


def dxbc(kind, body=b"", tag=b"SHEX"):
    """A minimal container: an ISGN chunk and a shader chunk of program type `kind`."""
    isgn = b"ISGN" + struct.pack("<I", 8) + b"\0" * 8
    shader = tag + struct.pack("<I", 8 + len(body)) + struct.pack("<II", (kind << 16) | 0x50, 2) + body
    chunks = [isgn, shader]
    head = 32 + 4 * len(chunks)
    offs, o = [], head
    for c in chunks:
        offs.append(o)
        o += len(c)
    return (b"DXBC" + b"\x11" * 16 + struct.pack("<III", 1, o, len(chunks)) +
            struct.pack("<%dI" % len(chunks), *offs) + b"".join(chunks))


class ContainersTest(unittest.TestCase):
    def test_kinds_and_junk(self):
        vs, ps, cs = dxbc(1), dxbc(0, b"\1" * 12), dxbc(5, tag=b"SHDR")
        # a stray "DXBC" in junk, a container whose size runs past the end,
        # and one with no shader chunk are all skipped
        truncated = dxbc(2)[:-4]
        no_shader = dxbc(1).replace(b"SHEX", b"STAT")
        data = b"junkDXBC" + b"\0" * 40 + vs + b"\xff" * 7 + ps + no_shader + cs + truncated
        found = [(k, b) for _, b, k in ts.containers(data)]
        self.assertEqual(found, [("vs", vs), ("ps", ps), ("cs", cs)])

    def test_extract_dedupes_and_matches(self):
        with tempfile.TemporaryDirectory() as d:
            title, out = os.path.join(d, "title"), os.path.join(d, "out")
            os.makedirs(os.path.join(title, "content"))
            hs, ds = dxbc(3), dxbc(4)
            with open(os.path.join(title, "content", "shader.cache"), "wb") as f:
                f.write(b"hdr" + hs + ds + hs)
            with open(os.path.join(title, "content", "texture.cache"), "wb") as f:
                f.write(dxbc(0))
            names, sources = ts.extract(title, out, r"shader")
            self.assertEqual(sorted(n.split("-")[0] for n in names), ["ds", "hs"])
            self.assertEqual(dict(sources), {os.path.join("content", "shader.cache"): 3})
            self.assertEqual(sorted(os.listdir(out)), sorted(names))
            names, _ = ts.extract(title, out)
            self.assertEqual(len(names), 3)


if __name__ == "__main__":
    unittest.main()
