/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The capture layer's linear-image use, with PP_CAPTURE_LINEAR=1: for every
 * VK_IMAGE_TILING_LINEAR image, where it is bound (memory, offset, size, the
 * memory's type, other images and buffers bound over the same range), whether
 * the application maps that range, its vkGetImageSubresourceLayout calls,
 * flushes and invalidations, the copies, blits, resolves, clears and barriers
 * naming it, and the descriptor writes and framebuffers naming its views.
 * Included by capture.c.
 *
 *    PP_CAPTURE_LINEAR_HASH=N   every N presents, hash a sample of the mapped
 *                               bytes (16 runs of 64 bytes) of each linear image
 *                               Metal cannot make from a buffer (3D, array or
 *                               mipmapped), and count the changes no GPU write
 *                               to it, submitted in that interval or the one
 *                               before, explains
 *    PP_CAPTURE_LINEAR_DUMP=N   a summary of the live images every N presents
 *                               (default 3000; 0 for none)
 *
 * Lines: "linimg H create|bind", "linmap" (the first 20,000 maps), "linlayout
 * H" (an image's first 4 layout queries), and one "linuse H WHY" summary per
 * image at vkDestroyImage (WHY destroy), for the live ones at vkDestroyDevice
 * (device), every PP_CAPTURE_LINEAR_DUMP presents (snapN) and at exit (exit;
 * a Wine process ends without it). An image's group is the first that
 * applies: 3d, attachment (colour), array, mips, plain. Its "layouts" is a
 * mask of 1 << VkImageLayout over its barriers (bit 31 for any other layout).
 */

static int lin_on = -1;
static int lin_enabled(void) { if (lin_on < 0) lin_on = getenv("PP_CAPTURE_LINEAR") != NULL; return lin_on; }
static pthread_mutex_t lin_mu = PTHREAD_MUTEX_INITIALIZER;

// A chained hash map of 64-bit handles.
typedef struct HNode { uint64_t k; void *v; struct HNode *next; } HNode;
typedef struct { HNode **b; } HMap;
#define HMAP_BITS 16
static HNode **hm_slot(HMap *m, uint64_t k) {
    if (!m->b) m->b = calloc(1u << HMAP_BITS, sizeof *m->b);
    HNode **s = &m->b[(k * 0x9E3779B97F4A7C15ull) >> (64 - HMAP_BITS)];
    while (*s && (*s)->k != k) s = &(*s)->next;
    return s;
}
static void *hm_get(HMap *m, uint64_t k) { HNode *n = *hm_slot(m, k); return n ? n->v : NULL; }
static void hm_put(HMap *m, uint64_t k, void *v) {
    HNode **s = hm_slot(m, k);
    if (*s) { (*s)->v = v; return; }
    HNode *n = malloc(sizeof *n); n->k = k; n->v = v; n->next = NULL; *s = n;
}
static void *hm_del(HMap *m, uint64_t k) {
    HNode **s = hm_slot(m, k), *n = *s;
    if (!n) return NULL;
    void *v = n->v; *s = n->next; free(n);
    return v;
}
#define HM_EACH(m, node) \
    for (uint32_t i_ = 0; (m).b && i_ < (1u << HMAP_BITS); i_++) \
        for (HNode *node = (m).b[i_]; node; node = node->next)

typedef struct LinMem LinMem;
// An image or buffer bound into a memory object, in one of its two lists; buffers' keys have bit 63 set.
typedef struct LinObj { uint64_t key; VkDeviceSize off, size; struct LinObj **list, *prev, *next; } LinObj;
struct LinMem {
    uint64_t h; uint32_t type, desk_type; VkDeviceSize size; // the application's memory type, the desktop one behind it
    const unsigned char *ptr; VkDeviceSize map_off, map_size; // the application's mapping, ptr NULL when unmapped
    LinObj *lin, *other; // the linear images bound into it, and every other object
};
typedef struct {
    uint64_t h; VkDevice dev; long seq; const char *grp;
    VkImageCreateInfo ci;
    uint64_t mem; VkDeviceSize off, size; long binds;
    int memtype, desktype; VkDeviceSize memsize; // of the memory it was last bound into
    long alias, mapped_at_bind, maps, layouts, flushes, invals;
    long b2i, i2b, ci_src, ci_dst, blit_src, blit_dst, res_src, res_dst, clears;
    long d_combined, d_sampled, d_storage, d_input, views, fb, rp, bars;
    long host_w, host_r; // barriers naming it after host writes (source HOST), before host reads (destination HOST)
    uint32_t layout_mask;
    long hashes, chg, chg_unexpl, subw, gpu_epoch; uint64_t hash;
} LinImg;
typedef struct { int n, cap; uint64_t *img; } LinList; // a command buffer's written images, a framebuffer's attachments
typedef struct { uint32_t n; VkDescriptorUpdateTemplateEntry e[]; } LinTemplate;

static HMap lin_imgs, lin_views, lin_mems, lin_bound, lin_fbs, lin_cbs, lin_tpls;
static long lin_seq, lin_presents, lin_epoch, lin_maplines, lin_host_mem_barriers;
static long lin_dw_images, lin_dw_linear, lin_copy_images; // every image descriptor written, those naming a linear image; every vkCmdCopyImage
static long lin_hash_every = -1, lin_dump_every = -1;

static const char *lin_group(const VkImageCreateInfo *ci) {
    if (ci->imageType == VK_IMAGE_TYPE_3D) return "3d";
    if (ci->usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) return "attachment";
    if (ci->arrayLayers > 1) return "array";
    if (ci->mipLevels > 1) return "mips";
    return "plain";
}
static int lin_overlap(VkDeviceSize a, VkDeviceSize as, VkDeviceSize b, VkDeviceSize bs) { return a < b + bs && b < a + as; }
static void lin_list_add(LinList *l, uint64_t h) {
    for (int i = l->n - 1; i >= 0 && i >= l->n - 8; i--) if (l->img[i] == h) return;
    if (l->n >= 4096) return;
    if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 8; l->img = realloc(l->img, l->cap * sizeof *l->img); }
    l->img[l->n++] = h;
}

