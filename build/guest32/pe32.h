/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_GUEST32_PE32_H
#define PLAYPORT_GUEST32_PE32_H
#include "guest32.h"

/* Experimental IMAGE mapping, not a Windows loader. No dependency loading,
 * import binding, TLS/DllMain calls, PEB/TEB or instruction execution. Input is
 * an untrusted file buffer. Mapping never makes native memory executable. */
#define G32_PE_MAX_IMAGE (UINT32_C(512) * 1024 * 1024)
#define G32_PE_MAX_SECTIONS 96u

typedef enum {
    G32_PE_OK, G32_PE_FORMAT, G32_PE_UNSUPPORTED, G32_PE_ADDRESS,
    G32_PE_MEMORY, G32_PE_RELOCATION
} g32_pe_result;

typedef struct {
    g32_space *space; /* Native ownership metadata, never written into the guest. */
    uint32_t base, preferred_base, size, entry;
    uint32_t imports_rva, imports_size;
    unsigned sections, relocations;
} g32_pe_image;

/* base=0 selects the preferred guest ImageBase. Non-preferred mappings require
 * valid i386 HIGHLOW/ABSOLUTE relocation records. Failure leaves output
 * unchanged and releases only the reservation acquired by this call. A native
 * VM failure can poison the space (guest32.h); callers must then destroy it. */
g32_pe_result g32_pe_map(g32_space *space, const void *file, size_t file_size,
                         uint32_t base, g32_pe_image *output);
/* The image belongs to one space. Its metadata/loans expire on unmap; do not
 * use a stale image after releasing or replacing its reservation directly. */
g32_result g32_pe_unmap(g32_space *space, const g32_pe_image *image);

/* Bounded import inspection, not resolution. Callback strings live only during
 * the callback. iat is a GUEST address, never a native pointer. An ordinal import
 * has symbol=NULL; ordinal=0 for named imports. Stop by returning nonzero.
 * Earlier callbacks may have run when malformed later records are rejected. */
typedef int (*g32_pe_import_visitor)(void *context, const char *dll,
                                    const char *symbol, uint16_t ordinal,
                                    uint32_t iat);
g32_pe_result g32_pe_imports(g32_space *space, const g32_pe_image *image,
                             g32_pe_import_visitor visitor, void *context);
#endif
