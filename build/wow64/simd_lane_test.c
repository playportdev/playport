/* The low-fault emulator's LD1/ST1 lane decoder (madeira-unix 0070), compiled
 * from the patch, against encodings llvm-mc assembles.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "simd_lane_api.h"

static const struct { uint32_t insn; int bytes, offset; const char *text; } cases[] =
{
    { 0x0d408690, 8, 0,  "ld1 {v16.d}[0], [x20]  (Portal 2's engine.dll fault)" },
    { 0x4d408443, 8, 8,  "ld1 {v3.d}[1], [x2]" },
    { 0x4d009025, 4, 12, "st1 {v5.s}[3], [x1]" },
    { 0x4d408127, 4, 8,  "ld1 {v7.s}[2], [x9]" },
    { 0x4d004801, 2, 10, "st1 {v1.h}[5], [x0]" },
    { 0x4d401fdf, 1, 15, "ld1 {v31.b}[15], [x30]" },
    { 0x0d001862, 1, 6,  "st1 {v2.b}[6], [x3]" },
    { 0x0ddf8690, 0, 0,  "ld1 {v16.d}[0], [x20], #8  (post-index: not this form)" },
    { 0x0d40b000, 0, 0,  "ld3 {v0.s, v1.s, v2.s}[1], [x0]" },
    { 0x4d40c800, 0, 0,  "ld1r {v0.4s}, [x0]" },
    { 0xfd400290, 0, 0,  "ldr d16, [x20]" },
};

int main(void)
{
    unsigned int i;

    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
    {
        int offset = -1, bytes = ios_simd_lane( cases[i].insn, &offset );
        if (bytes != cases[i].bytes || (bytes && offset != cases[i].offset))
        {
            fprintf( stderr, "%s: %08x gave %d bytes at %d\n", cases[i].text, cases[i].insn, bytes, offset );
            return 1;
        }
    }
    puts( "WoW64 low-fault LD1/ST1 lanes: PASS (B/H/S/D lanes, Q and S bits, other forms refused)" );
    return 0;
}
