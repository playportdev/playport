/* SPDX-License-Identifier: GPL-3.0-or-later */
/* ios_copy_extent.h (patches/madeira-unix, PLA-377): the bytes of a builtin a
 * JIT-pool copy needs. The section tables are the IPA's own (shell32,
 * kernelbase, kernel32, ntdll and FEX's xtajit64, as
 * .work/agent-notes/pla377/pe_sections.py read them), plus the layouts that
 * must not be trimmed. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "ios_copy_extent.h"

#define CODE  0x60000020u
#define RDATA 0x40000040u
#define DATA  0xc0000040u
#define RELOC 0x42000040u
#define DEBUG 0x42000040u
#define PAGE  0x4000

struct section { const char *name; uint32_t rva, vsize, chars; };

static unsigned char image[0x1000];

static void put32( unsigned char *p, uint32_t v ) { memcpy( p, &v, 4 ); }
static void put16( unsigned char *p, uint16_t v ) { memcpy( p, &v, 2 ); }

/* A PE32+ header at 0x80 with 16 data directories: exports at `export_rva`,
 * resources at `rsrc_rva`, base relocations at `reloc_rva` (0: none). */
static size_t build( const struct section *s, int n, uint32_t size_of_image, uint32_t export_rva,
                     uint32_t rsrc_rva, uint32_t reloc_rva, uint16_t magic )
{
    unsigned char *pe = image + 0x80, *opt = pe + 24, *sec = opt + 0xf0;
    int i;

    memset( image, 0, sizeof(image) );
    image[0] = 'M'; image[1] = 'Z';
    put32( image + 0x3c, 0x80 );
    memcpy( pe, "PE\0\0", 4 );
    put16( pe + 6, (uint16_t)n );
    put16( pe + 20, 0xf0 );
    put16( opt, magic );
    put32( opt + 56, size_of_image );
    put32( opt + 60, 0x400 );
    put32( opt + 108, 16 );
    if (export_rva) put32( opt + 112 + 0 * 8, export_rva ), put32( opt + 112 + 0 * 8 + 4, 0x100 );
    if (rsrc_rva) put32( opt + 112 + 2 * 8, rsrc_rva ), put32( opt + 112 + 2 * 8 + 4, 0x100 );
    if (reloc_rva) put32( opt + 112 + 5 * 8, reloc_rva ), put32( opt + 112 + 5 * 8 + 4, 0x100 );
    for (i = 0; i < n; i++, sec += 40)
    {
        memcpy( sec, s[i].name, strlen( s[i].name ) < 8 ? strlen( s[i].name ) : 8 );
        put32( sec + 8, s[i].vsize );
        put32( sec + 12, s[i].rva );
        put32( sec + 36, s[i].chars );
    }
    return size_of_image;
}

static void expect( const char *what, size_t got, size_t want )
{
    if (got != want)
    {
        fprintf( stderr, "%s: copy extent 0x%zx, expected 0x%zx\n", what, got, want );
        exit( 1 );
    }
}

/* Wine's ARM64EC builtins: 64 KiB sections, .rsrc then .reloc last. */
static const struct section shell32[] = {
    { ".text", 0x10000, 0x89aa3, CODE }, { ".hexpthk", 0xa0000, 0x16c0, CODE },
    { ".rdata", 0xb0000, 0x3f260, RDATA }, { ".data", 0xf0000, 0x1aa8, DATA },
    { ".pdata", 0x100000, 0x5928, RDATA }, { ".a64xrm", 0x110000, 0xb68, RDATA },
    { ".eh_fram", 0x120000, 0x8d8, RDATA }, { ".rsrc", 0x130000, 0x868120, RDATA },
    { ".reloc", 0x9a0000, 0x1ac0, RELOC },
};
static const struct section kernelbase[] = {
    { ".text", 0x10000, 0x7a3e6, CODE }, { ".hexpthk", 0x90000, 0x4f60, CODE },
    { ".rdata", 0xa0000, 0x38d80, RDATA }, { ".data", 0xe0000, 0x4460, DATA },
    { ".pdata", 0xf0000, 0x6f30, RDATA }, { ".a64xrm", 0x100000, 0x27b8, RDATA },
    { ".eh_fram", 0x110000, 0x878, RDATA }, { ".rsrc", 0x120000, 0x1e9bac, RDATA },
    { ".reloc", 0x310000, 0xa60, RELOC },
};
static const struct section kernel32[] = {
    { ".text", 0x10000, 0x33766, CODE }, { ".hexpthk", 0x50000, 0x1780, CODE },
    { ".rdata", 0x60000, 0x20d70, RDATA }, { ".data", 0x90000, 0x428, DATA },
    { ".pdata", 0xa0000, 0x511c, RDATA }, { ".a64xrm", 0xb0000, 0xbc8, RDATA },
    { ".eh_fram", 0xc0000, 0xab8, RDATA }, { ".rsrc", 0xd0000, 0x53fc, RDATA },
    { ".reloc", 0xe0000, 0xfd8, RELOC },
};
static const struct section ntdll[] = {
    { ".text", 0x10000, 0x8ad65, CODE }, { ".hexpthk", 0xa0000, 0x3540, CODE },
    { ".rdata", 0xb0000, 0x314f8, RDATA }, { ".data", 0xf0000, 0x12e10, DATA },
    { ".pdata", 0x110000, 0x8f14, RDATA }, { ".a64xrm", 0x120000, 0x22f8, RDATA },
    { ".eh_fram", 0x130000, 0xc18, RDATA }, { ".rsrc", 0x140000, 0x3c8, RDATA },
    { ".reloc", 0x150000, 0x510, RELOC },
};
/* FEX's module: 4 KiB sections, no resources, .reloc last. */
static const struct section xtajit64[] = {
    { ".text", 0x1000, 0x23fd66, CODE }, { ".hexpthk", 0x241000, 0x170, CODE },
    { ".rdata", 0x242000, 0x1d1718, RDATA }, { ".buildid", 0x414000, 0x35, RDATA },
    { ".data", 0x415000, 0x5c860, DATA }, { ".pdata", 0x472000, 0x112e0, RDATA },
    { ".a64xrm", 0x484000, 0xc0, RDATA }, { ".tls", 0x485000, 0x30, DATA },
    { ".reloc", 0x486000, 0x9f3c, RELOC },
};

