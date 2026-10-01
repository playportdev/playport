# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/gputrace.py: MTSP records, the keyed store and the descriptors, on
records built here in the layout the reader documents (no capture is committed)."""

import os
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gputrace  # noqa: E402


def record(num, sig, payload, flags=8):
    s = sig.encode() + b"\0"
    s += b"\0" * (-len(s) % 4)
    body = struct.pack("<i", num) + b"\0" * 24 + struct.pack("<I", flags) + s + payload
    return struct.pack("<I", len(body) + 4) + body


class Records(unittest.TestCase):
    def test_arguments_return_and_backtrace(self):
        trace = struct.pack("<II", 2, 8) + struct.pack("<QQ", 1, 2)
        # a receiver, an object, two unsigned longs, then the backtrace
        r1 = record(-16278, "Ctulul", struct.pack("<QQQQ", 0x1000, 0x2000, 16, 2) + trace)
        # a receiver, a key, a returned object
        key = b"ABCDEF0123456789\0\0\0\0"
        r2 = record(-16353, "CU", struct.pack("<Q", 0x3000) + key + struct.pack("<IQ", 0x74, 0x4000) + trace,
                    flags=9)
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"MTSP\0\4\0\0" + r1 + r2)
        try:
            calls = list(gputrace.records(f.name))
        finally:
            os.remove(f.name)
        self.assertEqual(calls[0].args, [0x1000, 0x2000, 16, 2])
        self.assertIsNone(calls[0].ret)
        self.assertEqual(calls[1].args, [0x3000, "ABCDEF0123456789"])
        self.assertEqual(calls[1].ret, 0x4000)

    def test_names_count_from_the_metal_base(self):
        names = ["a", "b", "c"]
        self.assertEqual(gputrace.name_of(names, -16384 + 2), "c")
        self.assertEqual(gputrace.name_of(names, -10240), "#-10240")


class Store(unittest.TestCase):
    def test_index_and_store(self):
        with tempfile.TemporaryDirectory() as d:
            blobs = {"K1": b"one" * 10, "K2": b"two"}
            store, entries = b"", b""
            for k, v in blobs.items():
                z = zlib.compress(v)
                entries += struct.pack("<6I", len(v), len(z), len(store), 0, 1, 0)
                store += z
            slots = 4
            idx = b"xdic" + struct.pack("<IIII", 0, slots, 2, 2) + b"\xff" * 12 * slots + entries
            idx += struct.pack("<3H", 3, 3, 0) + b"K1\0K2\0"
            open(os.path.join(d, "index"), "wb").write(idx)
            open(os.path.join(d, "store0"), "wb").write(store)
            self.assertEqual(gputrace.load_store(d), blobs)


class Descriptors(unittest.TestCase):
    def test_pass_descriptor(self):
        ones = 0xFFFFFFFFFFFFFFFF
        q = [0] * 73
        q[0], q[2], q[3], q[11], q[12] = 0xE1, 0, 0x10, 2, 1   # colour 0: clear, store
        q[19] = ones                                         # no more colour attachments
        q[20], q[28], q[29] = 0x20, 0, 0                     # depth: don't care twice
        q[58], q[59] = 1564, 720
        d = gputrace.pass_desc(struct.pack("<73Q", *q))
        self.assertEqual(d["color0"], {"texture": 0x10, "load": "C", "store": "S"})
        self.assertEqual((d["depth"]["load"], d["depth"]["store"]), ("x", "x"))
        self.assertIsNone(d["stencil"])
        self.assertEqual((d["width"], d["height"]), (1564, 720))

    def test_pass_descriptor_without_colour(self):
        ones = 0xFFFFFFFFFFFFFFFF
        q = [0] * 56
        q[0], q[2] = 0xE1, ones
        q[3], q[11], q[12] = 0x30, 2, 1                      # depth: clear, store
        q[41], q[42] = 1564, 720
        d = gputrace.pass_desc(struct.pack("<56Q", *q))
        self.assertIsNone(d["color0"])
        self.assertEqual(d["depth"], {"texture": 0x30, "load": "C", "store": "S"})
        self.assertEqual((d["width"], d["height"]), (1564, 720))

    def test_texture_descriptor(self):
        q = [0xE1, 2, 70, 1564, 720, 1, 1, 1, 1, 0, 0, 5]
        t = gputrace.texture_desc(struct.pack("<12Q", *q))
        self.assertEqual((t["format"], t["width"], t["height"]), ("RGBA8", 1564, 720))


if __name__ == "__main__":
    unittest.main()
