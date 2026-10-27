/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * wine_context.c — Wine's own ARM64EC context conversions, compiled on the
 * workstation for build/ymm-context/test.py. wine_unwind_conversions.inc is
 * the text test.py cuts out of the Wine PE tree's dlls/ntdll/unwind.h (the
 * block under "#if defined(__aarch64__) || defined(__arm64ec__)"), unchanged:
 * ctx_flags_x64_to_arm/ctx_flags_arm_to_x64, context_x64_to_arm and
 * context_arm_to_x64 as signal_arm64ec.c calls them. Wine's headers define
 * ARM64_NT_CONTEXT and ARM64EC_NT_CONTEXT on every architecture, so the block
 * compiles here as it does for arm64ec.
 */
#include <stdarg.h>
#include <stddef.h>
#include <string.h>

#include "windef.h"
#include "winbase.h"
#include "winnt.h"

#include "wine_unwind_conversions.inc"

void ymm_wine_context_arm_to_x64( ARM64EC_NT_CONTEXT *ec_ctx, const ARM64_NT_CONTEXT *arm_ctx )
{
    context_arm_to_x64( ec_ctx, arm_ctx );
}

void ymm_wine_context_x64_to_arm( ARM64_NT_CONTEXT *arm_ctx, const ARM64EC_NT_CONTEXT *ec_ctx )
{
    context_x64_to_arm( arm_ctx, ec_ctx );
}
