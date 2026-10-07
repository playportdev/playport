# SPDX-License-Identifier: GPL-3.0-or-later
"""Native GSS probe: exact C source, fault injection, and cleanup/redaction."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

HEADER = r'''
#include <stddef.h>
#include <stdint.h>
typedef uint32_t OM_uint32;
typedef struct {size_t length; void *elements;} gss_OID_desc, *gss_OID;
typedef struct {size_t count; gss_OID elements;} gss_OID_set_desc, *gss_OID_set;
typedef struct {size_t length; void *value;} gss_buffer_desc, *gss_buffer_t;
typedef struct {size_t count; gss_buffer_t elements;} *gss_buffer_set_t;
typedef void *gss_name_t;
typedef void *gss_cred_id_t;
typedef void *gss_ctx_id_t;
#define GSS_C_NO_OID_SET NULL
#define GSS_C_NO_BUFFER_SET NULL
#define GSS_C_NO_NAME NULL
#define GSS_C_NO_CREDENTIAL NULL
#define GSS_C_NO_CONTEXT NULL
#define GSS_C_NO_BUFFER NULL
#define GSS_C_NO_CHANNEL_BINDINGS NULL
#define GSS_C_EMPTY_BUFFER {0,NULL}
#define GSS_C_NT_USER_NAME ((gss_OID)1)
#define GSS_C_NT_HOSTBASED_SERVICE ((gss_OID)2)
#define GSS_C_INQ_SSPI_SESSION_KEY ((gss_OID)3)
#define GSS_C_INITIATE 1
#define GSS_C_INTEG_FLAG 4
#define GSS_C_CONF_FLAG 8
#define GSS_S_COMPLETE 0
#define GSS_S_CONTINUE_NEEDED 1
OM_uint32 gss_indicate_mechs(OM_uint32*,gss_OID_set*);
OM_uint32 gss_import_name(OM_uint32*,gss_buffer_t,gss_OID,gss_name_t*);
OM_uint32 gss_acquire_cred_with_password(OM_uint32*,gss_name_t,gss_buffer_t,OM_uint32,gss_OID_set,int,gss_cred_id_t*,gss_OID_set*,OM_uint32*);
OM_uint32 gss_init_sec_context(OM_uint32*,gss_cred_id_t,gss_ctx_id_t*,gss_name_t,gss_OID,OM_uint32,OM_uint32,void*,gss_buffer_t,gss_OID*,gss_buffer_t,OM_uint32*,OM_uint32*);
OM_uint32 gss_release_buffer(OM_uint32*,gss_buffer_t);
OM_uint32 gss_inquire_sec_context_by_oid(OM_uint32*,gss_ctx_id_t,gss_OID,gss_buffer_set_t*);
OM_uint32 gss_release_buffer_set(OM_uint32*,gss_buffer_set_t*);
OM_uint32 gss_delete_sec_context(OM_uint32*,gss_ctx_id_t*,gss_buffer_t);
OM_uint32 gss_destroy_cred(OM_uint32*,gss_cred_id_t*);
OM_uint32 gss_release_name(OM_uint32*,gss_name_t*);
OM_uint32 gss_release_oid_set(OM_uint32*,gss_OID_set*);
'''

MOCK = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <GSS/GSS.h>
#include "auth_probe.h"
static int fail, calls, names, credentials, contexts, buffers, sets, keysets, destroy_fail;
static OM_uint32 step(OM_uint32 *minor) { *minor=0; return ++calls==fail ? (*minor=123, 2) : 0; }
static gss_OID_desc oids[]={{10,"\x2b\x06\x01\x04\x01\x82\x37\x02\x02\x0a"},
                          {9,"\x2a\x86\x48\x86\xf7\x12\x01\x02\x02"}};
static gss_OID_set_desc mechanisms={2,oids};
OM_uint32 gss_indicate_mechs(OM_uint32 *m,gss_OID_set *s) {
    OM_uint32 r=step(m); if(!r) {*s=&mechanisms; sets++;} return r;
}
OM_uint32 gss_import_name(OM_uint32 *m,gss_buffer_t b,gss_OID t,gss_name_t *n) {
    assert(b && b->value && b->length && (t==GSS_C_NT_USER_NAME || t==GSS_C_NT_HOSTBASED_SERVICE));
    OM_uint32 r=step(m); if(!r) {*n=malloc(1); names++;} return r;
}
OM_uint32 gss_acquire_cred_with_password(OM_uint32 *m,gss_name_t n,gss_buffer_t p,OM_uint32 time,
    gss_OID_set mechs,int use,gss_cred_id_t *c,gss_OID_set *actual,OM_uint32 *expiry) {
    assert(n && p && p->length && !time && use==GSS_C_INITIATE && mechs->count==1);
    assert(!actual && !expiry); OM_uint32 r=step(m); if(!r) {*c=malloc(1); credentials++;} return r;
}
OM_uint32 gss_init_sec_context(OM_uint32 *m,gss_cred_id_t c,gss_ctx_id_t *x,gss_name_t target,gss_OID oid,
    OM_uint32 flags,OM_uint32 time,void *bindings,gss_buffer_t input,gss_OID *actual,gss_buffer_t out,
    OM_uint32 *ret_flags,OM_uint32 *expiry) {
    assert(c && target && oid && !time && !bindings && !actual && !expiry && ret_flags && flags);
    OM_uint32 r=step(m); if(r) return r;
    if(!*x) {*x=malloc(1); contexts++;} unsigned char token[12]={'N','T','L','M','S','S','P',0,0,0,0,0};
    token[8]=input?3:1; if(input) assert(input->length==64 && ((char*)input->value)[8]==2);
    out->value=malloc(12); memcpy(out->value,token,12); out->length=12; buffers++;
    return input?GSS_S_COMPLETE:GSS_S_CONTINUE_NEEDED;
}
OM_uint32 gss_release_buffer(OM_uint32 *m,gss_buffer_t b) {*m=0; assert(b->value); free(b->value); b->value=NULL; b->length=0; buffers--; return 0;}
OM_uint32 gss_inquire_sec_context_by_oid(OM_uint32 *m,gss_ctx_id_t x,gss_OID oid,gss_buffer_set_t *s) {
    assert(x && oid==GSS_C_INQ_SSPI_SESSION_KEY); OM_uint32 r=step(m); if(r) return r;
    *s=calloc(1,sizeof(**s)); (*s)->count=1; (*s)->elements=calloc(1,sizeof(*(*s)->elements));
    (*s)->elements[0].length=16; (*s)->elements[0].value=malloc(16); keysets++; return 0;
}
OM_uint32 gss_release_buffer_set(OM_uint32 *m,gss_buffer_set_t *s) {*m=0; free((*s)->elements[0].value); free((*s)->elements); free(*s); *s=NULL; keysets--; return 0;}
OM_uint32 gss_delete_sec_context(OM_uint32 *m,gss_ctx_id_t *x,gss_buffer_t b) {*m=0; assert(!b); free(*x); *x=NULL; contexts--; return 0;}
OM_uint32 gss_destroy_cred(OM_uint32 *m,gss_cred_id_t *c) {*m=destroy_fail?456:0; free(*c); *c=NULL; credentials--; return destroy_fail?2:0;}
OM_uint32 gss_release_name(OM_uint32 *m,gss_name_t *n) {*m=0; free(*n); *n=NULL; names--; return 0;}
OM_uint32 gss_release_oid_set(OM_uint32 *m,gss_OID_set *s) {*m=0; *s=NULL; sets--; return 0;}
int main(void) {
    char report[1024];
    for(fail=0;fail<=7;fail++) {
        calls=0; int r=playport_native_auth_probe(report,sizeof(report));
        assert((r==0)==(fail==0)); assert(!names && !credentials && !contexts && !buffers && !sets && !keysets);
        assert(!strstr(report,"SyntheticUser") && !strstr(report,"Password"));
        if(!fail) assert(strstr(report,"stage=ok") && strstr(report,"key-bytes=16"));
        else assert(strstr(report,"minor=0000007b"));
    }
    fail=0; calls=0; destroy_fail=1;
    assert(playport_native_auth_probe(report,sizeof(report)) && strstr(report,"destroy-major="));
    assert(playport_native_auth_probe(NULL,0));
    char tiny[1]; calls=0; playport_native_auth_probe(tiny,1); assert(!tiny[0]);
    assert(!names && !credentials && !contexts && !buffers && !sets && !keysets);
    return 0;
}
'''


class NativeAuthProbeTests(unittest.TestCase):
    def test_cleanup_redaction_and_errors(self):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="native-auth-test-", dir=work) as tmp:
            root = Path(tmp)
            (root / "GSS").mkdir()
            (root / "GSS/GSS.h").write_text(HEADER)
            (root / "mock.c").write_text(MOCK)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                            "-I", str(root), "-I", str(REPO / "app/Sources/AuthProbe/include"),
                            str(root / "mock.c"), str(REPO / "app/Sources/AuthProbe/auth_probe.c"),
                            "-o", str(root / "test")], check=True)
            subprocess.run([str(root / "test")], check=True)

    def test_dev_only_dependency(self):
        package = (REPO / "app/Package.swift").read_text()
        self.assertIn('(release ? [] : ["AuthProbe"])', package)
        self.assertIn('release ? ["Dev"] : []', package)


if __name__ == "__main__":
    unittest.main()
