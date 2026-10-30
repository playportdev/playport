#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Writes XboxClientKitTests/Fixtures/msixvc2-synthetic.msixvc2: a small MSIXVC2
package with the real layout (Xodus pull request #219 e8194a8; LukeFZ/XvdTool.Streaming
pull request #3 99db4dd for the CBOR model) and a test key, and prints the test key.

Independent of the Swift reader: Python's zipfile, zlib and `cryptography`'s AES.
Deterministic: run it again and the bytes are the same.

  python3 app/XboxClient/Tests/msixvc2-fixture.py
"""
import hashlib
import hmac
import os
import random
import struct
import uuid
import zipfile
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

OUT = os.path.join(os.path.dirname(__file__), "XboxClientKitTests", "Fixtures", "msixvc2-synthetic.msixvc2")
rng = random.Random(503)


def rand(n):
    return bytes(rng.getrandbits(8) for _ in range(n))


def guid():
    return str(uuid.UUID(bytes=rand(16), version=4))


# The licence's content key (test only) and the package's identity.
MASTER = bytes(range(0x40, 0x60))
KEY_ID = "5e0a4c51-8f1d-4b7a-9c1e-0d5a3b2c1f00"
CONTENT_ID = "2c6a9d8e-31f4-4b0a-8e57-1f2a3b4c5d6e"
FULFILLMENT_ID = "7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6"

# CBOR (RFC 8949), definite lengths.


class Tag:
    def __init__(self, tag, value):
        self.tag, self.value = tag, value


def head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if n < 1 << (8 * size):
            return bytes([major << 5 | info]) + n.to_bytes(size, "big")
    raise ValueError(n)


def cbor(v):
    if isinstance(v, bool):
        return bytes([0xF5 if v else 0xF4])
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, bytes):
        return head(2, len(v)) + v
    if isinstance(v, str):
        b = v.encode()
        return head(3, len(b)) + b
    if isinstance(v, list):
        return head(4, len(v)) + b"".join(cbor(x) for x in v)
    if isinstance(v, dict):
        return head(5, len(v)) + b"".join(cbor(k) + cbor(x) for k, x in v.items())
    if isinstance(v, Tag):
        return head(6, v.tag) + cbor(v.value)
    raise TypeError(v)


def described(tag, v):
    return cbor(Tag(55799, Tag(tag, v)))


SHA256, SHA384, SHA512 = 18540, 18513, 18512
XVCB, XVCC, XVCP, XVCZ = 0x58564342, 0x58564343, 0x58564350, 0x5856435A


def digest(kind, data):
    return Tag(kind, {SHA256: hashlib.sha256, SHA384: hashlib.sha384, SHA512: hashlib.sha512}[kind](data).digest())


def cbc(key, iv, data):
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return e.update(data) + e.finalize()


def next_iv(iv):
    return ((int.from_bytes(iv, "big") + 1) % (1 << 128)).to_bytes(16, "big")


def pad16(b):
    return b + bytes(-len(b) % 16)


# Key source: the licence key derives (SP800-108 HMAC-SHA256) a key that unwraps
# (AES-256-CBC, the source's IV) the package key; that unwraps each segment's key.
KDF_CONTEXT = rand(24)
SOURCE_IV = rand(16)
PACKAGE_KEY = rand(32)
derived = hmac.new(MASTER, b"\0\0\0\1MSIXVC2:PackageData:AES_256_CBC\0" + KDF_CONTEXT + b"\0\0\1\0", "sha256").digest()
SOURCES = [
    {288: KEY_ID, 287: 0, 284: 1024, 286: KDF_CONTEXT, 285: 256, 7: SOURCE_IV, 6: cbc(derived, SOURCE_IV, PACKAGE_KEY), 259: 256},
    {288: guid(), 287: 1, 284: 1024, 286: rand(24), 285: 256, 7: rand(16), 6: rand(32), 259: 256},
]


class Box:
    def __init__(self, name, seal):
        self.name, self.seal, self.data, self.listed = name, seal, bytearray(b"XBOXBOX\0"), []

    def finish(self):
        manifest = described(XVCB, {256: {257: 1, 258: 0}, 25: self.name, 29: self.listed})
        at = len(self.data)
        seal = described(XVCZ, {289: XVCB, 1: digest(self.seal, manifest)})
        return bytes(self.data) + manifest + seal + struct.pack("<QI", at, len(manifest))


boxes = [Box("box0", SHA256), Box("box1", SHA512)]


KEYS = {}  # a segment's box offset -> its key, so another file can list the same bytes


def segment(box_index, plain, iv, compress=False, encrypt=True):
    """Stores one segment in a box; returns its reference and the rolling IV after it."""
    box = boxes[box_index]
    h = digest(SHA384, plain)
    body = plain
    ref = {1: h, 2: len(plain)}
    if compress:
        c = zlib.compressobj(9, zlib.DEFLATED, -15)
        body = c.compress(plain) + c.flush()
        ref[3], ref[4] = 1, len(body)
    if encrypt:
        key = rand(32)
        KEYS[(box_index, len(box.data))] = key
        ref[6] = cbc(PACKAGE_KEY, iv, key)
        iv = next_iv(iv)
        body = cbc(key, h.value[:16], pad16(body))
    ref.update({8: digest(SHA384, body), 9: box_index, 10: len(box.data), 11: len(body)})
    box.data += body
    box.listed.append({k: v for k, v in ref.items() if k != 6})  # the reference without its wrapped key
    return ref, iv


def again(ref, iv):
    """The same stored segment listed by another file: its key wrapped under this file's IV."""
    ref = dict(ref)
    if 6 in ref:
        ref[6] = cbc(PACKAGE_KEY, iv, KEYS[(ref[9], ref[10])])
        iv = next_iv(iv)
    return ref, iv


def text(n, seed):
    words = [b"xbox", b"playport", b"segment", b"box", b"chunk", b"licence", b"file"]
    r = random.Random(seed)
    return b" ".join(r.choice(words) for _ in range(n))[:n]


CONFIG = (b'<?xml version="1.0" encoding="utf-8"?>\r\n<Game configVersion="1"><Identity Name="Playport.TestGame" '
          b'Publisher="CN=Playport" Version="1.2.3.0"/><TitleId>1234ABCD</TitleId><MSAAppId>0000000012345678</MSAAppId>'
          b'<ExecutableList><Executable Name="Game.exe" Id="Game"/></ExecutableList>'
          b'<ExtendedAttributeList><ExtendedAttribute Name="Scid" Value="00000000-0000-0000-0000-00001234abcd"/>'
          b'</ExtendedAttributeList></Game>\r\n')
FILES = {}  # path -> plaintext, for the tests' expectations


class Chunk:
    """Chunks/<id>.cbor: files in order; the rolling IV carries from file to file."""

    def __init__(self, cid):
        self.id, self.iv, self.files, self.names = cid, rand(16), [], []
        self.initial = self.iv

    def add(self, name, parts, own_iv=None):
        """parts: (box, bytes, compress, encrypt) or ("again", ref)."""
        iv = own_iv if own_iv is not None else self.iv
        refs, data = [], b""
        for part in parts:
            if part[0] == "again":
                ref, iv = again(part[1], iv)
                data += part[2]
            else:
                ref, iv = segment(part[0], part[1], iv, part[2], part[3])
                data += part[1]
            refs.append(ref)
        self.iv = iv
        entry = {24: len(self.files), 35: self.id, 2: len(data), 1: digest(SHA384, data)}
        if own_iv is not None:
            entry[27] = own_iv
        if refs:
            entry[29] = refs
        self.files.append(entry)
        self.names.append(name)
        FILES[name.replace("\\", "/")] = data
        return refs

    def cbor(self):
        return described(XVCC, {24: self.id, 27: self.initial, 28: self.files})


exe = b"MZ\x90\x00" + rand(9000)
level = text(20000, 1) + rand(3000)
shared = rand(5000)

c0, c1 = Chunk(0), Chunk(1)
c0.add("Game.exe", [(0, exe[:4000], False, True), (0, exe[4000:7000], True, True), (1, exe[7000:], False, True)])
c0.add("MicrosoftGame.config", [(0, CONFIG, True, True)])
level_refs = c0.add("Data\\level1.bin", [(1, level[:12000], True, True), (0, shared, False, True), (1, level[12000:], False, True)],
                    own_iv=rand(16))
c0.add("Data\\empty.txt", [])
c1.add("Data\\Sub\\readme.txt", [(1, b"Read me: an unencrypted segment.\n", False, False)])
c1.add("Data/Sub/shared.bin", [("again", level_refs[1], shared)])

# The package's rolling IV: one step per chunk secret, in chunk order.
PACKAGE_IV = rand(16)
iv, chunks = PACKAGE_IV, []
for c in (c0, c1):
    secret = described(XVCC, {24: c.id, 28: [{25: n} for n in c.names]})
    ref, iv = segment(0, secret, iv, compress=(c.id == 1))
    chunks.append({24: c.id, 2: sum(e[2] for e in c.files), 26: ref})

package = described(XVCP, {
    256: {257: 1, 258: 0, 290: ["Playport fixture"]},
    27: PACKAGE_IV,
    260: CONTENT_ID,
    279: FULFILLMENT_ID,
    280: guid(),
    261: {257: 1, 258: 2, 267: 3, 268: 0, 269: guid()},
    281: {257: 10, 258: 0, 267: 19041, 268: 0, 269: guid()},
    282: "9TESTGAME002",
    283: 1,
    263: {259: 512, 291: 769},
    262: [SOURCES],
    264: [{25: b.name} for b in boxes],
    265: chunks,
})


def put(z, name, data, method, zip64=False):
    info = zipfile.ZipInfo(name, date_time=(2026, 10, 30, 0, 0, 0))
    info.compress_type = method
    with z.open(info, "w", force_zip64=zip64) as f:
        f.write(data)


os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, "w") as z:
    put(z, "[Content_Types].xml", b'<?xml version="1.0"?><Types/>', zipfile.ZIP_DEFLATED)
    put(z, "XboxPackage.cbor", package, zipfile.ZIP_DEFLATED)
    put(z, "Chunks/0.cbor", c0.cbor(), zipfile.ZIP_DEFLATED)
    put(z, "Chunks/1.cbor", c1.cbor(), zipfile.ZIP_STORED)
    put(z, "Boxes/box0", boxes[0].finish(), zipfile.ZIP_STORED)
    put(z, "Boxes/box1", boxes[1].finish(), zipfile.ZIP_STORED, zip64=True)

print(OUT, os.path.getsize(OUT), "bytes")
print("licence key id", KEY_ID, "key", MASTER.hex())
for name, data in sorted(FILES.items()):
    print(f"{name}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}")
