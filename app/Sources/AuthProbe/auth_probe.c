/* SPDX-License-Identifier: GPL-3.0-or-later
 * Measure iOS's public GSS implementation before choosing a Wine backend.
 * No default credential acquisition, owner credentials, URLs or KDC requests.
 * Only a synthetic NTLM identity and a locally constructed challenge are used.
 */
#include "auth_probe.h"
#include <GSS/GSS.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned int token_type(const gss_buffer_desc *token)
{
    const unsigned char *p = token->value;
    if (token->length < 12 || memcmp(p, "NTLMSSP\0", 8)) return 0;
    return p[8] | (unsigned int)p[9] << 8 | (unsigned int)p[10] << 16 | (unsigned int)p[11] << 24;
}

int playport_native_auth_probe(char *report, size_t capacity)
{
    OM_uint32 major, minor = 0, ignored, flags = 0;
    gss_OID_set mechs = GSS_C_NO_OID_SET;
    gss_name_t name = GSS_C_NO_NAME, target = GSS_C_NO_NAME;
    gss_cred_id_t cred = GSS_C_NO_CREDENTIAL;
    gss_ctx_id_t context = GSS_C_NO_CONTEXT;
    gss_buffer_desc user = {sizeof("PLAYPORT-PROBE\\SyntheticUser") - 1, "PLAYPORT-PROBE\\SyntheticUser"};
    gss_buffer_desc password = {sizeof("PlayportSyntheticPasswordOnly") - 1, "PlayportSyntheticPasswordOnly"};
    gss_buffer_desc server = {sizeof("HTTP@playport.invalid") - 1, "HTTP@playport.invalid"};
    gss_buffer_desc output = GSS_C_EMPTY_BUFFER, input;
    gss_buffer_set_t keys = GSS_C_NO_BUFFER_SET;
    gss_OID_desc ntlm = {10, "\x2b\x06\x01\x04\x01\x82\x37\x02\x02\x0a"};
    gss_OID_set_desc wanted = {1, &ntlm};
    unsigned int type1 = 0, type3 = 0;
    size_t key_length = 0;
    int has_ntlm = 0, has_krb = 0, result = 1;
    const char *stage = "mechanisms";
    /* Type 2, NTLMv2/Unicode/target-info, synthetic target DOMAIN, EOL AV pair.
     * No server-side password check is claimed: the probe measures token creation.
     */
    unsigned char challenge[64] = {
        'N','T','L','M','S','S','P',0, 2,0,0,0,
        12,0,12,0, 48,0,0,0, 5,2,0x88,0xa0,
        1,2,3,4,5,6,7,8, 0,0,0,0,0,0,0,0,
        4,0,4,0, 60,0,0,0,
        'D',0,'O',0,'M',0,'A',0,'I',0,'N',0, 0,0,0,0
    };

    if (!report || !capacity) return 1;
    major = gss_indicate_mechs(&minor, &mechs);
    if (major != GSS_S_COMPLETE) goto done;
    for (size_t i = 0; i < mechs->count; ++i) {
        const gss_OID_desc *oid = &mechs->elements[i];
        if (oid->length == ntlm.length && !memcmp(oid->elements, ntlm.elements, ntlm.length)) has_ntlm = 1;
        static const unsigned char krb[] = {0x2a,0x86,0x48,0x86,0xf7,0x12,0x01,0x02,0x02};
        if (oid->length == sizeof(krb) && !memcmp(oid->elements, krb, sizeof(krb))) has_krb = 1;
    }
    stage = "name";
    major = gss_import_name(&minor, &user, GSS_C_NT_USER_NAME, &name);
    if (major != GSS_S_COMPLETE) goto done;
    stage = "credential";
    major = gss_acquire_cred_with_password(&minor, name, &password, 0, &wanted, GSS_C_INITIATE,
                                         &cred, NULL, NULL);
    if (major != GSS_S_COMPLETE) goto done;
    stage = "target";
    major = gss_import_name(&minor, &server, GSS_C_NT_HOSTBASED_SERVICE, &target);
    if (major != GSS_S_COMPLETE) goto done;
    stage = "type1";
    major = gss_init_sec_context(&minor, cred, &context, target, &ntlm,
                                GSS_C_INTEG_FLAG | GSS_C_CONF_FLAG, 0, GSS_C_NO_CHANNEL_BINDINGS,
                                GSS_C_NO_BUFFER, NULL, &output, &flags, NULL);
    type1 = token_type(&output);
    if (major != GSS_S_CONTINUE_NEEDED || type1 != 1) goto done;
    gss_release_buffer(&ignored, &output);
    stage = "type3";
    input.length = sizeof(challenge); input.value = challenge;
    major = gss_init_sec_context(&minor, cred, &context, target, &ntlm,
                                GSS_C_INTEG_FLAG | GSS_C_CONF_FLAG, 0, GSS_C_NO_CHANNEL_BINDINGS,
                                &input, NULL, &output, &flags, NULL);
    type3 = token_type(&output);
    if (major != GSS_S_COMPLETE || type3 != 3) goto done;
    stage = "session-key";
    major = gss_inquire_sec_context_by_oid(&minor, context, GSS_C_INQ_SSPI_SESSION_KEY, &keys);
    if (major != GSS_S_COMPLETE) goto done;
    if (keys && keys->count) key_length = keys->elements[0].length;
    if (key_length != 16) goto done;
    stage = "ok";
    result = 0;
done:
    /* Only status and lengths. Never credential strings, tokens or key bytes. */
    snprintf(report, capacity, "native-auth: stage=%s major=%08x minor=%08x ntlm=%d kerberos=%d type1=%u type3=%u key-bytes=%zu",
             stage, major, minor, has_ntlm, has_krb, type1, type3, key_length);
    if (keys) gss_release_buffer_set(&ignored, &keys);
    if (output.value) gss_release_buffer(&ignored, &output);
    if (context) gss_delete_sec_context(&ignored, &context, GSS_C_NO_BUFFER);
    /* destroy, not just release: remove any synthetic credential from storage. */
    if (cred) {
        OM_uint32 cleanup = gss_destroy_cred(&ignored, &cred);
        if (cleanup != GSS_S_COMPLETE) {
            size_t used = strlen(report);
            snprintf(report + used, capacity - used, " destroy-major=%08x destroy-minor=%08x", cleanup, ignored);
            result = 1;
        }
    }
    if (target) gss_release_name(&ignored, &target);
    if (name) gss_release_name(&ignored, &name);
    if (mechs) gss_release_oid_set(&ignored, &mechs);
    return result;
}
