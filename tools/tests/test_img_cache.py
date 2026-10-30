# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the image cache copy's rules shipped in madeira-unix 0235 (decision 0167, PLA-476).

The layout must give the bytes map_image_into_view gives the view before any write: the test replays
Wine's steps (map_pe_header's mmap and read, its zeroes to the aligned header end, each section's
sector-rounded read and the zeroes after it) on a synthetic file, assembles the copy as the writer thread
does (ppic_overlap over 1 MiB blocks), and compares the two byte for byte."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0235-virtual-map-a-large-x86-64-image-from-a-re-laid-out-.patch"


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

static void check(const struct ppic_section *s, unsigned n, uint64_t fsize, uint64_t total, uint64_t header_size,
                  uint64_t header_map_size, uint64_t align_mask)
{
    unsigned char *file = malloc(fsize), *view = malloc(total), *out;
    uint64_t out_size = ppic_file_size(total, HOST_MASK), i;
    struct ppic_run r[64];
    int nruns = ppic_layout(s, n, fsize, total, header_size, header_map_size, align_mask, HOST_MASK, r, 64);
    for (i = 0; i < fsize; i++) file[i] = (unsigned char)(i * 2654435761u >> 13) | 1;   /* never zero */
    assert(nruns > 0);
    assert(wine_view(view, total, file, fsize, s, n, header_size, header_map_size, align_mask) == 0);
    out = malloc(out_size);
    copy(out, out_size, file, fsize, r, nruns, 1u << 20);
    assert(!memcmp(out, view, total));
    for (i = total; i < out_size; i++) assert(!out[i]);
    copy(out, out_size, file, fsize, r, nruns, 0x3000);
    assert(!memcmp(out, view, total));
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

    /* The name: the file's identity and the view size; the copy's size: whole host pages. */
    ppic_name(name, sizeof name, 0x1000002, 0x2a5f1, 0xedcd000, 1761000000, 123456789, 0xefbe000);
    assert(!strcmp(name, "v1-1000002-2a5f1-edcd000-1761000000.123456789-efbe000.img"));
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
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_img_cache.h").write_text(added_header())
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
