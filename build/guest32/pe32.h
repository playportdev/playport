/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_GUEST32_PE32_H
#define PLAYPORT_GUEST32_PE32_H
#include "guest32.h"

/* Experimental IMAGE mapping, not a Windows loader. No dependency loading,
 * TLS/DllMain calls, PEB/TEB or instruction execution. Input is
 * an untrusted file buffer. Mapping never makes native memory executable. */
#define G32_PE_MAX_IMAGE (UINT32_C(512) * 1024 * 1024)
#define G32_PE_MAX_SECTIONS 96u

typedef enum {
    G32_PE_OK, G32_PE_FORMAT, G32_PE_UNSUPPORTED, G32_PE_ADDRESS,
    G32_PE_MEMORY, G32_PE_RELOCATION, G32_PE_IMPORT, G32_PE_NOT_FOUND,
    G32_PE_CYCLE, G32_PE_NO_SPACE
} g32_pe_result;

typedef struct {
    g32_space *space; /* Native ownership metadata, never written into the guest. */
    uint32_t base, preferred_base, size, entry;
    uint32_t imports_rva, imports_size;
    uint32_t exports_rva, exports_size;
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

/* Transactional IAT binding with an external resolver, NOT dependency loading.
 * Return nonzero and a guest address (wide solely to reject host pointers rather
 * than truncate them). Zero means unresolved. Named and ordinal imports include
 * data exports: targets must be readable OR fetchable in this same space.
 * Snapshot/validate every import before resolving; resolution order is unspecified.
 * The resolver must not change guest memory/mappings or reenter this API. Callback
 * strings expire on return. Failed binding leaves guest bytes/permissions intact;
 * resolver-side effects are not rolled back. IAT slots must already be writable:
 * this API never broadens guest protections. Overlapping slots are rejected.
 * FirstThunk fallback works once, but cannot be rebound without restoring lookup
 * data. Bound-address/delay imports are absent. resolve_import below can follow
 * forwarders through already-mapped dependencies.
 * At most 65536 imports per binding; use remains externally serialized. */
#define G32_PE_MAX_BIND_IMPORTS 65536u
typedef int (*g32_pe_import_resolver)(void *context, const char *dll,
                                     const char *symbol, uint16_t ordinal,
                                     uint64_t *guest_address);
g32_pe_result g32_pe_bind_imports(g32_space *space, const g32_pe_image *image,
                                  g32_pe_import_resolver resolver, void *context);
/* Map, relocate and bind a NEW image before applying final PE permissions.
 * Unlike bind_imports on an existing image, read-only IAT sections work without
 * leaving them writable. Resolver is required, even for a no-import image;
 * dependencies must already exist. No native execution or dependency loading.
 * Same callback/resource restrictions as bind_imports. The unpublished image
 * is RW (not guest executable) during callbacks; do not read/modify it or retain
 * loans into it. Targets are checked again AFTER final permissions, including
 * self-import targets. Failure leaves output unchanged and releases only this
 * call's image, not dependencies; resolver-side effects are not rolled back.
 * Native VM failure may poison the space, as for map. */
g32_pe_result g32_pe_map_bound(g32_space *space, const void *file, size_t file_size,
                               uint32_t base, g32_pe_import_resolver resolver,
                               void *context, g32_pe_image *output);
/* Automatic placement in [lower, upper), upper may be 2^32. Prefer the file's
 * ImageBase if valid, wholly in bounds and unoccupied; otherwise first-fit at
 * 64 KiB alignment. Fallback requires non-stripped relocation records; malformed
 * fixups fail transactionally, not by trying another base. Invalid bounds return
 * ADDRESS, exhausted relocatable windows NO_SPACE, fixed-base fallback RELOCATION.
 * Low 64 KiB remains unavailable. Reserve exactly once, then use the same mapping,
 * protections and rollback contract as map/map_bound. No dependency loading or
 * Windows ASLR policy. Bound form requires a resolver and already-live dependencies.
 * Failures preserve output and other allocations. Externally serialized use only. */
g32_pe_result g32_pe_map_auto(g32_space *space, const void *file, size_t file_size,
                              uint32_t lower, uint64_t upper, g32_pe_image *output);
g32_pe_result g32_pe_map_bound_auto(g32_space *space, const void *file, size_t file_size,
                                    uint32_t lower, uint64_t upper,
                                    g32_pe_import_resolver resolver, void *context,
                                    g32_pe_image *output);
/* Checked export lookup, NOT dependency loading or forwarder resolution.
 * symbol!=NULL selects an exact case-sensitive name (ordinal ignored); NULL
 * selects the full export ordinal, not an EAT index. Missing/zero EAT entries
 * return NOT_FOUND. Output is unchanged on every failure. Function/data targets
 * must be readable or fetchable within THIS image in THIS space. Forwarders
 * return a bounded copy instead of a callable address; resolve_export below can
 * follow them with dependency/cycle checks. Names/forwarders are limited to
 * 259 bytes plus NUL. Table spans and all name/ordinal pairs are checked before
 * lookup completes, but unselected EAT targets are not validated. At most 65536
 * function entries and 65536 names; aliases and unsorted name tables work.
 * Metadata/addresses expire on unmap; calls require external serialization. */
#define G32_PE_MAX_EXPORTS 65536u
typedef enum { G32_PE_EXPORT_ADDRESS, G32_PE_EXPORT_FORWARDER } g32_pe_export_kind;
typedef struct {
    g32_pe_export_kind kind;
    uint32_t ordinal, address; /* address=0 for a forwarder; never a host pointer. */
    char forwarder[260];       /* empty for an address export. */
} g32_pe_export;
g32_pe_result g32_pe_find_export(g32_space *space, const g32_pe_image *image,
                                 const char *symbol, uint32_t ordinal,
                                 g32_pe_export *output);

/* Immutable native snapshot of ALREADY mapped module names/image metadata.
 * Not dependency loading: no files, API sets, search paths, TLS or DllMain.
 * Names are ASCII basenames, case-insensitive; a name without any dot gains
 * .dll. Paths, empty names, leading/trailing dots and nonprintable/non-ASCII
 * bytes are rejected. Names (including appended suffix) fit 259 bytes + NUL.
 * Duplicate canonical names are rejected, but aliases of one image are allowed.
 * All images must belong to space and remain live and externally serialized
 * until table destruction. Destroying the table does NOT unmap its images.
 * Creation and resolution leave outputs unchanged on failure. No guest writes.
 * At most 256 modules and 32 selected exports per resolution. Forwarders split
 * at their LAST dot; #ordinals must be strict decimal uint32_t (zero allowed).
 * Symbols are bounded, nonempty, case-sensitive. Cycles are detected by image
 * base + export ordinal, including name/module aliases. Missing modules/exports
 * return NOT_FOUND, malformed syntax FORMAT, cycles CYCLE, depth UNSUPPORTED.
 * Resolution returns only a checked guest address, never a forwarder string. */
#define G32_PE_MAX_MODULES 256u
#define G32_PE_MAX_RESOLVE_DEPTH 32u
typedef struct { const char *name; const g32_pe_image *image; } g32_pe_module;
typedef struct g32_pe_modules g32_pe_modules;
g32_pe_result g32_pe_modules_create(g32_space *space, const g32_pe_module *modules,
                                     size_t count, g32_pe_modules **output);
void g32_pe_modules_destroy(g32_pe_modules *modules);
g32_pe_result g32_pe_resolve_export(const g32_pe_modules *modules, const char *dll,
                                    const char *symbol, uint32_t ordinal,
                                    uint32_t *guest_address);
/* Adapter for bind_imports/map_bound: context is a live g32_pe_modules table.
 * All non-OK results become unresolved (zero); output is unchanged on failure. */
int g32_pe_resolve_import(void *context, const char *dll, const char *symbol,
                          uint16_t ordinal, uint64_t *guest_address);
#endif
