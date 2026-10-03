/* Production section router, complete virtual_map_image function, bounds and
 * unmap transaction; real disjoint mappings, view splitting, guest placement
 * and Wine relocation kernel. Mock Wine layouts/view tree, FD/handle/server
 * transport, builtin bookkeeping and PE section population (not a PE loader).
 * No rbtree, actual section parsing, server/APC/Mach/PE execution is tested.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define WOW64_VM_HELPERS_ONLY
#include "vm_test.c"
#define VPROT_WOW64_IMAGE 0x2000
#define VPROT_WRITECOPY 8
#define SEC_IMAGE 0x1000000
#define SEC_FILE 0x800000
#define SEC_COMMIT 0x8000000
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_FILE_RELOCS_STRIPPED 1
#define IMAGE_FILE_DLL 0x2000
#define IMAGE_FLAGS_ImageMappedFlat 8
#define IMAGE_FLAGS_ImageDynamicallyRelocated 4
#define STATUS_INVALID_IMAGE_FORMAT 11
#define STATUS_IMAGE_NOT_AT_BASE 12
#define STATUS_NOT_MAPPED_VIEW 13
#define STATUS_INVALID_PAGE_PROTECTION 14
#define STATUS_INVALID_PARAMETER_4 15
#define STATUS_INVALID_ADDRESS 16
#define STATUS_ACCESS_VIOLATION 17
#define PAGE_WRITECOPY 8
#define PAGE_EXECUTE_WRITECOPY 0x80
#define SECTION_MAP_READ 1
#define SECTION_MAP_WRITE 2
#define SECTION_MAP_EXECUTE 4
#define DUPLICATE_SAME_ACCESS 2
#define FILE_READ_DATA 1
#define FILE_WRITE_DATA 2
#define NT_SUCCESS(s) ((s) == 0 || (s) == STATUS_IMAGE_NOT_AT_BASE)
#define IMAGE_REL_BASED_ABSOLUTE 0
#define IMAGE_REL_BASED_HIGH 1
#define IMAGE_REL_BASED_LOW 2
#define IMAGE_REL_BASED_HIGHLOW 3
#define IMAGE_REL_BASED_THUMB_MOV32 7
#define IMAGE_REL_BASED_DIR64 10
#define LOWORD(x) ((uint16_t)(x))
#define HIWORD(x) ((uint16_t)((uint64_t)(x) >> 16))
#define MAKELONG(a,b) ((uint32_t)(a) | ((uint32_t)(b) << 16))
#define FIXME(...) ((void)0)
#define ERR(...) ((void)0)
#define VIRTUAL_DEBUG_DUMP_VIEW(v) ((void)0)
typedef uint16_t WORD, USHORT;
typedef uint32_t DWORD;
typedef int64_t INT64;
typedef intptr_t INT_PTR;
typedef uint64_t mem_size_t;
typedef struct { DWORD VirtualAddress, Size; } IMAGE_DATA_DIRECTORY;
typedef struct { DWORD VirtualAddress, SizeOfBlock; } IMAGE_BASE_RELOCATION;
typedef struct { int64_t QuadPart; } LARGE_INTEGER;
typedef enum { ViewShare, ViewUnmap } SECTION_INHERIT;
struct pe_image_info {
    uint64_t base, map_addr; unsigned int machine, image_charact, image_flags;
    size_t map_size; uint64_t entry_point; int is_hybrid;
};
struct pe_mapping_info { struct pe_image_info image; HANDLE shared_file; int nt_name; };
#include "image_reloc.h"
#define mmap test_mmap
#include "wow64_image.h"
#undef mmap
#include "wow64_placement.h"

/* Mock transport enforces host identity and retains registrations/handles. */
static int map_error, unmap_error, fd_error, dup_error, populate_error;
static int live_handles, server_views, mapper_calls;
static uintptr_t server_base;
static size_t server_size;
static uint64_t server_entry;
enum { req_map_image_view, req_unmap_view, req_get_image_map_address };
struct section_request { int kind; HANDLE mapping, handle; uint64_t base, entry; size_t size; int machine; off_t offset; };
struct reply { uint64_t addr; };
#define SERVER_START_REQ(name) { struct section_request request = {.kind = req_##name}; struct section_request *req = &request; struct reply response = {0}; struct reply *reply __attribute__((unused)) = &response;
#define SERVER_END_REQ }
#define wine_server_obj_handle(h) (h)
#define wine_server_client_ptr(p) ((uint64_t)(uintptr_t)(p))
static NTSTATUS wine_server_call(struct section_request *r)
{
    if (r->kind == req_get_image_map_address) return 0;
    if (r->kind == req_map_image_view) {
        if (map_error) return map_error;
        assert(((r->base >= bases[0] && r->base - bases[0] < IOS_WOW64_WINDOW_SIZE) ||
                (r->base >= bases[1] && r->base - bases[1] < IOS_WOW64_WINDOW_SIZE)) &&
               r->entry < IOS_WOW64_WINDOW_SIZE);
        assert(r->machine == IMAGE_FILE_MACHINE_I386 && !r->offset);
        assert(r->size <= 0x11000); /* real server rejects host-rounded excess */
        assert(!server_views); server_views = 1;
        server_base = r->base; server_size = r->size; server_entry = r->entry;
        return STATUS_IMAGE_NOT_AT_BASE; /* host differs from guest */
    }
    if (unmap_error) return unmap_error;
    assert(server_views && r->base == server_base); server_views = 0;
    return 0;
}
static NTSTATUS NtClose(HANDLE h) { assert(h && live_handles > 0); --live_handles; return 0; }
static NTSTATUS NtDuplicateObject(HANDLE from, HANDLE h, HANDLE to, HANDLE *out,
                                  unsigned access, unsigned attrs, unsigned flags)
{
    assert(from == NtCurrentProcess() && to == from && h && !access && !attrs && flags == DUPLICATE_SAME_ACCESS);
    if (dup_error) return dup_error;
    ++live_handles; *out = (HANDLE)11; return 0;
}
static NTSTATUS server_get_unix_fd(HANDLE h, unsigned access, int *fd, int *close_fd, void *a, void *b)
{
    (void)h; (void)access; (void)a; (void)b;
    if (fd_error) return fd_error;
    *fd = -1; *close_fd = 0; return 0;
}
static NTSTATUS map_image_view(struct file_view **out, struct pe_image_info *info, size_t size,
                                uintptr_t low, uintptr_t high, ULONG type, uintptr_t window)
{
    assert(window); /* Native fall-through is tested at the router, not mocked here. */
    return type & MEM_TOP_DOWN ? ios_wow64_place_image_ex(window, info, size, low, high, TRUE, out) :
                               ios_wow64_place_image(window, info, size, low, high, out);
}
/* Population fixture is NOT a second PE mapper: a relocation block in writable
 * anonymous storage replaces Wine's header/file/section I/O for this test. */
