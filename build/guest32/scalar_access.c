/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "scalar_access.h"

static uint64_t pack(g32_result status, uint32_t value)
{ return ((uint64_t)status << 32) | value; }

uint64_t g32_scalar_access(g32_space *space, uint64_t address,
                          uint32_t operation, uint32_t value)
{
    uint32_t width = operation & ~G32_SCALAR_STORE;
    if ((width != 1 && width != 2 && width != 4) || address > UINT32_MAX)
        return pack(G32_RANGE, value);
    unsigned char bytes[4];
    g32_result status;
    if (operation & G32_SCALAR_STORE) {
        for (uint32_t i = 0; i < width; ++i) bytes[i] = (unsigned char)(value >> (i * 8));
        status = g32_write(space, (uint32_t)address, bytes, width);
    } else {
        status = g32_read(space, (uint32_t)address, bytes, width);
        if (status == G32_OK) {
            for (uint32_t i = 0; i < width; ++i)
                value = (value & ~(UINT32_C(0xff) << (i * 8))) | ((uint32_t)bytes[i] << (i * 8));
        }
    }
    return pack(status, value);
}
