# Steam downloads: table-driven AES doubles device throughput

**Date:** 2026-09-25. **IPA:** dev, sha256
`15f4ea2e656c4df4e2acaef1220cadb8d973d2eceed38446893942ba493bec06`, installed in
place with `build/build-and-install --from app`. **Baseline:** the dev build
installed before it (the tree at `1cd0d8c`). **Change:**
`app/SteamClient/Sources/SteamClientKit/Crypto/AES.swift`.
**Result:** the chunk pipeline was CPU-bound on the phone, and AES decryption
was its largest cost. The new decryptor doubles a whole-title install
on the phone.

## Cause

Every chunk is AES-256-CBC decrypted, decompressed and SHA-1-checked on the
device's CPU. The old decryptor allocated two or three arrays per 16-byte block
(state copy, `invShiftRows` copy, the CBC chaining block). The new one uses
the equivalent inverse cipher with Td0..Td3 tables on words, decrypts CBC in place
back to front, and allocates nothing per block. It stays portable Swift: the same code
runs on the Linux host and iOS, and the FIPS-197 and end-to-end chunk tests pass unchanged.

Host, one core, `-O` (fixture chunk, 150 kB):

| stage | MB/s |
|---|---|
| AES, before | 29 |
| AES, after | 462 |
| zstd | 176 |
| deflate (zip chunks) | ~115 |
| LZMA (VZip chunks) | ~45 |
| SHA-1 | 590 |

Host CPU for the first 0.59 GB of depot 232250 (anonymous
`steamclient install --cancel-after-chunks 800`): 37.4 CPU-s/GB before, 21.8 after.
After the change, LZMA and deflate decoding take most of the remaining CPU.

## Device

Each run: `flock $PLAYPORT_BUILD/device.lock python3 harness/device/ui-device-run.py --wait 1500
--action install:APP --action uninstall:app-APP`, same Wi-Fi, one after another. Figures are the
engine's `stage:` summary line in `steam-drive.log`.

| title | before | after |
|---|---|---|
| FlatOut 2 (2990), 3.58 GB, 3481 chunks | 146.5 s, 24.4 MB/s | 66.8 s, 53.5 MB/s |
| #DRIVE Rally (2494780), 2.39 GB, 2728 chunks | 44.3 s, 53.6 MB/s | 25.6 s, 92.8 MB/s |

Every file was SHA-1-verified and every uninstall left nothing behind (`ui: done ... ok actions=2`).
FlatOut 2, an older depot, is still well below the link rate. Its limit is now
decompression (LZMA/deflate in portable Swift); faster decoders are the next step for older titles.

## Follow-up: LZMA, inflate and CRC32

**IPA:** dev, sha256 `0c6df31807958f2913e0b69e592b6a15738f284a1ba5c762991a05c7c31579c5`.
LZMA decodes into the output buffer, with every probability in one allocation and
the range coder in a local struct (no per-bit `try`). Truncated input is checked once
per symbol. Inflate decodes codes of up to 9 bits with one table lookup, reads a
64-bit bit buffer, and writes to a growable raw buffer. CRC32 is slicing-by-8. New
tests: a stored block after compressed blocks, and corrupted and truncated streams
for both decoders, which must end in a `SteamError`.

Host, one core, same fixtures:

| stage | before | after |
|---|---|---|
| LZMA | 50 MB/s | 68 MB/s |
| inflate | 132 MB/s | 534 MB/s |
| CRC32 | 704 MB/s | 3166 MB/s |

Host CPU for the depot 232250 sample: 16.8 CPU-s/GB (21.8 after the AES change).

Device, same method, two runs each:

| title | AES build | this build |
|---|---|---|
| FlatOut 2 (2990) | 53.5 MB/s | 62.3, 57.8 MB/s |
| #DRIVE Rally (2494780) | 92.8 MB/s | 85.6, 99.3 MB/s |

#DRIVE Rally's spread on one build (86 to 99 MB/s) is the run-to-run variation, so it
shows no change. FlatOut 2 gains about 12%, near that noise. LZMA is still around 2x
slower than liblzma, which decodes the same fixture stream at 149 MB/s on this host.

## Follow-up: chunk requests in flight

`InstallEngine.Options.concurrency`, the chunk requests in flight, which also sets
whole-file hash checks to a quarter of it. FlatOut 2 (2990), same method, on the new decoders:

| in flight | IPA sha256 | runs | peak RSS |
|---|---|---|---|
| 8 | `0c6df318…` | 62.3, 57.8 MB/s | not recorded |
| 16 | `990147b6…` | 77.0, 73.0 MB/s | 202, 196 MiB |
| 32 | `45cd1db9…` | 78.3, 73.1 MB/s | 246, 254 MiB |
| 16, as committed | `bb934b64c1fa6ce900f7d227bba1418aba014c040e15ba14630f79e239bd808d` | 69.0 MB/s | 180 MiB |

At 8, part of the link sat idle. Above 16 the network is the limit: 32 is no faster and
holds ~50 MiB more. No run logged a CDN or HTTP retry. The default is 16. Over the
three changes, FlatOut 2 went from 24.4 MB/s to about 70-77 MB/s on the phone.