static void lin_summary(const LinImg *g, const char *why) {
    const VkImageCreateInfo *c = &g->ci;
    L("linuse %llx %s grp=%s fmt=%s %ux%ux%u mips=%u layers=%u usage=%x flags=%x init=%d seq=%ld binds=%ld mem=%llx memtype=%d desktype=%d memsize=%llu off=%llu size=%llu"
      " alias=%ld mapped_at_bind=%ld maps=%ld layout=%ld flush=%ld inval=%ld b2i=%ld i2b=%ld ci_src=%ld ci_dst=%ld blit_src=%ld blit_dst=%ld res_src=%ld res_dst=%ld clear=%ld"
      " d_combined=%ld d_sampled=%ld d_storage=%ld d_input=%ld views=%ld fb=%ld rp=%ld bars=%ld host_w=%ld host_r=%ld layouts=%x subw=%ld hashes=%ld chg=%ld chg_unexpl=%ld\n",
      (unsigned long long)g->h, why, g->grp, string_VkFormat(c->format), c->extent.width, c->extent.height, c->extent.depth, c->mipLevels, c->arrayLayers,
      c->usage, c->flags, c->initialLayout, g->seq, g->binds, (unsigned long long)g->mem, g->memtype, g->desktype,
      (unsigned long long)g->memsize, (unsigned long long)g->off, (unsigned long long)g->size,
      g->alias, g->mapped_at_bind, g->maps, g->layouts, g->flushes, g->invals, g->b2i, g->i2b, g->ci_src, g->ci_dst, g->blit_src, g->blit_dst,
      g->res_src, g->res_dst, g->clears, g->d_combined, g->d_sampled, g->d_storage, g->d_input, g->views, g->fb, g->rp, g->bars, g->host_w, g->host_r,
      g->layout_mask, g->subw, g->hashes, g->chg, g->chg_unexpl);
}
// A copy of the live images (of one device, or all), taken under lin_mu and printed after it.
typedef struct { LinImg *g; long n; char stats[256]; } LinDump;
static LinDump lin_dump_take(VkDevice dev) {
    LinDump d = {NULL, 0, ""};
    long cap = 0;
    HM_EACH(lin_imgs, node) {
        LinImg *g = node->v;
        if (dev && g->dev != dev) continue;
        if (d.n == cap) { cap = cap ? cap * 2 : 1024; d.g = realloc(d.g, cap * sizeof *d.g); }
        d.g[d.n++] = *g;
    }
    snprintf(d.stats, sizeof d.stats, "presents=%ld epoch=%ld host_mem_barriers=%ld image_descriptors=%ld linear_descriptors=%ld copy_image=%ld",
             lin_presents, lin_epoch, lin_host_mem_barriers, lin_dw_images, lin_dw_linear, lin_copy_images);
    return d;
}
static void lin_dump_print(LinDump *d, const char *why) {
    for (long i = 0; i < d->n; i++) lin_summary(&d->g[i], why);
    L("linstats %s %s\n", why, d->stats);
    free(d->g);
}
static void __attribute__((destructor)) lin_at_exit(void) {
    if (lin_on != 1) return;
    pthread_mutex_lock(&lin_mu); LinDump d = lin_dump_take(NULL); pthread_mutex_unlock(&lin_mu);
    lin_dump_print(&d, "exit");
}

