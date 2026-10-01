/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * prefix_registry — seed a Wine prefix's registry hives from the bundle.
 *
 * The app never runs wineboot, so the builtins' registrations (COM classes
 * above all: CoCreateInstance(CLSID_MMDeviceEnumerator) is how every title
 * reaches the audio driver) are generated at build time by
 * app/tools/prefix-registry.py into Runtime/registry/{system,user}.reg,
 * in wineserver's own file format. Before the wineserver starts, each seed
 * section whose key the prefix's hive does not have yet is appended to it.
 * A key it has is left alone, except a profile key, whose seed section
 * follows a ";; playport:top-up" line: it gets the seed's values it lacks.
 * A value the prefix already holds is never changed, so a user or title
 * change survives, and an app update that ships more classes adds only those.
 */

#ifndef PREFIX_REGISTRY_H
#define PREFIX_REGISTRY_H

#include <stddef.h>

/* Append to hive_path (created with the seed's header if missing) every
 * section of seed_path whose key it lacks, and a section holding the missing
 * values of each marked key it has. Returns the number of sections appended
 * (0 = already complete) or -1; err gets a one-line summary either way. */
int prefix_registry_seed(const char *seed_path, const char *hive_path, char *err, size_t errlen);

#endif
