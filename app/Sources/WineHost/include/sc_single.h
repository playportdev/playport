/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_SC_SINGLE_H
#define PLAYPORT_SC_SINGLE_H

/* Decision 0150: even an inherited or saved runtime key cannot enable the
 * helper's in-memory compatibility patch in a release executable. */
static inline int pp_sc_single_enabled(const char *value)
{
#ifdef PLAYPORT_RELEASE
    (void)value;
    return 0;
#else
    return value && value[0] == '1' && value[1] == 0;
#endif
}

#endif