/* creation, binding, mapping */
static void lin_image_created(VkDevice d, const VkImageCreateInfo *ci, VkImage img) {
    if (!lin_enabled() || ci->tiling != VK_IMAGE_TILING_LINEAR) return;
    LinImg *g = calloc(1, sizeof *g);
    g->h = (uint64_t)(uintptr_t)img; g->dev = d; g->ci = *ci; g->ci.pNext = NULL; g->ci.pQueueFamilyIndices = NULL; g->grp = lin_group(ci);
    g->gpu_epoch = -100;
    pthread_mutex_lock(&lin_mu);
    g->seq = lin_seq++;
    hm_put(&lin_imgs, g->h, g);
    pthread_mutex_unlock(&lin_mu);
    L("linimg %llx create grp=%s fmt=%s %ux%ux%u mips=%u layers=%u usage=%x init=%d seq=%ld\n", (unsigned long long)g->h, g->grp, string_VkFormat(ci->format),
      ci->extent.width, ci->extent.height, ci->extent.depth, ci->mipLevels, ci->arrayLayers, ci->usage, ci->initialLayout, g->seq);
}

static void lin_mem_allocated(const VkMemoryAllocateInfo *ai, uint32_t desk_type, VkDeviceMemory mem) {
    if (!lin_enabled()) return;
    LinMem *m = calloc(1, sizeof *m);
    m->h = (uint64_t)(uintptr_t)mem; m->type = ai->memoryTypeIndex; m->desk_type = desk_type; m->size = ai->allocationSize;
    pthread_mutex_lock(&lin_mu); hm_put(&lin_mems, m->h, m); pthread_mutex_unlock(&lin_mu);
}

static void lin_list_link(LinObj **list, LinObj *o) { o->list = list; o->prev = NULL; o->next = *list; if (*list) (*list)->prev = o; *list = o; }
static void lin_list_unlink(LinObj *o) {
    if (o->prev) o->prev->next = o->next; else *o->list = o->next;
    if (o->next) o->next->prev = o->prev;
}
// Unlinks an object from its memory (under lin_mu).
static void lin_unbind(uint64_t key) {
    LinObj *o = hm_del(&lin_bound, key);
    if (o) { lin_list_unlink(o); free(o); }
}
static void lin_alias(LinObj *list, VkDeviceSize off, VkDeviceSize size, LinImg *g, int linear_list) {
    for (LinObj *o = list; o; o = o->next) {
        if (!lin_overlap(off, size, o->off, o->size)) continue;
        if (g) g->alias++;
        if (linear_list) { LinImg *og = hm_get(&lin_imgs, o->key); if (og) og->alias++; }
    }
}
// Records a bind (under lin_mu) and counts the overlaps with linear images in the same memory.
static void lin_bind(uint64_t key, uint64_t memh, VkDeviceSize off, VkDeviceSize size, LinImg *g) {
    LinMem *m = hm_get(&lin_mems, memh);
    if (!m) return;
    lin_unbind(key);
    lin_alias(m->lin, off, size, g, 1);
    if (g) lin_alias(m->other, off, size, g, 0);
    LinObj *o = calloc(1, sizeof *o);
    o->key = key; o->off = off; o->size = size;
    lin_list_link(g ? &m->lin : &m->other, o);
    hm_put(&lin_bound, key, o);
    if (g) {
        g->mem = memh; g->off = off; g->size = size; g->binds++;
        g->memtype = (int)m->type; g->desktype = (int)m->desk_type; g->memsize = m->size;
        if (m->ptr && lin_overlap(off, size, m->map_off, m->map_size)) { g->mapped_at_bind++; g->maps++; }
    }
}

