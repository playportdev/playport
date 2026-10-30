# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the image cache copy's rules shipped in madeira-unix 0235 and 0238 (decision 0167,
PLA-476).

The layout must give the bytes map_image_into_view gives the view before any write: the test replays
Wine's steps (map_pe_header's mmap and read, its zeroes to the aligned header end, each section's
sector-rounded read and the zeroes after it) on a synthetic file, assembles the copy as the writer thread
does (ppic_overlap over 1 MiB blocks), and compares the two byte for byte."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0235-virtual-map-a-large-x86-64-image-from-a-re-laid-out-.patch"
# Later hunks to the header: the ctime in the name and the sampled check (0238).
LATER = [ROOT / "patches/madeira-unix/0238-virtual-key-an-image-s-cache-copy-by-its-ctime-too-a.patch"]


def added_header():
    section = PATCH.read_text().split("diff --git a/build/ntdll-unix/pp_img_cache.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_img_cache.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define HOST_MASK 0x3fffull
#define PAGE_MASK 0xfffull
#define ROUND(a, s, m) ppic_round(a, s, m)

/* Wine's steps into view[0..total) from file[0..fsize) (virtual_ios.c map_pe_header and the section
 * loop of map_image_into_view, with mmap's whole host pages and pread's short reads). */
static int wine_view(unsigned char *view, uint64_t total, const unsigned char *file, uint64_t fsize,
                     const struct ppic_section *s, unsigned n, uint64_t header_size, uint64_t header_map_size,
                     uint64_t align_mask)
{
    uint64_t hmap = header_map_size & ~HOST_MASK, header_end = ROUND(0, header_size, align_mask), i;
    memset(view, 0, total);
    if (hmap) {
        memcpy(view, file, hmap < fsize ? hmap : fsize);      /* mmap: whole host pages of the file */
        if (header_size > hmap) memcpy(view + hmap, file + hmap, header_size - hmap);
    } else memcpy(view, file, header_size);
    memset(view + header_size, 0, header_end - header_size);
    for (i = 0; i < n; i++) {
        uint64_t map_size = ROUND(0, s[i].virt_size ? s[i].virt_size : s[i].raw_size, align_mask);
        uint64_t file_start = s[i].raw_ptr & ~0x1ffull, file_size = ROUND(s[i].raw_ptr, s[i].raw_size, 0x1ff), end;
        if (file_size > map_size) file_size = map_size;
        end = s[i].va + ROUND(s[i].va, map_size, align_mask);
        if (s[i].va > total || end > total || end < s[i].va) return -1;
        if (!s[i].raw_ptr || !file_size) continue;
        end = file_start + file_size;
        if (s[i].raw_ptr >= fsize || end > ((fsize + 0x1ff) & ~0x1ffull) || end < file_start) return -1;
        /* pread: a read short at the end of the file */
        memcpy(view + s[i].va, file + file_start, end <= fsize ? file_size : fsize - file_start);
        if (file_size & align_mask) {
            end = ROUND(0, file_size, align_mask);
            if (end > map_size) end = map_size;
            memset(view + s[i].va + file_size, 0, end - file_size);
        }
    }
    return 0;
}

/* The writer thread's copy: 1 MiB blocks, each zeroed, then every run's part in it. Small blocks too,
 * so runs cross block edges. */
static void copy(unsigned char *out, uint64_t out_size, const unsigned char *file, uint64_t fsize,
                 const struct ppic_run *r, int nruns, uint64_t block)
{
    uint64_t b;
    int k;
    for (b = 0; b < out_size; b += block) {
        uint64_t size = out_size - b < block ? out_size - b : block, in_block, in_run, len;
        memset(out + b, 0, size);
        for (k = 0; k < nruns; k++) {
            if (!(len = ppic_overlap(&r[k], b, size, &in_block, &in_run))) continue;
            if (r[k].zero) { memset(out + b + in_block, 0, len); continue; }
            if (r[k].off + in_run >= fsize) continue;
            if (r[k].off + in_run + len > fsize) len = fsize - (r[k].off + in_run);   /* pread short */
            memcpy(out + b + in_block, file + r[k].off + in_run, len);
        }
    }
}

/* The sampled check (0238) as ios_img_cache_map makes it: the file's bytes at each point (a read short
 * at its end compares what was read) against the copy's at the point's rva. */
static int samples_equal(const unsigned char *out, const unsigned char *file, uint64_t fsize,
                         const struct ppic_run *p, unsigned m)
{
    unsigned k;
    for (k = 0; k < m; k++) {
        uint64_t got = p[k].off >= fsize ? 0 : (p[k].off + p[k].len > fsize ? fsize - p[k].off : p[k].len);
        if (got && memcmp(out + p[k].rva, file + p[k].off, got)) return 0;
    }
    return 1;
}

static void check(const struct ppic_section *s, unsigned n, uint64_t fsize, uint64_t total, uint64_t header_size,
                  uint64_t header_map_size, uint64_t align_mask)
{
    unsigned char *file = malloc(fsize), *view = malloc(total), *out;
    uint64_t out_size = ppic_file_size(total, HOST_MASK), i;
    struct ppic_run r[64], p[PPIC_SAMPLES];
    int nruns = ppic_layout(s, n, fsize, total, header_size, header_map_size, align_mask, HOST_MASK, r, 64), k, l;
    unsigned m;
    for (i = 0; i < fsize; i++) file[i] = (unsigned char)(i * 2654435761u >> 13) | 1;   /* never zero */
    assert(nruns > 0);
    assert(wine_view(view, total, file, fsize, s, n, header_size, header_map_size, align_mask) == 0);
    out = malloc(out_size);
    copy(out, out_size, file, fsize, r, nruns, 1u << 20);
    assert(!memcmp(out, view, total));
    for (i = total; i < out_size; i++) assert(!out[i]);
    copy(out, out_size, file, fsize, r, nruns, 0x3000);
    assert(!memcmp(out, view, total));

    /* The sample points: in a file run, at most 4 KiB, under no later run, in rva order; a right copy
     * passes, and a byte rewritten at any point fails. */
    m = ppic_samples(r, (unsigned)nruns, PPIC_SAMPLES, p);
    assert(m >= 1 && m <= PPIC_SAMPLES);
    for (k = 0; k < (int)m; k++) {
        int in_run = 0, later = 0;
        assert(p[k].len && p[k].len <= PPIC_SAMPLE_SIZE && !p[k].zero);
        assert(!k || p[k].rva > p[k - 1].rva);
        for (l = 0; l < nruns; l++) {
            if (!r[l].zero && p[k].rva >= r[l].rva && p[k].rva + p[k].len <= r[l].rva + r[l].len &&
                p[k].off - r[l].off == p[k].rva - r[l].rva) in_run = l + 1;
        }
        assert(in_run);
        for (l = in_run; l < nruns; l++)
            if (r[l].rva < p[k].rva + p[k].len && p[k].rva < r[l].rva + r[l].len) later = 1;
        assert(!later);
    }
    assert(samples_equal(out, file, fsize, p, m));
    for (k = 0; k < (int)m; k++) {
        if (p[k].off >= fsize) continue;
        file[p[k].off] ^= 0x80;                         /* rewritten in place */
        assert(!samples_equal(out, file, fsize, p, m));
        file[p[k].off] ^= 0x80;
    }
    free(file); free(view); free(out);
}

int main(void) {
    /* Stock libcef's shape: 4 KiB sections at RVAs off the 16 KiB grid, 0x200 file alignment,
     * file offsets not congruent to their RVAs, sizes not sector multiples. */
    struct ppic_section cef[] = {
        { 0x1000, 0x600, 0x803a00, 0x8039f4, 0x60000020 },        /* .text */
        { 0x805000, 0x804000, 0x123401, 0x1233f0, 0x40000040 },   /* .rdata */
        { 0x929000, 0x927600, 0x2200, 0x5a000, 0xc0000040 },      /* .data, mostly bss */
        { 0x983000, 0x929800, 0x4c000, 0x4be10, 0x40000040 },     /* .pdata */
        { 0x9cf000, 0, 0, 0x1000, 0xc0000040 },                   /* uninitialised: no file bytes */
        { 0x9d0000, 0x975800, 0x3e00, 0x3c9c, 0x42000040 },       /* .reloc, its end in the last sector */
    };
    uint64_t fsize = 0x975800 + 0x3c9c;   /* the file ends inside .reloc's last sector */
    struct ppic_section shared = { 0x1000, 0x600, 0x200, 0x200, 0xc0000040 | PPIC_SCN_SHARED_WRITE };
    struct ppic_run r[64];
    char name[128];

    /* The layout equals Wine's view: header read only (map size under a host page), and header mmapped
     * whole host pages (the bytes past SizeOfHeaders up to the aligned header end are zeroed after it). */
    check(cef, 6, fsize, 0x9d4000, 0x400, 0x1000, PAGE_MASK);
    check(cef, 6, fsize, 0x9d4000, 0x400, 0x8000, PAGE_MASK);
    /* Section alignment over the guest page: the zeroes after a section's bytes go to its alignment. */
    {
        struct ppic_section al[] = { { 0x10000, 0x400, 0x1234, 0x1234, 0x60000020 },
                                     { 0x20000, 0x1800, 0x200, 0x8000, 0xc0000040 } };
        check(al, 2, 0x1a00, 0x30000, 0x400, 0x1000, 0xffff);
    }

    /* Runs: the header, its zeroes, then each section with file bytes; a short layout refuses. */
    assert(ppic_layout(cef, 6, fsize, 0x9d4000, 0x400, 0x1000, PAGE_MASK, HOST_MASK, r, 64) == 11);
    assert(r[0].rva == 0 && r[0].len == 0x400 && !r[0].zero && r[1].rva == 0x400 && r[1].zero);
    assert(r[2].rva == 0x1000 && r[2].off == 0x600 && r[2].len == 0x803a00);
    assert(ppic_layout(cef, 6, fsize, 0x9d4000, 0x400, 0x1000, PAGE_MASK, HOST_MASK, r, 4) == -1);
    /* What Wine refuses, the layout refuses: a section past the view, raw data past the file. */
    assert(ppic_layout(cef, 6, fsize, 0x9d0000, 0x400, 0x1000, PAGE_MASK, HOST_MASK, r, 64) == -1);
    assert(ppic_layout(cef, 6, 0x975000, 0x9d4000, 0x400, 0x1000, PAGE_MASK, HOST_MASK, r, 64) == -1);
    assert(ppic_layout(&shared, 1, fsize, 0x9d4000, 0x400, 0x1000, PAGE_MASK, HOST_MASK, r, 64) == -1);

    /* Eligible: x86-64, 64 MiB or more, an alignment under the host page, no shared writable section. */
    assert(ppic_eligible(1, 0xefbe000, 0x1000, 0x200, HOST_MASK, 0, cef, 6));
    assert(!ppic_eligible(0, 0xefbe000, 0x1000, 0x200, HOST_MASK, 0, cef, 6));            /* not x86-64 */
    assert(!ppic_eligible(1, (64ull << 20) - 1, 0x1000, 0x200, HOST_MASK, 0, cef, 6));    /* too small */
    assert(ppic_eligible(1, 64ull << 20, 0x1000, 0x200, HOST_MASK, 0, cef, 6));
    assert(!ppic_eligible(1, 0xf690000, 0x4000, 0x4000, HOST_MASK, 0, cef, 6));          /* 16 KiB: maps as is */
    assert(ppic_eligible(1, 0xf690000, 0x4000, 0x200, HOST_MASK, 0, cef, 6));
    assert(!ppic_eligible(1, 0xefbe000, 0x1000, 0x200, HOST_MASK, 1, cef, 6));           /* removable */
    assert(!ppic_eligible(1, 0xefbe000, 0x1000, 0x200, HOST_MASK, 0, &shared, 1));

    /* The name: the file's identity with its ctime (0238) and the view size; the copy's size: whole
     * host pages. A v1 name is an older version's copy. */
    assert(ppic_name(name, sizeof name, 0x1000002, 0x2a5f1, 0xedcd000, 1761000000, 123456789, 1761000100, 5,
                     0xefbe000) < (int)sizeof name);
    assert(!strcmp(name, "v2-1000002-2a5f1-edcd000-1761000000.123456789-1761000100.000000005-efbe000.img"));
    assert(ppic_current(name) && !ppic_current("v1-1000002-2a5f1-edcd000-1761000000.123456789-efbe000.img"));
    assert(!ppic_current("v") && !ppic_current(""));
    /* The longest identity still fits the 128-byte names the runtime keeps. */
    assert(ppic_name(name, sizeof name, UINT64_MAX, UINT64_MAX, UINT64_MAX, INT64_MAX, 999999999, INT64_MAX,
                     999999999, UINT64_MAX) >= (int)sizeof name);
    assert(ppic_name(name, sizeof name, 0xffffffffu, 0xffffffffffffull, 0xffffffffull, 4102444800ll, 999999999,
                     4102444800ll, 999999999, 0xffffffffull) < (int)sizeof name);

    /* Sample points on libcef's runs: 16, spread over the whole image; the header run (its mmapped page
     * past SizeOfHeaders is zeroed by a later run) gives none there. */
    {
        struct ppic_run p[PPIC_SAMPLES + 4];
        int nr = ppic_layout(cef, 6, fsize, 0x9d4000, 0x400, 0x8000, PAGE_MASK, HOST_MASK, r, 64);
        unsigned m = ppic_samples(r, (unsigned)nr, PPIC_SAMPLES, p), k;
        assert(nr > 0 && m == PPIC_SAMPLES);
        assert(p[0].rva < 0x100000 && p[m - 1].rva > 0x900000);
        for (k = 0; k < m; k++) assert(p[k].rva >= 0x1000);
        assert(ppic_samples(r, (unsigned)nr, 40, p) == PPIC_SAMPLES);     /* at most PPIC_SAMPLES */
        assert(ppic_samples(r, (unsigned)nr, 0, p) == 0);
        assert(ppic_samples(r, 0, PPIC_SAMPLES, p) == 0);
        r[0] = (struct ppic_run){ 0, 0, 0x1000, 1 };                      /* zeroes only: nothing to sample */
        assert(ppic_samples(r, 1, PPIC_SAMPLES, p) == 0);
        r[0] = (struct ppic_run){ 0x2000, 0x400, 0x300, 0 };              /* a tiny run: one point */
        assert(ppic_samples(r, 1, PPIC_SAMPLES, p) == 1 && p[0].rva == 0x2000 && p[0].off == 0x400 &&
               p[0].len == 0x300);
    }
    assert(ppic_file_size(0xefbe000, HOST_MASK) == 0xefc0000 && ppic_file_size(0xefc0000, HOST_MASK) == 0xefc0000);

    /* Eviction: least recently used first, until the new copy fits the budget. */
    {
        struct ppic_entry e[] = { { 239ull << 20, 300, 0 }, { 115ull << 20, 100, 0 }, { 600ull << 20, 200, 0 } };
        assert(ppic_evict(e, 3, PPIC_BUDGET, 100ull << 20));          /* 954 + 100 > 1024: one goes */
        assert(!e[0].victim && e[1].victim && !e[2].victim);
        assert(ppic_evict(e, 3, PPIC_BUDGET, 500ull << 20));          /* two go, oldest first */
        assert(!e[0].victim && e[1].victim && e[2].victim);
        assert(ppic_evict(e, 3, PPIC_BUDGET, 0) && !e[0].victim && !e[1].victim && !e[2].victim);
        assert(!ppic_evict(e, 3, PPIC_BUDGET, PPIC_BUDGET + 1));     /* never fits */
        assert(ppic_evict(NULL, 0, PPIC_BUDGET, PPIC_BUDGET));
    }
    return 0;
}
'''


class ImageCacheTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            unix = d / "build/ntdll-unix"
            unix.mkdir(parents=True)
            (unix / "pp_img_cache.h").write_text(added_header())
            # The header as the series leaves it; d is inside this repository's .work.
            env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(d.parent))
            for later in LATER:
                subprocess.run(["git", "apply", "--include=build/ntdll-unix/pp_img_cache.h", str(later)],
                               cwd=d, env=env, check=True)
            (d / "pp_img_cache.h").write_text((unix / "pp_img_cache.h").read_text())
            (d / "test.c").write_text(TEST_C)
            args = [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")]
            if sys.platform.startswith("linux"):
                args.insert(1, "-fsanitize=address,undefined")
            subprocess.run(args, check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_map_image_into_view_tries_the_copy_before_its_section_loop(self):
        text = PATCH.read_text()
        hook = text.index("+    if (!ios_img_cache_map( view, nt_name, fd, &st, nt, sec, header_size, header_map_size, "
                          "align_mask, removable ))")
        loop = text.index(" for (i = pos = 0; i < nt->FileHeader.NumberOfSections; i++)", hook)
        self.assertLess(hook, loop)
        self.assertIn("ios_img_file_mapped = ios_img_file_read = 0;", text[hook - 300:hook])


if __name__ == "__main__":
    unittest.main()
