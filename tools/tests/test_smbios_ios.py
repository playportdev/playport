# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the SMBIOS code shipped by wine-unix 0040-0042 (PLA-401): type 44 Block Length,
cf_to_string's bound and the firmware table log's RSMB shape check. The functions 0040 and
0041 change are Wine's (dlls/ntdll/unix/system.c), with the patch's added lines in place."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCHES = REPO / "patches/wine-unix"


def added(name):
    """The lines the patch adds."""
    return "\n".join(line[1:] for line in next(PATCHES.glob(name)).read_text().splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


def function(code, start, end_marker="\n}\n"):
    begin = code.index(start)
    return code[begin:code.index(end_marker, begin) + len(end_marker)]


# Wine's dlls/ntdll/unix/system.c definitions the functions use.
TYPES = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t BYTE; typedef uint16_t WORD; typedef uint32_t DWORD, ULONG; typedef uint64_t UINT64;
typedef int BOOL;
#pragma pack(push,1)
struct smbios_prologue { BYTE calling_method, major_version, minor_version, revision; DWORD length; };
struct smbios_header { BYTE type; BYTE length; WORD handle; };
struct smbios_processor_specific_block { BYTE length; BYTE processor_type; BYTE data[]; };
struct smbios_processor_additional_info { struct smbios_header hdr; WORD ref_handle; struct smbios_processor_specific_block info_block; };
struct smbios_wine_core_id_regs_arm64 { WORD num_regs; struct smbios_wine_id_reg_value_arm64 { WORD reg; UINT64 value; } regs[]; };
#pragma pack(pop)
enum { SMBIOS_TYPE_PROCESSOR_ADDITIONAL_INFO = 44, SMBIOS_TYPE_END = 127 };
'''


def compile_and_run(test, source):
    work = REPO / ".work"
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="smbios-ios-", dir=work) as tmp:
        root = Path(tmp)
        (root / "test.c").write_text(source)
        build = subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-Wno-unused-function",
                                "-o", str(root / "test"), str(root / "test.c")],
                               capture_output=True, text=True)
        test.assertEqual(build.returncode, 0, build.stderr)
        run = subprocess.run([str(root / "test")], capture_output=True, text=True)
        test.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout


class SMBIOSIOS(unittest.TestCase):
    def test_type44_block_length_counts_the_data_alone(self):
        code = r'''
static WORD append_smbios_wine_core_id_regs_arm64( struct smbios_buffer *buf, WORD ref_handle,
                                                   WORD logical_thread_id )
{
    WORD length;
    BYTE info_buf[0xff];
    struct smbios_processor_additional_info *proc_additional_info =
        (struct smbios_processor_additional_info *)info_buf;
    struct smbios_wine_core_id_regs_arm64 *core_id_regs =
        (struct smbios_wine_core_id_regs_arm64 *)proc_additional_info->info_block.data;

    proc_additional_info->hdr.type = SMBIOS_TYPE_PROCESSOR_ADDITIONAL_INFO;
    proc_additional_info->ref_handle = ref_handle;
    proc_additional_info->info_block.processor_type = 5; /* 64 bit ARM */

    core_id_regs->num_regs = get_core_id_regs_arm64( core_id_regs->regs, logical_thread_id );

    length = sizeof(struct smbios_processor_additional_info) +
             sizeof(struct smbios_wine_core_id_regs_arm64) +
             core_id_regs->num_regs * sizeof(struct smbios_wine_id_reg_value_arm64);

    proc_additional_info->hdr.length = length;
''' + added("0040-*.patch") + r'''
    return append_smbios( buf, &proc_additional_info->hdr, NULL, 0 );
}
'''
        out = compile_and_run(self, TYPES + r'''
struct smbios_buffer { int unused; };
static BYTE last[0x100];
static WORD append_smbios( struct smbios_buffer *buf, struct smbios_header *hdr, const char *strings[], unsigned n )
{ memcpy( last, hdr, hdr->length ); return 1; }
static unsigned regs_to_report;
static DWORD get_core_id_regs_arm64( struct smbios_wine_id_reg_value_arm64 *regs, WORD id )
{ for (unsigned i = 0; i < regs_to_report; i++) regs[i] = (struct smbios_wine_id_reg_value_arm64){ 0x4000 + i, i }; return regs_to_report; }
''' + code + r'''
int main(void)
{
    static const unsigned counts[] = { 0, 1, 3 };
    for (unsigned i = 0; i < 3; i++)
    {
        struct smbios_buffer buf;
        regs_to_report = counts[i];
        append_smbios_wine_core_id_regs_arm64( &buf, 7, 0 );
        /* DSP0134 Tables 129 and 130: Length = 6 + Y, Y = 2 + Block Length */
        assert( last[0] == 44 && last[7] == 5 && (last[4] | last[5] << 8) == 7 );
        assert( last[1] == 8 + last[6] );
        assert( last[6] == 2 + 10 * counts[i] && (last[8] | last[9] << 8) == counts[i] );
        printf( "regs=%u length=%u block=%u\n", counts[i], last[1], last[6] );
    }
    return 0;
}
''')
        self.assertIn("regs=0 length=10 block=2", out)

    def test_cf_to_string_keeps_the_terminator_inside(self):
        code = r'''
static void cf_to_string( CFTypeRef type_ref, char *buffer, size_t buffer_size )
{
    buffer[0] = 0;
    if (!type_ref)
        return;

    if (CFGetTypeID(type_ref) == CFDataGetTypeID())
    {
''' + added("0041-*.patch") + r'''
        CFDataGetBytes(type_ref, CFRangeMake(0, length), (UInt8*)buffer);
        buffer[length] = 0;
    }
    else if (CFGetTypeID(type_ref) == CFStringGetTypeID())
    {
        CFStringGetCString(type_ref, buffer, buffer_size, kCFStringEncodingASCII);
    }

    CFRelease(type_ref);
}
'''
        compile_and_run(self, r'''
#include <assert.h>
#include <stddef.h>
#include <string.h>
typedef unsigned char UInt8; typedef long CFIndex;
typedef const struct cf { int kind; const char *bytes; CFIndex len; } *CFTypeRef;
typedef struct { CFIndex location, length; } CFRange;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
static int CFGetTypeID( CFTypeRef r ) { return r->kind; }
static int CFDataGetTypeID(void) { return 1; }
static int CFStringGetTypeID(void) { return 2; }
static CFIndex CFDataGetLength( CFTypeRef r ) { return r->len; }
static CFRange CFRangeMake( CFIndex l, CFIndex n ) { CFRange r = { l, n }; return r; }
static void CFDataGetBytes( CFTypeRef r, CFRange range, UInt8 *b ) { memcpy( b, r->bytes + range.location, range.length ); }
static void CFStringGetCString( CFTypeRef r, char *b, CFIndex n, int e ) {}
static int released;
static void CFRelease( CFTypeRef r ) { released++; }
#define kCFStringEncodingASCII 0
''' + code + r'''
int main(void)
{
    struct { char buffer[8]; char guard; } s;
    struct cf full = { 1, "ABCDEFGH", 8 }, longer = { 1, "ABCDEFGHIJ", 10 }, shorter = { 1, "ABC\0", 4 };

    s.guard = 0x5a;
    cf_to_string( &full, s.buffer, sizeof(s.buffer) );
    assert( s.guard == 0x5a && !strcmp( s.buffer, "ABCDEFG" ) );
    cf_to_string( &longer, s.buffer, sizeof(s.buffer) );
    assert( s.guard == 0x5a && !strcmp( s.buffer, "ABCDEFG" ) );
    cf_to_string( &shorter, s.buffer, sizeof(s.buffer) );
    assert( !strcmp( s.buffer, "ABC" ) && released == 3 );
    return 0;
}
''')

    def test_firmware_table_log_checks_the_rsmb_shape(self):
        shipped = added("0042-*.patch")
        code = function(shipped, "struct smbios_table_check", "\n};\n") + function(
            shipped, "static void check_smbios_table(")
        compile_and_run(self, TYPES + code + r'''
static ULONG build( BYTE *t, int block_length, int with_end, int with_string )
{
    ULONG n = 8;
    BYTE type4[] = { 4, 6, 0, 0, 1, 0 };
    BYTE type44[] = { 44, 10, 1, 0, 0, 0, (BYTE)block_length, 5, 0, 0 };
    BYTE end[] = { 127, 4, 2, 0 };
    memcpy( t + n, type4, sizeof(type4) ); n += sizeof(type4);
    if (with_string) { memcpy( t + n, "S\0\0", 3 ); n += 3; } else { t[n++] = 0; t[n++] = 0; }
    memcpy( t + n, type44, sizeof(type44) ); n += sizeof(type44); t[n++] = 0; t[n++] = 0;
    if (with_end) { memcpy( t + n, end, sizeof(end) ); n += sizeof(end); t[n++] = 0; t[n++] = 0; }
    memset( t, 0, 8 ); t[1] = 3; ((struct smbios_prologue *)t)->length = n - 8;
    return n;
}

int main(void)
{
    BYTE t[128]; ULONG n; struct smbios_table_check c;

    n = build( t, 2, 1, 1 );
    check_smbios_table( t, n, &c );
    assert( c.valid && c.structures == 3 && c.processor_info == 1 && c.processor_info_block_ok == 1 );
    n = build( t, 4, 1, 0 );   /* the Block Length Wine generated before 0040 */
    check_smbios_table( t, n, &c );
    assert( c.valid && c.structures == 3 && c.processor_info == 1 && c.processor_info_block_ok == 0 );
    n = build( t, 2, 0, 1 );   /* no end marker */
    check_smbios_table( t, n, &c );
    assert( !c.valid && c.structures == 2 );
    n = build( t, 2, 1, 1 );
    check_smbios_table( t, n - 1, &c );   /* the prologue's length no longer matches */
    assert( !c.valid && !c.structures );
    t[8 + 1] = 200;            /* a structure longer than the table */
    check_smbios_table( t, n, &c );
    assert( !c.valid && !c.structures );
    return 0;
}
''')


if __name__ == "__main__":
    unittest.main()
