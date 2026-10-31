/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_SC_SINGLE_H
#define PLAYPORT_SC_SINGLE_H

/* Single-process Social Club (decisions 0150, 0169): on by default in both builds. madeira-unix
 * 0190 still runs only a verified helper (its exact-build preflight) single-process; any other
 * keeps the multi-process path. A dev build's PLAYPORT_SC_SINGLE=0 turns it off; a release build
 * takes no runtime key from a person (decision 0126), so it is always on there. */
static inline int pp_sc_single_enabled(const char *value)
{
#ifdef PLAYPORT_RELEASE
    (void)value;
    return 1;
#else
    return !(value && value[0] == '0' && value[1] == 0);
#endif
}

#endif
