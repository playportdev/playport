/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_AUTH_PROBE_H
#define PLAYPORT_AUTH_PROBE_H
#include <stddef.h>
/* Dev Settings only. Synthetic credentials, no network or store session. */
int playport_native_auth_probe(char *report, size_t capacity);
#endif