static void lin_image_bound(VkDevice d, VkImage img, VkDeviceMemory mem, VkDeviceSize off) {
    if (!lin_enabled()) return;
    VkMemoryRequirements req = {0};
    p_ImgReq(d, img, &req);
    pthread_mutex_lock(&lin_mu);
    LinImg *g = hm_get(&lin_imgs, (uint64_t)(uintptr_t)img), copy;
    lin_bind((uint64_t)(uintptr_t)img, (uint64_t)(uintptr_t)mem, off, req.size, g);
    if (g) copy = *g;
    pthread_mutex_unlock(&lin_mu);
    if (g) L("linimg %llx bind mem=%llx memtype=%d desktype=%d memsize=%llu off=%llu size=%llu mapped=%ld alias=%ld\n", (unsigned long long)copy.h,
             (unsigned long long)(uintptr_t)mem, copy.memtype, copy.desktype, (unsigned long long)copy.memsize,
             (unsigned long long)off, (unsigned long long)req.size, copy.mapped_at_bind, copy.alias);
}

static void lin_buffer_bound(VkDevice d, VkBuffer b, VkDeviceMemory mem, VkDeviceSize off) {
    if (!lin_enabled()) return;
    VkMemoryRequirements req = {0};
    p_BufReq(d, b, &req);
    pthread_mutex_lock(&lin_mu);
    lin_bind((uint64_t)(uintptr_t)b | 1ull << 63, (uint64_t)(uintptr_t)mem, off, req.size, NULL);
    pthread_mutex_unlock(&lin_mu);
}

static void lin_image_destroyed(VkImage img) {
    if (!lin_enabled() || !img) return;
    pthread_mutex_lock(&lin_mu);
    uint64_t k = (uint64_t)(uintptr_t)img;
    LinImg *g = hm_del(&lin_imgs, k);
    lin_unbind(k);
    pthread_mutex_unlock(&lin_mu);
    if (g) { lin_summary(g, "destroy"); free(g); }
}

static void lin_buffer_destroyed(VkBuffer b) {
    if (!lin_enabled() || !b) return;
    pthread_mutex_lock(&lin_mu); lin_unbind((uint64_t)(uintptr_t)b | 1ull << 63); pthread_mutex_unlock(&lin_mu);
}

static void lin_mem_freed(VkDeviceMemory mem) {
    if (!lin_enabled() || !mem) return;
    pthread_mutex_lock(&lin_mu);
    LinMem *m = hm_del(&lin_mems, (uint64_t)(uintptr_t)mem);
    if (m) {
        for (int linear = 0; linear < 2; linear++)
            for (LinObj *o = linear ? m->lin : m->other, *next; o; o = next) {
                next = o->next;
                hm_del(&lin_bound, o->key);
                LinImg *g = linear ? hm_get(&lin_imgs, o->key) : NULL;
                if (g) g->mem = 0;
                free(o);
            }
        free(m);
    }
    pthread_mutex_unlock(&lin_mu);
}

