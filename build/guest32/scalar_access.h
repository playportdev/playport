/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_GUEST32_SCALAR_ACCESS_H
#define PLAYPORT_GUEST32_SCALAR_ACCESS_H

#ifdef __cplusplus
extern "C" {
#endif
#include "guest32.h"

/* Host-only candidate helper ABI, NOT installed in FEX or the app.
 * Only byte/word/dword low-register MOV and FNSTCW-style stores are supported.
 * operation is the byte width (1, 2 or 4), optionally ORed with STORE. All other
 * bits are invalid. address is WIDE deliberately: reject native pointers or
 * dirty upper bits instead of truncating them. Guest arithmetic must already
 * have wrapped to 32 bits at the call site.
 *
 * space is the ONLY native-pointer argument. value is the old 32-bit destination
 * for loads, or the 32-bit source for stores. There are no buffer/CPU-state
 * pointers and no pointer loans returned. The uint64_t result has g32_result
 * in bits 63:32 and a 32-bit value in bits 31:0. On success a load replaces only
 * the low width bytes; a store returns its unchanged input value. Any rejection
 * returns the original value and changes no guest bytes or VM metadata.
 * Memory is little endian regardless of host endianness. Complete width and
 * permissions are checked before any read/write by the serialized g32 API.
 *
 * This is a ordinary native C ABI, NOT a special FEX preserve-all convention.
 * A lowering must save live caller-clobbered registers/flags, check status before
 * publishing a destination or continuing execution, and report the guest PC.
 * Fault delivery, helper-call emission, atomics, concurrency and other memory
 * families are absent. External serialization is mandatory throughout a call.
 */
#define G32_SCALAR_STORE 0x100u
uint64_t g32_scalar_access(g32_space *space, uint64_t address,
                          uint32_t operation, uint32_t value);

static inline g32_result g32_scalar_status(uint64_t result)
{ return (g32_result)(result >> 32); }
static inline uint32_t g32_scalar_value(uint64_t result)
{ return (uint32_t)result; }

#ifdef __cplusplus
}
#endif
#endif