int main( void )
{
    struct section s[16];
    size_t size;

    /* shell32: 9.9 MiB of image, 8.4 MiB of it .rsrc; the copy ends after .eh_fram */
    size = build( shell32, 9, 0x9b0000, 0xb0000, 0x130000, 0x9a0000, 0x20b );
    expect( "shell32", ios_copy_extent( image, size, PAGE ), 0x124000 );
    size = build( kernelbase, 9, 0x320000, 0xa0000, 0x120000, 0x310000, 0x20b );
    expect( "kernelbase", ios_copy_extent( image, size, PAGE ), 0x114000 );
    size = build( kernel32, 9, 0xf0000, 0x60000, 0xd0000, 0xe0000, 0x20b );
    expect( "kernel32", ios_copy_extent( image, size, PAGE ), 0xc4000 );
    /* the copy path keeps ntdll whole; its layout alone would be trimmed */
    size = build( ntdll, 9, 0x160000, 0xb0000, 0x140000, 0x150000, 0x20b );
    expect( "ntdll", ios_copy_extent( image, size, PAGE ), 0x134000 );
    /* only .reloc is left out; the rounding takes in its first page */
    size = build( xtajit64, 9, 0x490000, 0x242000, 0, 0x486000, 0x20b );
    expect( "xtajit64", ios_copy_extent( image, size, PAGE ), 0x488000 );

    /* kernel32 linked with 16 KiB sections (PLA-377 A2) */
    {
        static const struct section k16[] = {
            { ".text", 0x4000, 0x33766, CODE }, { ".hexpthk", 0x38000, 0x1780, CODE },
            { ".rdata", 0x3c000, 0x20d70, RDATA }, { ".data", 0x60000, 0x428, DATA },
            { ".pdata", 0x64000, 0x511c, RDATA }, { ".a64xrm", 0x6c000, 0xbc8, RDATA },
            { ".eh_fram", 0x70000, 0xab8, RDATA }, { ".rsrc", 0x74000, 0x53fc, RDATA },
            { ".reloc", 0x7c000, 0xfd8, RELOC },
        };
        size = build( k16, 9, 0x80000, 0x3c000, 0x74000, 0x7c000, 0x20b );
        expect( "kernel32 at 16 KiB", ios_copy_extent( image, size, PAGE ), 0x74000 );
    }

    /* DWARF after .reloc is discardable too */
    memcpy( s, kernel32, sizeof(kernel32) );
    s[9] = (struct section){ "/4", 0xf0000, 0x20000, DEBUG };
    size = build( s, 10, 0x110000, 0x60000, 0xd0000, 0xe0000, 0x20b );
    expect( "kernel32 with debug info", ios_copy_extent( image, size, PAGE ), 0xc4000 );

    /* a writable section after .rsrc: .rsrc is not trailing, nothing is left out */
    memcpy( s, kernel32, sizeof(kernel32) );
    s[8] = (struct section){ ".data2", 0xe0000, 0x100, DATA };
    size = build( s, 9, 0xf0000, 0x60000, 0xd0000, 0, 0x20b );
    expect( "data after .rsrc", ios_copy_extent( image, size, PAGE ), 0xf0000 );

    /* .rsrc as the last section, with no .reloc */
    size = build( kernel32, 8, 0xe0000, 0x60000, 0xd0000, 0, 0x20b );
    expect( "no .reloc", ios_copy_extent( image, size, PAGE ), 0xc4000 );

    /* a writable .rsrc is kept; the .reloc after it still goes */
    memcpy( s, kernel32, sizeof(kernel32) );
    s[7].chars = DATA;
    size = build( s, 9, 0xf0000, 0x60000, 0xd0000, 0xe0000, 0x20b );
    expect( "writable .rsrc", ios_copy_extent( image, size, PAGE ), 0xd8000 );

    /* a discardable section that holds the exports is kept */
    memcpy( s, kernel32, sizeof(kernel32) );
    s[8] = (struct section){ ".edata", 0xe0000, 0x400, RELOC };
    size = build( s, 9, 0xf0000, 0xe0000, 0xd0000, 0, 0x20b );
    expect( "exports last", ios_copy_extent( image, size, PAGE ), 0xf0000 );

    /* a read-only section that is not discardable and holds no resources is kept */
    memcpy( s, kernel32, sizeof(kernel32) );
    s[7].chars = RDATA;
    size = build( s, 9, 0xf0000, 0x60000, 0, 0xe0000, 0x20b );
    expect( "plain .rdata before .reloc", ios_copy_extent( image, size, PAGE ), 0xd8000 );

    /* not PE32+, or no image: the whole SizeOfImage */
    size = build( kernel32, 9, 0xf0000, 0x60000, 0xd0000, 0xe0000, 0x10b );
    expect( "PE32", ios_copy_extent( image, size, PAGE ), 0xf0000 );
    image[0] = 0;
    expect( "no MZ", ios_copy_extent( image, 0xf0000, PAGE ), 0xf0000 );
    expect( "NULL", ios_copy_extent( NULL, 0xf0000, PAGE ), 0xf0000 );

    printf( "copy extent: ok\n" );
    return 0;
}