static void lin_mapped(VkDeviceMemory mem, VkDeviceSize off, VkDeviceSize size, void *ptr) {
    if (!lin_enabled() || !ptr) return;
    pthread_mutex_lock(&lin_mu);
    LinMem *m = hm_get(&lin_mems, (uint64_t)(uintptr_t)mem);
    int nlin = 0, nobj = 0, type = -1;
    VkDeviceSize memsize = 0, map_size = size;
    if (m) {
        m->ptr = ptr; m->map_off = off; m->map_size = map_size = size == VK_WHOLE_SIZE ? m->size - off : size;
        type = (int)m->type; memsize = m->size;
        for (LinObj *o = m->other; o; o = o->next) nobj++;
        for (LinObj *o = m->lin; o; o = o->next) {
            nobj++;
            if (!lin_overlap(o->off, o->size, m->map_off, m->map_size)) continue;
            LinImg *g = hm_get(&lin_imgs, o->key);
            if (g) { g->maps++; nlin++; }
        }
    }
    long line = lin_maplines++;
    pthread_mutex_unlock(&lin_mu);
    if (line < 20000)
        L("linmap mem=%llx memtype=%d memsize=%llu off=%llu size=%llu objects=%d linear_overlapping=%d\n", (unsigned long long)(uintptr_t)mem,
          type, (unsigned long long)memsize, (unsigned long long)off, (unsigned long long)map_size, nobj, nlin);
}

static void lin_unmapped(VkDeviceMemory mem) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinMem *m = hm_get(&lin_mems, (uint64_t)(uintptr_t)mem);
    if (m) m->ptr = NULL;
    pthread_mutex_unlock(&lin_mu);
}

// Flushes and invalidations of ranges that overlap linear images.
static void lin_ranges(uint32_t n, const VkMappedMemoryRange *r, int inval) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    for (uint32_t k = 0; k < n; k++) {
        LinMem *m = hm_get(&lin_mems, (uint64_t)(uintptr_t)r[k].memory);
        if (!m) continue;
        VkDeviceSize size = r[k].size == VK_WHOLE_SIZE ? m->size - r[k].offset : r[k].size;
        for (LinObj *o = m->lin; o; o = o->next) {
            if (!lin_overlap(o->off, o->size, r[k].offset, size)) continue;
            LinImg *g = hm_get(&lin_imgs, o->key);
            if (g) { if (inval) g->invals++; else g->flushes++; }
        }
    }
    pthread_mutex_unlock(&lin_mu);
}

static void lin_layout_queried(VkImage img, const VkImageSubresource *s, const VkSubresourceLayout *l) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinImg *g = hm_get(&lin_imgs, (uint64_t)(uintptr_t)img);
    long n = g ? g->layouts++ : -1;
    pthread_mutex_unlock(&lin_mu);
    if (n >= 0 && n < 4)
        L("linlayout %llx aspect=%x mip=%u layer=%u -> off=%llu size=%llu row=%llu array=%llu depth=%llu\n", (unsigned long long)(uintptr_t)img,
          s->aspectMask, s->mipLevel, s->arrayLayer, (unsigned long long)l->offset, (unsigned long long)l->size, (unsigned long long)l->rowPitch,
          (unsigned long long)l->arrayPitch, (unsigned long long)l->depthPitch);
}

