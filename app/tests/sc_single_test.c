/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "sc_single.h"
#include <assert.h>

/* Single-process is on by default in both builds (PLA-476 chunk 4, decision 0169). A dev
 * build's PLAYPORT_SC_SINGLE=0 turns it off; a release build takes no runtime key from a person,
 * so it stays on whatever the environment says. */
int main(void)
{
    assert(pp_sc_single_enabled(0));
    assert(pp_sc_single_enabled(""));
    assert(pp_sc_single_enabled("1"));
    assert(pp_sc_single_enabled("true"));
#ifdef PLAYPORT_RELEASE
    assert(pp_sc_single_enabled("0"));
#else
    assert(!pp_sc_single_enabled("0"));
#endif
    return 0;
}
