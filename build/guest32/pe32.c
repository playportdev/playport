/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "pe32.h"
#include <stdlib.h>
#include <string.h>

#define PE_READ UINT32_C(0x40000000)
#define PE_WRITE UINT32_C(0x80000000)
#define PE_EXEC UINT32_C(0x20000000)
#define PE_RELOCS_STRIPPED 1u
#define DIR_EXPORT 0u
#define DIR_IMPORT 1u
#define DIR_RELOC 5u

typedef struct {
    uint32_t rva, extent, raw_offset, raw_size;
    unsigned permissions;
} section;

typedef struct {
    g32_pe_image image;
    uint32_t headers, reloc_rva, reloc_size;
    uint16_t characteristics;
    section sections[G32_PE_MAX_SECTIONS];
} layout;

static g32_pe_result bind_imports(g32_space *s, const g32_pe_image *image,
                                  g32_pe_import_resolver resolver, void *context,
                                  layout *unpublished);

static uint16_t le16(const unsigned char *p)
{ return (uint16_t)(p[0] | (uint16_t)p[1] << 8); }
static uint32_t le32(const unsigned char *p)
{ return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void put32(unsigned char *p, uint32_t value)
{ for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(value >> (8 * i)); }
static int span(uint64_t offset, uint64_t size, uint64_t limit)
{ return offset <= limit && size <= limit - offset; }
static int power2(uint32_t n) { return n && !(n & (n - 1)); }
static uint32_t page_up(uint32_t n) { return (n + G32_PAGE - 1) & ~(G32_PAGE - 1); }

static g32_pe_result parse(const unsigned char *f, size_t size, layout *l)
{
    if (!f || size < 64 || le16(f) != 0x5a4d) return G32_PE_FORMAT;
    uint32_t nt = le32(f + 0x3c);
    if (nt < 64 || !span(nt, 24, size) || le32(f + nt) != 0x4550) return G32_PE_FORMAT;
    if (le16(f + nt + 4) != 0x14c) return G32_PE_UNSUPPORTED;
    uint16_t count = le16(f + nt + 6), optional_size = le16(f + nt + 20);
    uint64_t optional_offset = (uint64_t)nt + 24;
    if (!count || count > G32_PE_MAX_SECTIONS || optional_size < 96 ||
        !span(optional_offset, optional_size, size)) return G32_PE_FORMAT;
    const unsigned char *o = f + optional_offset;
    if (le16(o) != 0x10b) return G32_PE_UNSUPPORTED;
    uint32_t section_align = le32(o + 32), file_align = le32(o + 36);
    if (!power2(section_align) || section_align < G32_PAGE ||
        !power2(file_align) || file_align < 512 || file_align > 65536 ||
        section_align < file_align) return G32_PE_UNSUPPORTED;
    uint32_t image_size = le32(o + 56), headers = le32(o + 60);
    uint64_t table = optional_offset + optional_size;
    uint64_t table_size = (uint64_t)count * 40;
    if (!image_size || image_size > G32_PE_MAX_IMAGE || image_size % section_align ||
        !headers || headers > image_size || headers % file_align || !span(0, headers, size) ||
        !span(table, table_size, headers) || page_up(headers) > image_size) return G32_PE_FORMAT;
    uint32_t directory_count = le32(o + 92);
    if (directory_count > 16 || !span(96, (uint64_t)directory_count * 8, optional_size)) return G32_PE_FORMAT;
    memset(l, 0, sizeof(*l));
    l->image.preferred_base = le32(o + 28);
    l->image.entry = le32(o + 16); /* RVA until the map is complete. */
    l->image.size = image_size;
    l->image.sections = count;
    l->headers = headers;
    l->characteristics = le16(f + nt + 22);
    if (!(l->characteristics & 2) || l->image.entry >= image_size) return G32_PE_FORMAT;
    if (directory_count > DIR_EXPORT) {
        l->image.exports_rva = le32(o + 96 + DIR_EXPORT * 8);
        l->image.exports_size = le32(o + 100 + DIR_EXPORT * 8);
    }
    if (directory_count > DIR_IMPORT) {
        l->image.imports_rva = le32(o + 96 + DIR_IMPORT * 8);
        l->image.imports_size = le32(o + 100 + DIR_IMPORT * 8);
    }
    if (directory_count > DIR_RELOC) {
        l->reloc_rva = le32(o + 96 + DIR_RELOC * 8);
        l->reloc_size = le32(o + 100 + DIR_RELOC * 8);
    }
    if ((!!l->reloc_rva != !!l->reloc_size) ||
        !span(l->reloc_rva, l->reloc_size, image_size) ||
        (!!l->image.imports_rva != !!l->image.imports_size) ||
        !span(l->image.imports_rva, l->image.imports_size, image_size) ||
        (!!l->image.exports_rva != !!l->image.exports_size) ||
        !span(l->image.exports_rva, l->image.exports_size, image_size)) return G32_PE_FORMAT;
    for (unsigned i = 0; i < count; ++i) {
        const unsigned char *s = f + table + i * 40;
        section *d = &l->sections[i];
        uint32_t virtual_size = le32(s + 8), flags = le32(s + 36);
        d->rva = le32(s + 12);
        d->raw_size = le32(s + 16);
        d->raw_offset = le32(s + 20);
        uint32_t extent = virtual_size > d->raw_size ? virtual_size : d->raw_size;
        if (d->rva % section_align || d->rva < page_up(headers) ||
            !span(d->rva, extent, image_size) ||
            (d->raw_size && (d->raw_offset < headers || d->raw_offset % file_align ||
                            d->raw_size % file_align || !span(d->raw_offset, d->raw_size, size))))
            return G32_PE_FORMAT;
        d->extent = page_up(extent);
        if (!span(d->rva, d->extent, image_size)) return G32_PE_FORMAT;
        if (flags & PE_READ) d->permissions |= G32_READ;
        if (flags & PE_WRITE) d->permissions |= G32_WRITE;
        if (flags & PE_EXEC) d->permissions |= G32_EXEC;
        for (unsigned j = 0; j < i; ++j) {
            const section *previous = &l->sections[j];
            if (d->extent && previous->extent &&
                d->rva < (uint64_t)previous->rva + previous->extent &&
                previous->rva < (uint64_t)d->rva + d->extent) return G32_PE_FORMAT;
        }
    }
    return G32_PE_OK;
}

static int image_read(g32_space *s, const g32_pe_image *i, uint32_t rva, void *data, size_t size)
{
    return span(rva, size, i->size) &&
           g32_read(s, i->base + rva, data, size) == G32_OK;
}

static g32_pe_result relocate(g32_space *s, layout *l)
{
    uint32_t delta = l->image.base - l->image.preferred_base;
    if (!delta) return G32_PE_OK;
    if ((l->characteristics & PE_RELOCS_STRIPPED) || !l->reloc_size) return G32_PE_RELOCATION;
    /* Snapshot: relocations may target the relocation table itself. Parsing
     * mutable guest bytes while applying fixups would let a fixup change later
     * records. File bounds/guest commitment were validated before this copy. */
    unsigned char *records = malloc(l->reloc_size);
    if (!records) return G32_PE_MEMORY;
    g32_pe_result result = G32_PE_RELOCATION;
    if (!image_read(s, &l->image, l->reloc_rva, records, l->reloc_size)) goto done;
    uint32_t cursor = 0;
    while (cursor < l->reloc_size) {
        if (!span(cursor, 8, l->reloc_size)) goto done;
        uint32_t page = le32(records + cursor), block = le32(records + cursor + 4);
        if (page % G32_PAGE || page >= l->image.size || block < 8 || block % 2 ||
            !span(cursor, block, l->reloc_size)) goto done;
        for (uint32_t offset = 8; offset < block; offset += 2) {
            uint16_t record = le16(records + cursor + offset);
            unsigned type = record >> 12;
            if (!type) continue; /* IMAGE_REL_BASED_ABSOLUTE padding */
            if (type != 3) { result = G32_PE_UNSUPPORTED; goto done; }
            uint32_t target = page + (record & 0xfff);
            unsigned char value[4];
            if (!image_read(s, &l->image, target, value, sizeof(value))) goto done;
            put32(value, le32(value) + delta); /* Win32 relocation arithmetic */
            if (g32_write(s, l->image.base + target, value, sizeof(value)) != G32_OK) goto done;
            ++l->image.relocations;
        }
        cursor += block;
    }
    result = G32_PE_OK;
done:
    free(records);
    return result;
}

static g32_pe_result finalize(g32_space *s, layout *l)
{
    if (g32_protect(s, l->image.base, page_up(l->headers), G32_READ) != G32_OK)
        return G32_PE_MEMORY;
    for (unsigned n = 0; n < l->image.sections; ++n) {
        const section *d = &l->sections[n];
        if (d->extent && g32_protect(s, l->image.base + d->rva, d->extent, d->permissions) != G32_OK)
            return G32_PE_MEMORY;
    }
    if (l->image.entry) {
        void *instruction;
        if (g32_translate(s, l->image.base + l->image.entry, 1, G32_EXEC, &instruction) != G32_OK)
            return G32_PE_FORMAT;
        l->image.entry += l->image.base;
    }
    return G32_PE_OK;
}

static g32_pe_result map_image(g32_space *s, const void *file, size_t size,
                               uint32_t base, g32_pe_import_resolver resolver,
                               void *context, g32_pe_image *output)
{
    if (!s || !output) return G32_PE_FORMAT;
    layout l;
    g32_pe_result result = parse(file, size, &l);
    if (result != G32_PE_OK) return result;
    if (!base) base = l.image.preferred_base;
    if (base < G32_GRANULE || base % G32_GRANULE ||
        !span(base, l.image.size, UINT64_C(1) << 32)) return G32_PE_ADDRESS;
    g32_result vm = g32_reserve(s, base, l.image.size);
    if (vm != G32_OK) return vm == G32_SYSTEM ? G32_PE_MEMORY : G32_PE_ADDRESS;
    l.image.base = base;
    l.image.space = s;
    result = G32_PE_MEMORY;
    unsigned initial = G32_READ | G32_WRITE;
    if (g32_commit(s, base, page_up(l.headers), initial) != G32_OK ||
        g32_write(s, base, file, l.headers) != G32_OK) goto failed;
    for (unsigned n = 0; n < l.image.sections; ++n) {
        const section *d = &l.sections[n];
        if (!d->extent) continue;
        if (g32_commit(s, base + d->rva, d->extent, initial) != G32_OK ||
            (d->raw_size && g32_write(s, base + d->rva,
                                      (const unsigned char *)file + d->raw_offset, d->raw_size) != G32_OK))
            goto failed;
    }
    result = relocate(s, &l);
    if (result != G32_PE_OK) goto failed;
    result = resolver ? bind_imports(s, &l.image, resolver, context, &l) : finalize(s, &l);
    if (result != G32_PE_OK) goto failed;
    *output = l.image;
    return G32_PE_OK;
failed:
    if (g32_release(s, base) == G32_SYSTEM) return G32_PE_MEMORY;
    return result;
}

g32_pe_result g32_pe_map(g32_space *s, const void *file, size_t size,
                         uint32_t base, g32_pe_image *output)
{
    return map_image(s, file, size, base, NULL, NULL, output);
}

g32_pe_result g32_pe_map_bound(g32_space *s, const void *file, size_t size,
                               uint32_t base, g32_pe_import_resolver resolver,
                               void *context, g32_pe_image *output)
{
    if (!resolver) return G32_PE_FORMAT;
    return map_image(s, file, size, base, resolver, context, output);
}

g32_result g32_pe_unmap(g32_space *s, const g32_pe_image *image)
{
    if (!image || image->space != s) return G32_RANGE;
    return g32_release(s, image->base);
}

static int image_string(g32_space *s, const g32_pe_image *image, uint32_t rva,
                        char *destination, size_t capacity)
{
    for (size_t n = 0; n < capacity; ++n) {
        if (!span(rva, n + 1, image->size) ||
            !image_read(s, image, rva + (uint32_t)n, &destination[n], 1)) return 0;
        if (!destination[n]) return n != 0;
    }
    return 0;
}

g32_pe_result g32_pe_imports(g32_space *s, const g32_pe_image *image,
                             g32_pe_import_visitor visitor, void *context)
{
    if (!s || !image || image->space != s || !visitor ||
        image->size > G32_PE_MAX_IMAGE || !span(image->base, image->size, UINT64_C(1) << 32))
        return G32_PE_FORMAT;
    if (!image->imports_rva && !image->imports_size) return G32_PE_OK;
    if (!image->imports_rva || !span(image->imports_rva, image->imports_size, image->size)) return G32_PE_FORMAT;
    uint64_t inspected = 0;
    for (uint32_t offset = 0; span(offset, 20, image->imports_size); offset += 20) {
        unsigned char descriptor[20];
        if (!image_read(s, image, image->imports_rva + offset, descriptor, sizeof(descriptor))) return G32_PE_FORMAT;
        uint32_t lookup = le32(descriptor), name = le32(descriptor + 12), iat = le32(descriptor + 16);
        if (!lookup && !name && !iat && !le32(descriptor + 4) && !le32(descriptor + 8)) return G32_PE_OK;
        if (!lookup) lookup = iat;
        char dll[260];
        if (!lookup || !iat || !image_string(s, image, name, dll, sizeof(dll))) return G32_PE_FORMAT;
        for (uint64_t n = 0; ; ++n) {
            /* A shared/cyclic thunk table must not multiply the traversal budget
             * by the descriptor count. This is an inspection resource limit. */
            if (++inspected > UINT32_C(1048576)) return G32_PE_UNSUPPORTED;
            uint64_t source = (uint64_t)lookup + n * 4, target = (uint64_t)iat + n * 4;
            unsigned char slot[4], iat_slot[4];
            if (!span(source, 4, image->size) || !span(target, 4, image->size) ||
                !image_read(s, image, (uint32_t)source, slot, sizeof(slot)) ||
                !image_read(s, image, (uint32_t)target, iat_slot, sizeof(iat_slot))) return G32_PE_FORMAT;
            uint32_t thunk = le32(slot);
            if (!thunk) break;
            char symbol[260];
            uint16_t ordinal = 0;
            const char *symbol_name = NULL;
            if (thunk & UINT32_C(0x80000000)) {
                if (thunk & UINT32_C(0x7fff0000)) return G32_PE_FORMAT;
                ordinal = (uint16_t)thunk;
            } else {
                unsigned char hint[2];
                if (!image_read(s, image, thunk, hint, sizeof(hint)) ||
                    !span(thunk, 3, image->size) ||
                    !image_string(s, image, thunk + 2, symbol, sizeof(symbol))) return G32_PE_FORMAT;
                symbol_name = symbol;
            }
            if (visitor(context, dll, symbol_name, ordinal, image->base + (uint32_t)target))
                return G32_PE_OK;
        }
    }
    return G32_PE_FORMAT; /* No terminating descriptor within the directory. */
}

static int image_table(g32_space *s, const g32_pe_image *image,
                       uint32_t rva, uint32_t count, unsigned width)
{
    if (!count) return 1;
    void *loan;
    uint64_t bytes = (uint64_t)count * width;
    return rva && span(rva, bytes, image->size) &&
           g32_translate(s, image->base + rva, bytes, G32_READ, &loan) == G32_OK;
}

g32_pe_result g32_pe_find_export(g32_space *s, const g32_pe_image *image,
                                 const char *symbol, uint32_t ordinal,
                                 g32_pe_export *output)
{
    if (!s || !image || image->space != s || !output ||
        !image->size || image->size > G32_PE_MAX_IMAGE ||
        !span(image->base, image->size, UINT64_C(1) << 32)) return G32_PE_FORMAT;
    if (!image->exports_rva && !image->exports_size) return G32_PE_NOT_FOUND;
    if (!image->exports_rva || image->exports_size < 40 ||
        !span(image->exports_rva, image->exports_size, image->size)) return G32_PE_FORMAT;
    unsigned char directory[40];
    if (!image_read(s, image, image->exports_rva, directory, sizeof(directory))) return G32_PE_FORMAT;
    uint32_t first = le32(directory + 16), functions = le32(directory + 20);
    uint32_t names = le32(directory + 24), eat = le32(directory + 28);
    uint32_t name_table = le32(directory + 32), ordinal_table = le32(directory + 36);
    if (functions > G32_PE_MAX_EXPORTS || names > G32_PE_MAX_EXPORTS) return G32_PE_UNSUPPORTED;
    if (!span(first, functions, UINT64_C(1) << 32) ||
        !image_table(s, image, eat, functions, 4) ||
        !image_table(s, image, name_table, names, 4) ||
        !image_table(s, image, ordinal_table, names, 2)) return G32_PE_FORMAT;
    uint32_t index = UINT32_MAX;
    if (!symbol && ordinal >= first && (uint64_t)ordinal - first < functions)
        index = ordinal - first;
    for (uint32_t n = 0; n < names; ++n) {
        unsigned char name_rva[4], name_index[2];
        char name[260];
        if (!image_read(s, image, name_table + n * 4, name_rva, 4) ||
            !image_read(s, image, ordinal_table + n * 2, name_index, 2) ||
            le16(name_index) >= functions ||
            !image_string(s, image, le32(name_rva), name, sizeof(name))) return G32_PE_FORMAT;
        if (symbol && strcmp(symbol, name) == 0) {
            if (index != UINT32_MAX) return G32_PE_FORMAT; /* Ambiguous duplicate name. */
            index = le16(name_index);
        }
    }
    if (index == UINT32_MAX) return G32_PE_NOT_FOUND;
    unsigned char slot[4];
    if (!image_read(s, image, eat + index * 4, slot, 4)) return G32_PE_FORMAT;
    uint32_t rva = le32(slot);
    if (!rva) return G32_PE_NOT_FOUND; /* EAT hole, never image.base. */
    g32_pe_export result = { .ordinal = first + index };
    if (rva >= image->exports_rva &&
        (uint64_t)rva < (uint64_t)image->exports_rva + image->exports_size) {
        result.kind = G32_PE_EXPORT_FORWARDER;
        uint64_t remaining = (uint64_t)image->exports_rva + image->exports_size - rva;
        size_t capacity = remaining < sizeof(result.forwarder) ? (size_t)remaining : sizeof(result.forwarder);
        if (!image_string(s, image, rva, result.forwarder, capacity)) return G32_PE_FORMAT;
    } else {
        void *target;
        if (!span(rva, 1, image->size) ||
            (g32_translate(s, image->base + rva, 1, G32_READ, &target) != G32_OK &&
             g32_translate(s, image->base + rva, 1, G32_EXEC, &target) != G32_OK)) return G32_PE_FORMAT;
        result.kind = G32_PE_EXPORT_ADDRESS;
        result.address = image->base + rva;
    }
    *output = result;
    return G32_PE_OK;
}

typedef struct {
    char name[260];
    g32_pe_image image;
} module_entry;

struct g32_pe_modules {
    g32_space *space;
    size_t count;
    module_entry entries[];
};

static int copy_name(const char *source, char destination[260])
{
    if (!source) return 0;
    for (size_t n = 0; n < 260; ++n) {
        destination[n] = source[n];
        if (!source[n]) return n != 0;
    }
    return 0;
}

static int module_name(const char *source, char destination[260])
{
    if (!copy_name(source, destination)) return 0;
    size_t length = strlen(destination);
    if (destination[0] == '.' || destination[length - 1] == '.') return 0;
    int dot = 0;
    for (size_t n = 0; n < length; ++n) {
        unsigned char c = (unsigned char)destination[n];
        if (c < 0x21 || c > 0x7e || c == '/' || c == '\\' || c == ':') return 0;
        if (c >= 'A' && c <= 'Z') destination[n] = (char)(c + ('a' - 'A'));
        if (c == '.') dot = 1;
    }
    if (!dot) {
        if (length + 4 >= 260) return 0;
        memcpy(destination + length, ".dll", 5);
    }
    return 1;
}

g32_pe_result g32_pe_modules_create(g32_space *s, const g32_pe_module *modules,
                                     size_t count, g32_pe_modules **output)
{
    if (!s || !output || (count && !modules)) return G32_PE_FORMAT;
    if (count > G32_PE_MAX_MODULES) return G32_PE_UNSUPPORTED;
    g32_pe_modules *table = calloc(1, sizeof(*table) + count * sizeof(module_entry));
    if (!table) return G32_PE_MEMORY;
    table->space = s;
    table->count = count;
    for (size_t n = 0; n < count; ++n) {
        const g32_pe_image *image = modules[n].image;
        void *header;
        if (!module_name(modules[n].name, table->entries[n].name) || !image ||
            image->space != s || image->base < G32_GRANULE || image->base % G32_GRANULE ||
            !image->size || image->size > G32_PE_MAX_IMAGE ||
            !span(image->base, image->size, UINT64_C(1) << 32) ||
            g32_translate(s, image->base, 1, G32_READ, &header) != G32_OK) goto malformed;
        for (size_t j = 0; j < n; ++j)
            if (!strcmp(table->entries[j].name, table->entries[n].name)) goto malformed;
        table->entries[n].image = *image;
    }
    *output = table;
    return G32_PE_OK;
malformed:
    free(table);
    return G32_PE_FORMAT;
}

void g32_pe_modules_destroy(g32_pe_modules *modules) { free(modules); }

g32_pe_result g32_pe_resolve_export(const g32_pe_modules *modules, const char *dll,
                                    const char *symbol, uint32_t ordinal,
                                    uint32_t *guest_address)
{
    char module[260], name[260];
    if (!modules || !guest_address || !module_name(dll, module) ||
        (symbol && !copy_name(symbol, name))) return G32_PE_FORMAT;
    int named = symbol != NULL;
    struct { uint32_t base, ordinal; } visited[G32_PE_MAX_RESOLVE_DEPTH];
    for (size_t depth = 0; depth < G32_PE_MAX_RESOLVE_DEPTH; ++depth) {
        const g32_pe_image *image = NULL;
        for (size_t n = 0; n < modules->count; ++n)
            if (!strcmp(module, modules->entries[n].name)) {
                image = &modules->entries[n].image;
                break;
            }
        if (!image) return G32_PE_NOT_FOUND;
        g32_pe_export found;
        g32_pe_result result = g32_pe_find_export(modules->space, image,
                                                  named ? name : NULL, ordinal, &found);
        if (result != G32_PE_OK) return result;
        for (size_t n = 0; n < depth; ++n)
            if (visited[n].base == image->base && visited[n].ordinal == found.ordinal)
                return G32_PE_CYCLE;
        visited[depth].base = image->base;
        visited[depth].ordinal = found.ordinal;
        if (found.kind == G32_PE_EXPORT_ADDRESS) {
            *guest_address = found.address;
            return G32_PE_OK;
        }
        char *separator = strrchr(found.forwarder, '.');
        if (!separator || !separator[1]) return G32_PE_FORMAT;
        *separator = 0;
        if (!module_name(found.forwarder, module)) return G32_PE_FORMAT;
        const char *target = separator + 1;
        named = *target != '#';
        if (named) {
            if (!copy_name(target, name)) return G32_PE_FORMAT;
        } else {
            if (!*++target) return G32_PE_FORMAT;
            ordinal = 0;
            for (; *target; ++target) {
                if (*target < '0' || *target > '9') return G32_PE_FORMAT;
                unsigned digit = (unsigned)(*target - '0');
                if (ordinal > (UINT32_MAX - digit) / 10) return G32_PE_FORMAT;
                ordinal = ordinal * 10 + digit;
            }
        }
    }
    return G32_PE_UNSUPPORTED;
}

int g32_pe_resolve_import(void *context, const char *dll, const char *symbol,
                          uint16_t ordinal, uint64_t *guest_address)
{
    uint32_t address;
    if (!guest_address || g32_pe_resolve_export(context, dll, symbol, ordinal, &address) != G32_PE_OK)
        return 0;
    *guest_address = address;
    return 1;
}

typedef struct {
    char dll[260], symbol[260];
    uint16_t ordinal;
    int named;
    uint32_t iat, address;
    void *write_loan;
} binding;

typedef struct {
    binding *items;
    size_t count, capacity;
    g32_pe_result result;
} bindings;

static int collect_binding(void *context, const char *dll, const char *symbol,
                           uint16_t ordinal, uint32_t iat)
{
    bindings *b = context;
    if (b->count == G32_PE_MAX_BIND_IMPORTS) {
        b->result = G32_PE_UNSUPPORTED;
        return 1;
    }
    if (b->count == b->capacity) {
        size_t capacity = b->capacity ? b->capacity * 2 : 16;
        binding *items = realloc(b->items, capacity * sizeof(*items));
        if (!items) { b->result = G32_PE_MEMORY; return 1; }
        b->items = items;
        b->capacity = capacity;
    }
    binding *item = &b->items[b->count++];
    memset(item, 0, sizeof(*item));
    memcpy(item->dll, dll, strlen(dll) + 1);
    if (symbol) memcpy(item->symbol, symbol, strlen(symbol) + 1);
    item->named = symbol != NULL;
    item->ordinal = ordinal;
    item->iat = iat;
    return 0;
}

static int binding_order(const void *a, const void *b)
{
    const binding *left = a, *right = b;
    return (left->iat > right->iat) - (left->iat < right->iat);
}

static int accessible_target(g32_space *s, uint32_t address)
{
    void *target;
    return g32_translate(s, address, 1, G32_READ, &target) == G32_OK ||
           g32_translate(s, address, 1, G32_EXEC, &target) == G32_OK;
}

static g32_pe_result bind_imports(g32_space *s, const g32_pe_image *image,
                                  g32_pe_import_resolver resolver, void *context,
                                  layout *unpublished)
{
    if (!resolver) return G32_PE_FORMAT;
    bindings b = { .result = G32_PE_OK };
    g32_pe_result result = g32_pe_imports(s, image, collect_binding, &b);
    if (result != G32_PE_OK) goto done;
    result = b.result;
    if (result != G32_PE_OK) goto done;
    /* No guest writes during lookup traversal, including FirstThunk fallback
     * and IAT slots aliasing lookup strings. Reject conflicting writes. */
    if (b.count) qsort(b.items, b.count, sizeof(*b.items), binding_order);
    for (size_t n = 0; n < b.count; ++n) {
        if (n && (uint64_t)b.items[n - 1].iat + 4 > b.items[n].iat) {
            result = G32_PE_FORMAT;
            goto done;
        }
    }
    result = G32_PE_IMPORT;
    for (size_t n = 0; n < b.count; ++n) {
        binding *item = &b.items[n];
        uint64_t address = 0;
        if (!resolver(context, item->dll, item->named ? item->symbol : NULL,
                      item->ordinal, &address) || address > UINT32_MAX)
            goto done;
        item->address = (uint32_t)address;
    }
    /* Validate after all callbacks, then retain checked write loans until the
     * serialized commit. There are no fallible operations in the write phase. */
    for (size_t n = 0; n < b.count; ++n) {
        binding *item = &b.items[n];
        if (!accessible_target(s, item->address) ||
            g32_translate(s, item->iat, 4, G32_WRITE, &item->write_loan) != G32_OK)
            goto done;
    }
    for (size_t n = 0; n < b.count; ++n)
        put32(b.items[n].write_loan, b.items[n].address);
    if (unpublished) {
        /* Only a new image can be discarded after a post-write failure. Never
         * use the now-expired write loans after changing guest permissions. */
        result = finalize(s, unpublished);
        if (result != G32_PE_OK) goto done;
        result = G32_PE_IMPORT;
        for (size_t n = 0; n < b.count; ++n)
            if (!accessible_target(s, b.items[n].address)) goto done;
    }
    result = G32_PE_OK;
done:
    free(b.items);
    return result;
}

g32_pe_result g32_pe_bind_imports(g32_space *s, const g32_pe_image *image,
                                  g32_pe_import_resolver resolver, void *context)
{
    return bind_imports(s, image, resolver, context, NULL);
}