/* views, descriptors, framebuffers */
static void lin_view_created(const VkImageViewCreateInfo *ci, VkImageView v) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinImg *g = hm_get(&lin_imgs, (uint64_t)(uintptr_t)ci->image);
    if (g) { g->views++; hm_put(&lin_views, (uint64_t)(uintptr_t)v, (void *)(uintptr_t)ci->image); }
    pthread_mutex_unlock(&lin_mu);
}
static void lin_view_destroyed(VkImageView v) {
    if (!lin_enabled() || !v) return;
    pthread_mutex_lock(&lin_mu); hm_del(&lin_views, (uint64_t)(uintptr_t)v); pthread_mutex_unlock(&lin_mu);
}
static LinImg *lin_of_view(VkImageView v) {
    uint64_t img = v ? (uint64_t)(uintptr_t)hm_get(&lin_views, (uint64_t)(uintptr_t)v) : 0;
    return img ? hm_get(&lin_imgs, img) : NULL;
}
// One image descriptor naming view v (under lin_mu).
static void lin_descriptor(VkDescriptorType t, VkImageView v) {
    lin_dw_images++;
    LinImg *g = lin_of_view(v);
    if (!g) return;
    lin_dw_linear++;
    switch (t) {
    case VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: g->d_combined++; break;
    case VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE: g->d_sampled++; break;
    case VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: g->d_storage++; break;
    case VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT: g->d_input++; break;
    default: break;
    }
}
static int lin_image_descriptor(VkDescriptorType t) {
    return t == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER || t == VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE ||
           t == VK_DESCRIPTOR_TYPE_STORAGE_IMAGE || t == VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT;
}
static void lin_descriptor_writes(uint32_t n, const VkWriteDescriptorSet *w) {
    if (!lin_enabled() || !n) return;
    pthread_mutex_lock(&lin_mu);
    for (uint32_t k = 0; k < n; k++)
            if (lin_image_descriptor(w[k].descriptorType) && w[k].pImageInfo)
                for (uint32_t i = 0; i < w[k].descriptorCount; i++) lin_descriptor(w[k].descriptorType, w[k].pImageInfo[i].imageView);
    pthread_mutex_unlock(&lin_mu);
}
static void lin_template_created(const VkDescriptorUpdateTemplateCreateInfo *ci, VkDescriptorUpdateTemplate t) {
    if (!lin_enabled() || ci->templateType != VK_DESCRIPTOR_UPDATE_TEMPLATE_TYPE_DESCRIPTOR_SET) return;
    LinTemplate *lt = malloc(sizeof *lt + ci->descriptorUpdateEntryCount * sizeof lt->e[0]);
    lt->n = ci->descriptorUpdateEntryCount;
    memcpy(lt->e, ci->pDescriptorUpdateEntries, lt->n * sizeof lt->e[0]);
    pthread_mutex_lock(&lin_mu); free(hm_del(&lin_tpls, (uint64_t)(uintptr_t)t)); hm_put(&lin_tpls, (uint64_t)(uintptr_t)t, lt); pthread_mutex_unlock(&lin_mu);
}
static void lin_template_destroyed(VkDescriptorUpdateTemplate t) {
    if (!lin_enabled() || !t) return;
    pthread_mutex_lock(&lin_mu); free(hm_del(&lin_tpls, (uint64_t)(uintptr_t)t)); pthread_mutex_unlock(&lin_mu);
}
static void lin_template_write(VkDescriptorUpdateTemplate t, const void *data) {
    if (!lin_enabled() || !data) return;
    pthread_mutex_lock(&lin_mu);
    LinTemplate *lt = hm_get(&lin_tpls, (uint64_t)(uintptr_t)t);
    for (uint32_t k = 0; lt && k < lt->n; k++) {
        const VkDescriptorUpdateTemplateEntry *e = &lt->e[k];
        if (!lin_image_descriptor(e->descriptorType)) continue;
        for (uint32_t i = 0; i < e->descriptorCount; i++)
            lin_descriptor(e->descriptorType, ((const VkDescriptorImageInfo *)((const char *)data + e->offset + i * e->stride))->imageView);
    }
    pthread_mutex_unlock(&lin_mu);
}
static void lin_framebuffer_created(const VkFramebufferCreateInfo *ci, VkFramebuffer fb) {
    if (!lin_enabled() || (ci->flags & VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT)) return;
    pthread_mutex_lock(&lin_mu);
    LinList *l = NULL;
    for (uint32_t i = 0; i < ci->attachmentCount; i++) {
        LinImg *g = lin_of_view(ci->pAttachments[i]);
        if (!g) continue;
        g->fb++;
        if (!l) l = calloc(1, sizeof *l);
        lin_list_add(l, g->h);
    }
    if (l) hm_put(&lin_fbs, (uint64_t)(uintptr_t)fb, l);
    pthread_mutex_unlock(&lin_mu);
}
static void lin_framebuffer_destroyed(VkFramebuffer fb) {
    if (!lin_enabled() || !fb) return;
    pthread_mutex_lock(&lin_mu);
    LinList *l = hm_del(&lin_fbs, (uint64_t)(uintptr_t)fb);
    if (l) { free(l->img); free(l); }
    pthread_mutex_unlock(&lin_mu);
}