static NTSTATUS map_image_into_view(struct file_view *v, const int *name, int fd,
                                    struct pe_image_info *info, USHORT machine, int shared, BOOL removable)
{
    (void)name; (void)fd; (void)shared; (void)removable;
    ++mapper_calls; assert(machine == IMAGE_FILE_MACHINE_I386);
    char *p = v->base; uint32_t target = info->base + 0x1234;
    memcpy(p + 0x1000, &target, 4);
    IMAGE_BASE_RELOCATION rel = {0x1000, 12}; memcpy(p + 0x8000, &rel, sizeof(rel));
    uint16_t entries[] = {IMAGE_REL_BASED_HIGHLOW << 12, 0}; memcpy(p + 0x8008, entries, sizeof(entries));
    IMAGE_DATA_DIRECTORY dir = {0x8000, 12};
    NTSTATUS status = ios_wow64_relocate_image(p, v->size, &dir, info->base, info->map_addr);
    if (status) return status;
    set_page_vprot(v->base, v->size, VPROT_READ | VPROT_EXEC | VPROT_COMMITTED);
    assert(!mprotect(v->base, v->size, PROT_READ)); /* real NX backing */
    return populate_error;
}
static void free_pages(struct file_view *v, void *p, size_t s) { (void)v; (void)p; assert(!s); }
static void add_builtin_module(void *p, void *h) { (void)p; (void)h; abort(); }
#include "section_map_api.h"
#include "section_server_api.h"
#define dprintf(...) ((void)0)
#include "wow64_section.h"
static struct pe_mapping_info mapping_info;
static unsigned section_flags = SEC_IMAGE | SEC_FILE;
static int mapping_error;
static NTSTATUS get_mapping_info(HANDLE h, unsigned access, unsigned *flags, mem_size_t *size,
                                 struct pe_mapping_info **out)
{
    assert(h && access); if (mapping_error) return mapping_error;
    *flags = section_flags; *size = mapping_info.image.map_size;
    *out = malloc(sizeof(**out)); assert(*out); **out = mapping_info; return 0;
}
static void free_pe_mapping_info(struct pe_mapping_info *p) { free(p); }
#include "section_route_api.h"
#undef dprintf

