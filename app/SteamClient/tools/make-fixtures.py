#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Regenerates Tests/SteamClientKitTests/Fixtures with independent encoders
(zlib, gzip, lzma, zstd from CPython 3.14, AES via `openssl enc`), so the
Swift decoders are checked against implementations they do not share code with.
Deterministic: the plaintext is derived from a fixed seed."""
import gzip, hashlib, json, lzma, os, random, struct, subprocess, sys, zlib
from compression import zstd

out = os.path.join(os.path.dirname(__file__), "..", "Tests", "SteamClientKitTests", "Fixtures")
os.makedirs(out, exist_ok=True)

def plaintext(n, seed):
    # Compressible but not trivial: words, runs and random bytes.
    r = random.Random(seed)
    words = [b"steam", b"depot", b"chunk", b"manifest", b"Playport", b"\x00\x01\x02", b"iOS"]
    buf = bytearray()
    while len(buf) < n:
        k = r.random()
        if k < 0.6: buf += r.choice(words)
        elif k < 0.8: buf += bytes([r.randrange(256)]) * r.randrange(1, 40)
        else: buf += bytes(r.randrange(256) for _ in range(r.randrange(1, 30)))
    return bytes(buf[:n])

def w(name, data):
    with open(os.path.join(out, name), "wb") as f: f.write(data)

meta = {}
plain = plaintext(150_000, 1)
# Tests compare against the SHA-1 and length below; the plaintext is not stored.
meta["plain_sha1"] = hashlib.sha1(plain).hexdigest()
meta["plain_len"] = len(plain)

# raw deflate + gzip
co = zlib.compressobj(9, zlib.DEFLATED, -15)
w("plain.deflate", co.compress(plain) + co.flush())
w("plain.gz", gzip.compress(plain, mtime=0))
# A stored block after compressed ones: a sync flush (which ends in an empty
# stored block), then a hand-made final stored block of 1000 bytes.
co = zlib.compressobj(9, zlib.DEFLATED, -15)
stored = plain[60_000:61_000]
w("mixed.deflate", co.compress(plain[:60_000]) + co.flush(zlib.Z_SYNC_FLUSH)
  + b"\x01" + struct.pack("<HH", len(stored), len(stored) ^ 0xFFFF) + stored)
meta["mixed_sha1"] = hashlib.sha1(plain[:61_000]).hexdigest()

# zstd: several levels, one frame with checksum, one multi-block
for lvl in (1, 3, 19):
    w(f"plain.l{lvl}.zst", zstd.compress(plain, level=lvl))
w("plain.check.zst", zstd.compress(plain, options={zstd.CompressionParameter.checksum_flag: 1}))
small = plaintext(1500, 2)
meta["small_sha1"] = hashlib.sha1(small).hexdigest()
w("small.zst", zstd.compress(small, level=3))

# VZip (Steam's LZMA container): "VZa" + u32 crc + 5 props + raw LZMA + u32 crc + u32 size + "zv"
alone = lzma.compress(plain, format=lzma.FORMAT_ALONE, preset=6)
props, raw = alone[:5], alone[13:]  # .lzma header: 5 props + 8-byte size
crc = zlib.crc32(plain)
w("plain.vzip", b"VZa" + struct.pack("<I", crc) + props + raw + struct.pack("<II", crc, len(plain)) + b"zv")

# VZstd: "VSZa" + u32 crc + zstd frame + u32 crc + u32 size + 4 zero bytes + "zsv"
w("plain.vzstd", b"VSZa" + struct.pack("<I", crc) + zstd.compress(plain, level=3) + struct.pack("<II", crc, len(plain)) + b"\0\0\0\0" + b"zsv")

# Steam symmetric encryption of the VZstd chunk: AES-ECB(iv) || AES-CBC-PKCS7(iv, data)
key = bytes(range(32))
iv = bytes(range(100, 116))
def openssl(args, data):
    return subprocess.run(["openssl", "enc"] + args, input=data, capture_output=True, check=True).stdout
chunk_plain = open(os.path.join(out, "plain.vzstd"), "rb").read()
enc_iv = openssl(["-aes-256-ecb", "-nopad", "-K", key.hex()], iv)
body = openssl(["-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex()], chunk_plain)
w("plain.vzstd.enc", enc_iv + body)
meta["chunk_key_hex"] = key.hex()
meta["plain_adler32_seed0"] = (zlib.adler32(plain, 0))

with open(os.path.join(out, "fixtures.json"), "w") as f: json.dump(meta, f, indent=2, sort_keys=True)
print("fixtures written to", os.path.normpath(out))