/* commands: counts at recording, GPU writes marked at submission */
static LinList *lin_cb(VkCommandBuffer c) {
    LinList *l = hm_get(&lin_cbs, (uint64_t)(uintptr_t)c);
    if (!l) { l = calloc(1, sizeof *l); hm_put(&lin_cbs, (uint64_t)(uintptr_t)c, l); }
    return l;
}
static void lin_cb_begin(VkCommandBuffer c) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinList *l = hm_get(&lin_cbs, (uint64_t)(uintptr_t)c);
    if (l) l->n = 0;
    pthread_mutex_unlock(&lin_mu);
}
// An image a command reads (write 0) or writes (write 1); returns it when linear (under lin_mu).
static LinImg *lin_cmd_image(VkCommandBuffer c, VkImage img, int write) {
    LinImg *g = img ? hm_get(&lin_imgs, (uint64_t)(uintptr_t)img) : NULL;
    if (g && write) lin_list_add(lin_cb(c), g->h);
    return g;
}
#define LIN_CMD(c, img, write, field) do { if (lin_enabled()) { pthread_mutex_lock(&lin_mu); \
    LinImg *g_ = lin_cmd_image(c, img, write); if (g_) g_->field++; pthread_mutex_unlock(&lin_mu); } } while (0)
static void lin_render_pass(VkCommandBuffer c, const VkRenderPassBeginInfo *b) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinList *l = lin_fbs.b ? hm_get(&lin_fbs, (uint64_t)(uintptr_t)b->framebuffer) : NULL;
    for (int i = 0; l && i < l->n; i++) { LinImg *g = lin_cmd_image(c, (VkImage)(uintptr_t)l->img[i], 1); if (g) g->rp++; }
    for (const Hdr *h = b->pNext; h; h = h->pNext) {
        if (h->sType != VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO) continue;
        const VkRenderPassAttachmentBeginInfo *a = (const void *)h;
        for (uint32_t i = 0; i < a->attachmentCount; i++) {
            LinImg *g = lin_of_view(a->pAttachments[i]);
            if (g) { g->rp++; lin_list_add(lin_cb(c), g->h); }
        }
    }
    pthread_mutex_unlock(&lin_mu);
}
static void lin_barriers(VkPipelineStageFlags src, VkPipelineStageFlags dst, uint32_t nm, const VkMemoryBarrier *mb, uint32_t n, const VkImageMemoryBarrier *b) {
    if (!lin_enabled()) return;
    int src_host = (src & VK_PIPELINE_STAGE_HOST_BIT) != 0, dst_host = (dst & VK_PIPELINE_STAGE_HOST_BIT) != 0;
    pthread_mutex_lock(&lin_mu);
    for (uint32_t k = 0; k < nm; k++)
        if (src_host || dst_host || ((mb[k].srcAccessMask | mb[k].dstAccessMask) & (VK_ACCESS_HOST_READ_BIT | VK_ACCESS_HOST_WRITE_BIT))) lin_host_mem_barriers++;
    for (uint32_t k = 0; k < n; k++) {
        LinImg *g = hm_get(&lin_imgs, (uint64_t)(uintptr_t)b[k].image);
        if (!g) continue;
        g->bars++;
        if (src_host || (b[k].srcAccessMask & VK_ACCESS_HOST_WRITE_BIT)) g->host_w++;
        if (dst_host || (b[k].dstAccessMask & VK_ACCESS_HOST_READ_BIT)) g->host_r++;
        g->layout_mask |= 1u << (b[k].oldLayout < 31 ? b[k].oldLayout : 31) | 1u << (b[k].newLayout < 31 ? b[k].newLayout : 31);
    }
    pthread_mutex_unlock(&lin_mu);
}
static void lin_execute(VkCommandBuffer primary, uint32_t n, const VkCommandBuffer *sec) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    for (uint32_t k = 0; k < n; k++) {
        LinList *s = hm_get(&lin_cbs, (uint64_t)(uintptr_t)sec[k]);
        for (int i = 0; s && i < s->n; i++) lin_list_add(lin_cb(primary), s->img[i]);
    }
    pthread_mutex_unlock(&lin_mu);
}
static void lin_submit(uint32_t n, const VkSubmitInfo *s) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    for (uint32_t k = 0; lin_cbs.b && k < n; k++)
        for (uint32_t c = 0; c < s[k].commandBufferCount; c++) {
            LinList *l = hm_get(&lin_cbs, (uint64_t)(uintptr_t)s[k].pCommandBuffers[c]);
            for (int i = 0; l && i < l->n; i++) {
                LinImg *g = hm_get(&lin_imgs, l->img[i]);
                if (g) { g->subw++; g->gpu_epoch = lin_epoch; }
            }
        }
    pthread_mutex_unlock(&lin_mu);
}

