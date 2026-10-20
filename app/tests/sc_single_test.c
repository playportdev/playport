/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "sc_single.h"
#include <assert.h>

int main(void)
{
    assert(!pp_sc_single_enabled(0));
    assert(!pp_sc_single_enabled(""));
    assert(!pp_sc_single_enabled("0"));
    assert(!pp_sc_single_enabled("true"));
    assert(!pp_sc_single_enabled("10"));
#ifdef PLAYPORT_RELEASE
    assert(!pp_sc_single_enabled("1"));
#else
    assert(pp_sc_single_enabled("1"));
#endif
    return 0;
}
