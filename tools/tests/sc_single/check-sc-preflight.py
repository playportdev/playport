#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the production file preflight with malformed files and synthetic PE data.

A synthetic SHA provider permits a positive fixture without publishing helper
bytes. Real SHA-256 remains available in the harness for private local checks.
"""
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

from source import NATIVE, SCRATCH, added_file


def define(name):
    return int(re.search(r'#define ' + name + r'\s+(0x[\da-fA-F]+|\d+)', NATIVE)[1], 0)


virtual = added_file('virtual_ios.c')
start = virtual.index('int pp_sc_single_preflight(')
preflight = virtual[start:virtual.index('\n}', start) + 2]

# PE layout definitions, not a platform Windows SDK dependency. Static asserts
# keep the parser harness byte-compatible with the Wine types it compiles with.
TYPES = r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <openssl/sha.h>
typedef uint64_t ULONG64, ULONG_PTR;
typedef size_t SIZE_T;
typedef struct { uint16_t e_magic; unsigned char rest[58]; int32_t e_lfanew; } IMAGE_DOS_HEADER;
typedef struct {
    uint16_t Machine, NumberOfSections;
    uint32_t TimeDateStamp, PointerToSymbolTable, NumberOfSymbols;
    uint16_t SizeOfOptionalHeader, Characteristics;
} IMAGE_FILE_HEADER;
typedef struct {
    uint16_t Magic; unsigned char version[2]; uint32_t size[3], entry, base_code;
    uint64_t ImageBase;
    uint32_t SectionAlignment, FileAlignment;
    uint16_t versions[6]; uint32_t Win32VersionValue, SizeOfImage, SizeOfHeaders, CheckSum;
    uint16_t Subsystem, DllCharacteristics;
    uint64_t stack_heap[4]; uint32_t LoaderFlags, NumberOfRvaAndSizes;
    struct { uint32_t rva, size; } directories[16];
} IMAGE_OPTIONAL_HEADER64;
typedef struct { uint32_t Signature; IMAGE_FILE_HEADER FileHeader; IMAGE_OPTIONAL_HEADER64 OptionalHeader; } IMAGE_NT_HEADERS;
typedef struct {
    char Name[8]; union { uint32_t VirtualSize; } Misc;
    uint32_t VirtualAddress, SizeOfRawData, PointerToRawData, PointerToRelocations, PointerToLinenumbers;
    uint16_t NumberOfRelocations, NumberOfLinenumbers; uint32_t Characteristics;
} IMAGE_SECTION_HEADER;
_Static_assert(sizeof(IMAGE_DOS_HEADER) == 64, "DOS header");
_Static_assert(sizeof(IMAGE_NT_HEADERS) == 264, "PE32+ NT header");
_Static_assert(offsetof(IMAGE_NT_HEADERS, OptionalHeader) == 24, "optional header offset");
_Static_assert(sizeof(IMAGE_SECTION_HEADER) == 40, "section header");
#define IMAGE_DOS_SIGNATURE 0x5a4d
#define IMAGE_NT_SIGNATURE 0x4550
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_NT_OPTIONAL_HDR64_MAGIC 0x20b
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
#define IMAGE_SCN_MEM_WRITE 0x80000000
#define IMAGE_SCN_MEM_SHARED 0x10000000
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define max(a,b) ((a) > (b) ? (a) : (b))
#define CC_SHA256_DIGEST_LENGTH 32
static unsigned char *CC_SHA256(const void *, uint32_t, unsigned char *);
#include "pp_sc_single.h"
static int synthetic_sha;
static const unsigned char *synthetic_image;
static unsigned char *CC_SHA256(const void *data, uint32_t len, unsigned char *digest)
{
    if (!synthetic_sha) return SHA256(data, len, digest);
    memset(digest, 0, 32);
    const unsigned char *p = data;
    if (!synthetic_image) synthetic_image = p - ios_sch_code[0].rva;
    for (size_t k = 0; k < ARRAY_SIZE(ios_sch_code); k++) {
        if (len != ios_sch_code[k].len || p != synthetic_image + ios_sch_code[k].rva) continue;
        size_t i;
        for (i = 0; i < len && p[i] == (unsigned char)((ios_sch_code[k].rva + i) * 131u + 7u); i++);
        if (i == len) { memcpy(digest, ios_sch_code[k].sha256, 32); break; }
    }
    return digest;
}
'''
MAIN = r'''
int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    synthetic_sha = argc > 2 && !strcmp(argv[2], "synthetic");
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 2;
    int ok = pp_sc_single_preflight(fd);
    close(fd);
    return ok ? 0 : 1;
}
'''


def fixture():
    image = bytearray(0x244000)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 0x3c, 0x80)
    image[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHI', image, 0x84, 0x8664, 3, 0x6a86d563)
    struct.pack_into('<H', image, 0x94, 240)
    opt = 0x98
    struct.pack_into('<H', image, opt, 0x20b)
    struct.pack_into('<Q', image, opt + 24, 0x140000000)
    struct.pack_into('<II', image, opt + 32, 0x1000, 0x200)
    struct.pack_into('<II', image, opt + 56, 0x244000, 0x400)
    sections = [(0x1000, 0x17f34c, 0x17f400, 0x60000020),
                (0x181000, 0x4b000, 0x4b000, 0x40000040),
                (0x1cc000, 0x43bc, 0x1a00, 0xc0000040)]
    raw = 0x400
    for i, (rva, virtual_size, raw_size, flags) in enumerate(sections):
        struct.pack_into('<IIII', image, 0x188 + i * 40 + 8, virtual_size, rva, raw_size, raw)
        struct.pack_into('<I', image, 0x188 + i * 40 + 36, flags)
        raw += raw_size
    table = NATIVE.split('} ios_sch_code[] =', 1)[1].split('};', 1)[0]
    ranges = []
    for rva, length in re.findall(r'\{ (IOS_SCH_\w+|0x[\da-f]+), (0x[\da-f]+),', table):
        rva = define(rva) if rva.startswith('IOS_') else int(rva, 0)
        length = int(length, 0)
        image[rva:rva + length] = bytes(((rva + i) * 131 + 7) & 255 for i in range(length))
        ranges.append((rva, length))
    assert len(ranges) == 48, len(ranges)
    for rva, target in [(0x182268 + 3 * 8, 0x51b0), (0x182268 + 4 * 8, 0x4330),
                        (0x182658 + 3 * 8, 0x4330), (0x182658 + 4 * 8, 0x51b0), (0x182688, 0x7e60)]:
        struct.pack_into('<Q', image, rva, 0x140000000 + target)
    packed = bytearray(image[:0x400])
    for rva, _, raw_size, _ in sections:
        packed.extend(image[rva:rva + raw_size])
    return packed, ranges


with tempfile.TemporaryDirectory(dir=SCRATCH, prefix='sc-preflight-') as td:
    folder = Path(td)
    (folder / 'pp_sc_single.h').write_text(NATIVE)
    (folder / 'test.c').write_text(TYPES + preflight + MAIN)
    binary = folder / 'test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-O2', '-Wall', '-Wextra',
                    '-Wno-unused-function', '-Wno-sign-compare', '-fsanitize=address,undefined',
                    str(folder / 'test.c'), '-lcrypto', '-o', str(binary)], check=True)
    good, ranges = fixture()

    def check(data, expect, synthetic=True):
        path = folder / 'helper.exe'
        path.write_bytes(data)
        result = subprocess.run([str(binary), str(path)] + (['synthetic'] if synthetic else []),
                                capture_output=True, text=True)
        assert result.returncode == expect, result.stderr
        assert path.read_bytes() == data, 'preflight changed the file'
        return result.stderr

    assert 'accepted' in check(good, 0)
    assert 'code bytes differ' in check(good, 1, synthetic=False)
    for rva, _ in ranges:
        changed = good.copy()
        changed[0x400 + rva - 0x1000] ^= 1
        assert 'fallback' in check(changed, 1)
    for offset in (0, 0x3c, 0x80, 0x84, 0x86, 0x88, 0x94, 0x98,
                   0x98 + 32, 0x98 + 36, 0x98 + 56,
                   0x188 + 12, 0x188 + 20,
                   0x400 + 0x17f400 + 0x1268 + 3 * 8):
        changed = good.copy()
        changed[offset] ^= 1
        check(changed, 1)
    for size in (0, 63, 0x80, 0x180, 0x400, len(good) - 1):
        check(good[:size], 1)
    changed = good.copy()
    struct.pack_into('<I', changed, 0x188 + 40 + 12, 0x1000)
    check(changed, 1)  # overlapping sections
    print('PASS: production preflight accepts the synthetic exact layout, rejects all 48 changed ranges, malformed/truncated/overlapping files, and never writes the file')