/* presents: content samples and snapshots */
static uint64_t lin_sample_hash(const unsigned char *p, VkDeviceSize n) {
    uint64_t h = 1469598103934665603ull;
    if (n <= 1024) { for (VkDeviceSize i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
    VkDeviceSize step = (n - 64) / 15;
    for (int r = 0; r < 16; r++)
        for (int i = 0; i < 64; i++) { h ^= p[r * step + i]; h *= 1099511628211ull; }
    return h;
}
static void lin_present(void) {
    if (!lin_enabled()) return;
    if (lin_hash_every < 0) { const char *e = getenv("PP_CAPTURE_LINEAR_HASH"); lin_hash_every = e ? atol(e) : 0; }
    if (lin_dump_every < 0) { const char *e = getenv("PP_CAPTURE_LINEAR_DUMP"); lin_dump_every = e ? atol(e) : 3000; }
    pthread_mutex_lock(&lin_mu);
    lin_presents++;
    if (lin_hash_every > 0 && lin_presents % lin_hash_every == 0) {
        HM_EACH(lin_imgs, node) {
            LinImg *g = node->v;
            if (g->ci.imageType != VK_IMAGE_TYPE_3D && g->ci.arrayLayers == 1 && g->ci.mipLevels == 1) continue;
            LinMem *m = g->mem ? hm_get(&lin_mems, g->mem) : NULL;
            if (!m || !m->ptr || !lin_overlap(g->off, g->size, m->map_off, m->map_size)) continue;
            VkDeviceSize a = g->off > m->map_off ? g->off : m->map_off;
            VkDeviceSize e = g->off + g->size < m->map_off + m->map_size ? g->off + g->size : m->map_off + m->map_size;
            uint64_t h = lin_sample_hash(m->ptr + (a - m->map_off), e - a);
            if (g->hashes && h != g->hash) { g->chg++; if (g->gpu_epoch < lin_epoch - 1) g->chg_unexpl++; }
            g->hash = h; g->hashes++;
        }
        lin_epoch++;
    }
    long snap = lin_dump_every > 0 && lin_presents % lin_dump_every == 0 ? lin_presents / lin_dump_every : 0;
    LinDump d = {NULL, 0, ""};
    if (snap) d = lin_dump_take(NULL);
    pthread_mutex_unlock(&lin_mu);
    if (snap) { char why[32]; snprintf(why, sizeof why, "snap%ld", snap); lin_dump_print(&d, why); }
}
static void lin_device_destroyed(VkDevice d) {
    if (!lin_enabled()) return;
    pthread_mutex_lock(&lin_mu);
    LinDump dump = lin_dump_take(d);
    for (uint32_t i = 0; lin_imgs.b && i < (1u << HMAP_BITS); i++) // the device's images are gone with it
        for (HNode **s = &lin_imgs.b[i]; *s;) {
            LinImg *g = (*s)->v;
            if (g->dev != d) { s = &(*s)->next; continue; }
            HNode *n = *s; *s = n->next; free(n); free(g);
        }
    pthread_mutex_unlock(&lin_mu);
    lin_dump_print(&dump, "device");
}