static const size_t page_mask = 0xfff;
#define MEM_FREE 0x10000
#define MEM_PRIVATE 0x20000
#define MEM_IMAGE SEC_IMAGE
#define SEC_RESERVE 0x4000000
typedef struct {
    void *BaseAddress, *AllocationBase; ULONG AllocationProtect;
    unsigned short PartitionId; SIZE_T RegionSize; ULONG State, Protect, Type;
} MEMORY_BASIC_INFORMATION;
typedef struct { void *ImageBase; size_t SizeOfImage; unsigned int ImageSigningLevel; } MEMORY_IMAGE_INFORMATION;
#include "wow64_query.h"

static NTSTATUS map_at(void **addr, size_t *size, uintptr_t bits, ULONG type)
{
    NTSTATUS s = -1;
    assert(ios_wow64_route_section((HANDLE)10, NtCurrentProcess(), addr, size, bits, 0,
                                    NULL, ViewUnmap, type, PAGE_READONLY, FALSE, &s));
    return s;
}
static void fail_map(void *at, size_t n, uintptr_t bits, ULONG type, NTSTATUS expected)
{
    void *out = at; size_t size = n;
    assert(map_at(&out, &size, bits, type) == expected && out == at && size == n);
    assert(!server_views && !live_handles); check_cover(bases[0]);
}
static NTSTATUS unmap_at(HANDLE process, void *at, ULONG flags)
{
    NTSTATUS s = -1; assert(ios_wow64_route_unmap(process, at, flags, &s)); return s;
}
int main(void)
{
    struct rlimit core = {0,0}; assert(!setrlimit(RLIMIT_CORE, &core));
    bases[0] = reserve(); bases[1] = reserve();
    int a,b; current_owner = &a;
    ios_wow64_windows[0].owner = &a; ios_wow64_windows[0].base = bases[0];
    ios_wow64_windows[1].owner = &b; ios_wow64_windows[1].base = bases[1];
    mapping_info.image = (struct pe_image_info){0x400000, 0, IMAGE_FILE_MACHINE_I386, 0, 0, 0x11000, 0x1234, 0};
    void *at = NULL; size_t n = 0; NTSTATUS s;
    assert(!ios_wow64_route_section((HANDLE)10, NtCurrentProcess(), &at, &n, 0, 0, NULL,
                                     ViewUnmap, 0, PAGE_READONLY, FALSE, &s));
    assert(!ios_wow64_route_section((HANDLE)10, NtCurrentProcess(), &at, &n, UINT64_C(0x1ffffffff),
                                     0, NULL, ViewUnmap, 0, PAGE_READONLY, FALSE, &s));
    at = (void *)0x400000;
    assert(!ios_wow64_route_section((HANDLE)10, NtCurrentProcess(), &at, &n, 0, 0, NULL,
                                     ViewUnmap, 0, PAGE_READONLY, FALSE, &s));
    assert(!ios_wow64_route_unmap(NtCurrentProcess(), at, 0, &s));
    fail_map((void *)(bases[1]+0x400000), 0, 0, 0, STATUS_ACCESS_DENIED);
    fail_map((void *)(bases[0]+1), 0, 0, 0, STATUS_INVALID_PARAMETER);
    fail_map((void *)bases[0], 0, 0, 0, STATUS_CONFLICTING_ADDRESSES);
    fail_map((void *)(bases[0]+0x7fff0000), 0, 0, 0, STATUS_CONFLICTING_ADDRESSES);
    fail_map(NULL, 1, UINT32_MAX, 0, STATUS_NOT_SUPPORTED);
    fail_map(NULL, 0, 22, 0, STATUS_INVALID_PARAMETER_4);
    fail_map(NULL, 0, 21, 0, STATUS_CONFLICTING_ADDRESSES);
    fail_map(NULL, 0, UINT32_MAX, MEM_RESERVE, STATUS_NOT_SUPPORTED);
    for (unsigned option=0; option<6; ++option)
    {
        at=NULL; n=0; LARGE_INTEGER off={option==2 ? -1 : 0};
        assert(ios_wow64_route_section((HANDLE)10, option==0 ? (HANDLE)4 : NtCurrentProcess(),
                 &at,&n,UINT32_MAX,option==1 ? 1 : 0,&off,option==3 ? ViewShare : ViewUnmap,
                 0,option==4 ? 0xdead : PAGE_READONLY,option==5,&s));
        assert(s==(option==0 ? STATUS_ACCESS_DENIED : option==4 ? STATUS_INVALID_PAGE_PROTECTION : STATUS_NOT_SUPPORTED));
        assert(!at && !n && !server_views && !live_handles);
    }
    section_flags = SEC_COMMIT; fail_map(NULL, 0, UINT32_MAX, 0, STATUS_NOT_SUPPORTED);
    section_flags = SEC_IMAGE | SEC_FILE | 0x10000000; /* SEC_IMAGE_NO_EXECUTE */
    fail_map(NULL,0,UINT32_MAX,0,STATUS_NOT_SUPPORTED);
    section_flags = SEC_IMAGE | SEC_FILE;
    mapping_info.image.machine = 0xaa64; fail_map(NULL, 0, UINT32_MAX, 0, STATUS_NOT_SUPPORTED); mapping_info.image.machine = IMAGE_FILE_MACHINE_I386;
    mapping_info.image.is_hybrid=1; fail_map(NULL,0,UINT32_MAX,0,STATUS_NOT_SUPPORTED); mapping_info.image.is_hybrid=0;
    mapping_info.image.image_flags=0x10; fail_map(NULL,0,UINT32_MAX,0,STATUS_NOT_SUPPORTED); mapping_info.image.image_flags=0;
    fd_error = STATUS_ACCESS_DENIED; fail_map(NULL,0,UINT32_MAX,0,fd_error); fd_error=0;
    fail_after = 0; fail_map(NULL,0,UINT32_MAX,0,STATUS_NO_MEMORY); fail_after = -1;
    fail_protect=1; fail_map(NULL,0,UINT32_MAX,0,STATUS_ACCESS_DENIED); fail_protect=0;
    dup_error=STATUS_ACCESS_DENIED; fail_map(NULL,0,UINT32_MAX,0,dup_error); dup_error=0;
    populate_error=STATUS_INVALID_IMAGE_FORMAT; fail_map(NULL,0,UINT32_MAX,0,populate_error); populate_error=0;
    map_error=STATUS_ACCESS_DENIED; fail_map(NULL,0,UINT32_MAX,0,map_error); map_error=0;
    populate_error=STATUS_INVALID_IMAGE_FORMAT; fail_replace=1;
    at=NULL;n=0; assert(map_at(&at,&n,UINT32_MAX,0)==populate_error && !at && !n);
    struct file_view *failed=find_view((void *)(bases[0]+0x400000),1);
    assert(failed->protect&VPROT_WOW64_IMAGE);
    assert(failed->wow64_mapping && !failed->wow64_registered && !server_views && live_handles==1);
    populate_error=0; fail_replace=0;
    /* Explicit test cleanup of a failed unpublished view; production defers
     * this to owner exit, which closes its retained handle via free_view. */
    assert(!ios_wow64_rollback_image(failed)); NtClose(failed->wow64_mapping); failed->wow64_mapping=0;
    ios_wow64_vm_coalesce(bases[0],failed); check_cover(bases[0]);
    /* Collision forces guest relocation; native storage must never add B. */
    void *collision=(void *)(bases[0]+0x400000); size_t cn=0x20000;
    assert(!routed(0,&collision,&cn,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE,NULL));
    at=NULL; n=0; assert(!map_at(&at,&n,UINT32_MAX,0));
    assert(at==(void *)(bases[0]+0x10000) && n==0x11000 && server_base==(uintptr_t)at && server_size==n);
    assert(find_view(at,1)->size==0x14000); /* holdback owns native-page padding */
    assert(server_entry==0x1234); /* server metadata retains PE entry RVA, not host entry */
    MEMORY_BASIC_INFORMATION basic;
    assert(!ios_wow64_query_basic(bases[0],at,&basic));
    assert(basic.AllocationBase==at && basic.Type==MEM_IMAGE && basic.State==MEM_COMMIT &&
           basic.Protect==PAGE_EXECUTE_READ);
    MEMORY_IMAGE_INFORMATION qi;
    assert(!ios_wow64_query_image(bases[0],at,&qi));
    assert(qi.ImageBase==at && qi.SizeOfImage==n && !qi.ImageSigningLevel);
    assert(ios_wow64_query_image(bases[0],(char *)at+0x13000,&qi)==STATUS_INVALID_ADDRESS);
    assert(qi.SizeOfImage==0x11000); /* failure output unchanged; padding is not image identity */
    uint32_t target; memcpy(&target,(char *)at+0x1000,4); assert(target==0x11234);
    assert(get_page_vprot(at)&VPROT_EXEC); inaccessible(at,1); inaccessible(at,0);
    assert(unmap_at(NtCurrentProcess(),at,MEM_RELEASE)==STATUS_NOT_SUPPORTED);
    assert(unmap_at((HANDLE)4,at,0)==STATUS_ACCESS_DENIED);
    current_owner=&b; assert(unmap_at(NtCurrentProcess(),at,0)==STATUS_ACCESS_DENIED); current_owner=&a;
    unmap_error=STATUS_ACCESS_DENIED; assert(unmap_at(NtCurrentProcess(),at,0)==unmap_error); unmap_error=0;
    memcpy(&target,(char *)at+0x1000,4); assert(target==0x11234 && server_views && live_handles);
    fail_replace=1; assert(unmap_at(NtCurrentProcess(),(char *)at+7,0)==STATUS_NO_MEMORY); fail_replace=0;
    memcpy(&target,(char *)at+0x1000,4); assert(target==0x11234 && server_views && live_handles);
    /* If replacement AND re-registration fail, refuse reuse/unmap until exit,
     * retaining the mapped bytes and descriptor rather than unmapping B. */
    fail_replace=1; map_error=STATUS_ACCESS_DENIED;
    assert(unmap_at(NtCurrentProcess(),at,0)==STATUS_NO_MEMORY);
    fail_replace=0; map_error=0;
    struct file_view *quarantined=find_view(at,1);
    assert(!quarantined->wow64_registered && quarantined->wow64_mapping && !server_views);
    assert(unmap_at(NtCurrentProcess(),at,0)==STATUS_NOT_MAPPED_VIEW);
    memcpy(&target,(char *)at+0x1000,4); assert(target==0x11234);
    /* Test-only recovery to continue exercising release/coalescing. Production
     * keeps such a double-failed view quarantined until owner teardown. */
    assert(!ios_wow64_server_map(quarantined)); quarantined->wow64_registered=TRUE;
    assert(!unmap_at(NtCurrentProcess(),(char *)at+7,0)); assert(!server_views && !live_handles);
    assert(ios_wow64_query_image(bases[0],at,&qi)==STATUS_INVALID_ADDRESS);
    assert(!ios_wow64_query_basic(bases[0],at,&basic) && basic.State==MEM_FREE);
    inaccessible(at,0); assert(unmap_at(NtCurrentProcess(),at,0)==STATUS_NOT_MAPPED_VIEW);
    assert(!routed(1,&collision,&(size_t){0},MEM_RELEASE,0,NULL));
    assert(find_view((void *)bases[0],1)->size==IOS_WOW64_WINDOW_SIZE); check_cover(bases[0]);
    /* Explicit relocation, stripped rejection, top-down and independent owner. */
    at=(void *)(bases[0]+0x600000); n=0; assert(!map_at(&at,&n,UINT32_MAX,0));
    memcpy(&target,(char *)at+0x1000,4); assert(target==0x601234); assert(!unmap_at(NtCurrentProcess(),at,0));
    mapping_info.image.image_charact=IMAGE_FILE_RELOCS_STRIPPED;
    fail_map((void *)(bases[0]+0x600000),0,0,0,STATUS_CONFLICTING_ADDRESSES); mapping_info.image.image_charact=0;
    collision=(void *)(bases[0]+0x400000); cn=0x20000; assert(!routed(0,&collision,&cn,MEM_RESERVE, PAGE_READWRITE,NULL));
    at=NULL;n=0; assert(!map_at(&at,&n,UINT32_MAX,MEM_TOP_DOWN)); assert((uintptr_t)at-bases[0]==0x7ffe0000);
    assert(!unmap_at(NtCurrentProcess(),at,0)); assert(!routed(1,&collision,&(size_t){0},MEM_RELEASE,0,NULL));
    /* 4 GiB-capable owners/images still obey the rounded final page edge. */
    image.ImageCharacteristics=IMAGE_FILE_LARGE_ADDRESS_AWARE;
    mapping_info.image.image_charact=IMAGE_FILE_LARGE_ADDRESS_AWARE;
    at=(void *)(bases[0]+UINT64_C(0xffff0000)); n=0;
    fail_map(at,n,UINT32_MAX,0,STATUS_CONFLICTING_ADDRESSES);
    at=(void *)(bases[0]+UINT64_C(0xfffe0000)); assert(!map_at(&at,&n,UINT32_MAX,0));
    assert(!unmap_at(NtCurrentProcess(),at,0));
    image.ImageCharacteristics=0; mapping_info.image.image_charact=0;
    current_owner=&b; at=NULL;n=0; assert(!map_at(&at,&n,UINT32_MAX,0)); assert(at==(void *)(bases[1]+0x400000));
    assert(!unmap_at(NtCurrentProcess(),at,0)); current_owner=&a;
    struct file_view *bootstrap; assert(!ios_wow64_claim_view(bases[0],0x7ff00000,0x4000,VPROT_READ|VPROT_WRITE|VPROT_COMMITTED,&bootstrap));
    assert(unmap_at(NtCurrentProcess(),bootstrap->base,0)==STATUS_NOT_MAPPED_VIEW);
    assert(mapper_calls>=6); ios_wow64_delete_views(bases[0]); ios_wow64_delete_views(bases[1]);
    puts("wow64 section: production router/map/unmap transaction and guest relocation passed (mock PE population/server)");
    return 0;
}
