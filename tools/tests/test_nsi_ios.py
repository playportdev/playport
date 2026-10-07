# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the exact Darwin decoder shipped by the Wine unix patch."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class NSIIOS(unittest.TestCase):
    def test_dispatch_and_wow64(self):
        patch = REPO / "patches/madeira-unix/0095-ntdll-route-iOS-NSI-reads-to-Wine-NDIS-and-IP-provid.patch"
        added = "\n".join(line[1:] for line in patch.read_text().splitlines()
                          if line.startswith("+") and not line.startswith("+++"))
        code = "static const struct module_table *ios_get_table(" + added.split(
            "static const struct module_table *ios_get_table(", 1)[1].split(
            "    (const void *)nsi_get_all_parameters_ex,", 1)[0]
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="nsi-dispatch-", dir=work) as tmp:
            root = Path(tmp)
            source = root / "test.c"
            source.write_text(r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
typedef unsigned int UINT;
typedef uintptr_t UINT_PTR;
typedef int NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_NOT_SUPPORTED 1
#define STATUS_INVALID_PARAMETER 2
#define STATUS_BUFFER_OVERFLOW 3
#define NSI_PARAM_TYPE_STATIC 2
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
typedef struct { struct {UINT Data1;} Guid; } NPI_MODULEID;
#define NmrIsEqualNpiModuleId(a,b) ((a)->Guid.Data1 == (b)->Guid.Data1)
struct nsi_enumerate_all_ex {
    void *unknown[2]; const NPI_MODULEID *module; UINT_PTR table;
    UINT first_arg, second_arg; void *key_data; UINT key_size; void *rw_data; UINT rw_size;
    void *dynamic_data; UINT dynamic_size; void *static_data; UINT static_size; UINT_PTR count;
};
struct nsi_get_all_parameters_ex {
    void *unknown[2]; const NPI_MODULEID *module; UINT_PTR table;
    UINT first_arg, unknown2; const void *key; UINT key_size; void *rw_data; UINT rw_size;
    void *dynamic_data; UINT dynamic_size; void *static_data; UINT static_size;
};
struct nsi_get_parameter_ex {
    void *unknown[2]; const NPI_MODULEID *module; UINT_PTR table;
    UINT first_arg, unknown2; const void *key; UINT key_size; UINT_PTR param_type;
    void *data; UINT data_size, data_offset;
};
struct module_table {
    UINT table, sizes[4];
    NTSTATUS (*enumerate_all)(void*,UINT,void*,UINT,void*,UINT,void*,UINT,UINT_PTR*);
    NTSTATUS (*get_all_parameters)(const void*,UINT,void*,UINT,void*,UINT,void*,UINT);
    NTSTATUS (*get_parameter)(const void*,UINT,UINT,void*,UINT,UINT);
};
struct module {const NPI_MODULEID *module; const struct module_table *tables;};
static NTSTATUS rows(void *k,UINT ks,void *rw,UINT rs,void *d,UINT ds,void *s,UINT ss,UINT_PTR *count) {
    assert(!rs && !ds && !ss && !rw && !d && !s);
    if (!ks) {*count=2; return 0;}
    if (*count<2) return STATUS_BUFFER_OVERFLOW;
    ((UINT*)k)[0]=11; ((UINT*)k)[1]=22; *count=2; return 0;
}
static NTSTATUS all(const void *k,UINT ks,void *rw,UINT rs,void *d,UINT ds,void *s,UINT ss) {
    assert(k && ks==4 && !d && !s && !ds && !ss);
    if (rs) *(UINT*)rw=*(const UINT*)k; return 0;
}
static NTSTATUS parameter(const void *k,UINT ks,UINT type,void *data,UINT size,UINT offset) {
    assert(k && ks==4 && type==2 && size==4 && offset==0); *(UINT*)data=*(const UINT*)k; return 0;
}
static const NPI_MODULEID id={.Guid={1}}, id4={.Guid={2}}, id6={.Guid={3}};
static const struct module_table tables[]={ {0,{4,4,4,4},rows,all,parameter}, {~0u,{0},NULL,NULL,NULL} };
static const struct module ndis_module={&id,tables},ipv4_module={&id4,tables},ipv6_module={&id6,tables};
static uintptr_t base;
static uintptr_t ios_wow64_current_base(void) {return base;}
static void *ios_wow64_to_host(uintptr_t b, uint32_t p) {return p?(void*)(b+p):NULL;}
static int ios_wow64_host_span(uintptr_t b,const void *p,size_t size) {
    uintptr_t delta=(uintptr_t)p-b;
    return p && delta>0 && delta<=UINT32_MAX && size<=UINT64_C(0x100000000)-delta;
}
static NTSTATUS ios_nsi_enumerate_all_ex(void *p);
''' + code + r'''
static NTSTATUS ios_nsi_enumerate_all_ex(void *p) {return nsi_enumerate_all_ex(p);}
int main(void) {
    UINT key=42,out=0,keys[2]={0};
    struct nsi_enumerate_all_ex e={.module=&id};
    struct nsi_get_all_parameters_ex a={.module=&id,.key=&key,.key_size=4,.rw_data=&out,.rw_size=4};
    struct nsi_get_parameter_ex p={.module=&id,.key=&key,.key_size=4,.param_type=2,.data=&out,.data_size=4};
    assert(!nsi_enumerate_all_ex(&e) && e.count==2);
    e.key_data=keys; e.key_size=4; e.count=1;
    assert(nsi_enumerate_all_ex(&e)==STATUS_BUFFER_OVERFLOW);
    e.count=2; assert(!nsi_enumerate_all_ex(&e) && keys[0]==11 && keys[1]==22);
    e.key_size=3; assert(nsi_enumerate_all_ex(&e)==STATUS_INVALID_PARAMETER);
    e.key_size=4; e.key_data=NULL; assert(nsi_enumerate_all_ex(&e)==STATUS_INVALID_PARAMETER);
    e.table=99; assert(nsi_enumerate_all_ex(&e)==STATUS_NOT_SUPPORTED);
    assert(!nsi_get_all_parameters_ex(&a) && out==42);
    a.rw_size=3; assert(nsi_get_all_parameters_ex(&a)==STATUS_INVALID_PARAMETER);
    assert(!nsi_get_parameter_ex(&p));
    p.data_offset=UINT32_MAX; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    p.data_offset=1; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    p.data_offset=0; p.param_type=3; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    _Alignas(8) unsigned char window[256]={0};
    base=(uintptr_t)window-0x1000;
    memcpy(window,&id,sizeof(id));
    struct ios_nsi_enum32 e32={.module=0x1000,.key_size=4,.key_data=0x1040,.count=2};
    assert(!ios_nsi_enum_wow64(&e32) && e32.count==2 && *(UINT*)(window+64)==11);
    e32.key_data=UINT32_MAX-1; assert(ios_nsi_enum_wow64(&e32)==STATUS_INVALID_PARAMETER);
    memcpy(window+64,&key,4);
    struct ios_nsi_all32 a32={.module=0x1000,.key=0x1040,.key_size=4,.rw_data=0x1080,.rw_size=4};
    assert(!ios_nsi_all_wow64(&a32) && *(UINT*)(window+128)==42);
    struct ios_nsi_param32 p32={.module=0x1000,.key=0x1040,.key_size=4,.param_type=2,
                              .data=0x1080,.data_size=4};
    assert(!ios_nsi_param_wow64(&p32) && *(UINT*)(window+128)==42);
    p32.data=UINT32_MAX-1; assert(ios_nsi_param_wow64(&p32)==STATUS_INVALID_PARAMETER);
    assert(sizeof(struct ios_nsi_enum32)==60 && sizeof(struct ios_nsi_all32)==56 && sizeof(struct ios_nsi_param32)==48);
    return 0;
}
''')
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Wno-misleading-indentation",
                            "-fsanitize=undefined,address", str(source), "-o", str(root / "test")], check=True)
            subprocess.run([str(root / "test")], check=True, capture_output=True)

    def test_darwin_route_decoder(self):
        patches = sorted((REPO / "patches/wine-unix").glob("*-nsiproxy*.patch"))
        self.assertEqual(len(patches), 1)
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="nsi-test-", dir=work) as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "apply", "--include=dlls/nsiproxy.sys/ios_routes.h", str(patches[0])],
                           cwd=root, check=True)
            source = root / "test.c"
            source.write_text(r'''
#include <assert.h>
#include "dlls/nsiproxy.sys/ios_routes.h"

static size_t message(unsigned char *b, unsigned int family, unsigned int flags,
                      unsigned int mask_length)
{
    struct ios_route_header h = {0};
    unsigned int len = family == 2 ? 16 : 28, off = family == 2 ? 4 : 8;
    unsigned char *dst = b + sizeof(h), *gw = dst + len, *mask = gw + len;
    memset(b, 0, 512);
    h.length = sizeof(h) + len * 2 + ((mask_length + 3) & ~3u);
    h.version = 5; h.type = 4; h.index = 7; h.flags = flags;
    h.addrs = 7; h.metrics[2] = 11;
    memcpy(b, &h, sizeof(h));
    dst[0] = gw[0] = len; dst[1] = gw[1] = family;
    mask[0] = mask_length; mask[1] = 255; /* BSD masks do not have an IP family */
    dst[off] = family == 2 ? 10 : 0x20; dst[off + 1] = 1;
    gw[off] = family == 2 ? 10 : 0xfe; gw[off + 1] = family == 2 ? 0 : 0x80;
    gw[off + 2] = family == 2 ? 0 : 7; gw[off + (family == 2 ? 3 : 15)] = 1;
    if (mask_length > off) mask[off] = 255;
    return h.length;
}

int main(void)
{
    unsigned char b[512], copy[512];
    struct ios_route row;
    struct ios_route_header h;
    size_t len;
    len = message(b, 2, 3, 5); /* compressed 255.0.0.0 (/8) */
    assert(ios_route_parse(b, len, &row) == 1);
    assert(row.family == 2 && row.index == 7 && row.metric == 11 && row.prefix_len == 8);
    assert(row.prefix[0] == 10 && row.prefix[1] == 0 && row.next_hop[3] == 1);
    for (size_t i = 0; i < len; ++i) assert(ios_route_parse(b, i, &row) == -1);
    memcpy(copy, b, len);
    /* No natural alignment may be assumed for a route message. */
    memmove(b + 1, copy, len);
    assert(ios_route_parse(b + 1, len, &row) == 1);
    memcpy(b, copy, len);
    memcpy(&h, b, sizeof(h));
    h.length = 0; memcpy(b, &h, sizeof(h)); assert(ios_route_parse(b, len, &row) == -1);
    h.length = len; h.version = 6; memcpy(b, &h, sizeof(h)); assert(!ios_route_parse(b, len, &row));
    h.version = 5; h.flags = 0; memcpy(b, &h, sizeof(h)); assert(!ios_route_parse(b, len, &row));
    h.flags = 3 | 0x800000; memcpy(b, &h, sizeof(h)); assert(!ios_route_parse(b, len, &row));
    h.flags = 3; h.addrs |= 256; memcpy(b, &h, sizeof(h)); assert(ios_route_parse(b, len, &row) == -1);
    len = message(b, 2, 3, 8);
    b[sizeof(h) + 32 + 4] = 0xf0; b[sizeof(h) + 32 + 5] = 0x80; /* noncontiguous mask */
    assert(ios_route_parse(b, len, &row) == -1);
    len = message(b, 2, 3, 4); /* default route */
    memset(b + sizeof(h) + 4, 0, 4);
    assert(ios_route_parse(b, len, &row) == 1 && row.prefix_len == 0);
    len = message(b, 2, 5, 4); /* host route without mask */
    assert(ios_route_parse(b, len, &row) == 1 && row.prefix_len == 32 && !row.gateway);
    assert(!memcmp(row.next_hop, (unsigned char[16]){0}, 16)); /* AF_LINK on-link allowed */
    len = message(b, 30, 3, 16);
    for (unsigned int i = 8; i < 16; ++i) b[sizeof(h) + 56 + i] = 255;
    assert(ios_route_parse(b, len, &row) == 1 && row.family == 30 && row.prefix_len == 64);
    assert(row.next_hop[0] == 0xfe && row.next_hop[1] == 0x80 && !row.next_hop[2] && !row.next_hop[3]);
    len = message(b, 2, 3, 5);
    b[sizeof(h) + 16 + 1] = 18; /* AF_LINK cannot supply an IP gateway */
    assert(!ios_route_parse(b, len, &row));
    b[sizeof(h)] = 255; /* sockaddr overrun */
    assert(ios_route_parse(b, len, &row) == -1);
    /* Fuzz all input lengths without undefined behaviour / hangs. */
    uint32_t seed = 123;
    for (unsigned int trial = 0; trial < 20000; ++trial)
    {
        for (unsigned int i = 0; i < sizeof(b); ++i)
        { seed = seed * 1664525u + 1013904223u; b[i] = seed >> 24; }
        ios_route_parse(b, trial % sizeof(b), &row);
    }
    return 0;
}
''')
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=undefined,address", str(source), "-o", str(root / "test")], check=True)
            subprocess.run([str(root / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
