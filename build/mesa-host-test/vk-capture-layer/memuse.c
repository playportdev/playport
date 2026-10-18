/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The capture layer's memory, upload and present counters, with
 * PP_CAPTURE_MEMUSE=N: per device, its memory allocations (by the
 * application's memory type: live and peak bytes, dedicated ones, the bytes
 * of allocations it maps and of those it never maps), its buffers (those
 * whose only usage is TRANSFER_SRC, staging, apart), the bytes bound to its
 * optimal and linear images, and its copy commands with the bytes they move
 * (buffer to image, buffer to buffer, image to buffer, image to image, buffer
 * updates; counted when recorded, so a command buffer submitted twice counts
 * once). A "memuse" line every N presents on that device and at
 * vkDestroyDevice, and "memuse dev=D slot=S created" at vkCreateDevice; every
 * present's wall-clock time (microseconds) goes to present.PID.log as
 * "SLOT USEC". Included by capture.c, after linear.c (its
 * hash map).
 */

#include <time.h>

static int mu_every = -1;
static int mu_enabled(void) { if (mu_every < 0) { const char *e = getenv("PP_CAPTURE_MEMUSE"); mu_every = e ? atoi(e) : 0; } return mu_every > 0; }
static pthread_mutex_t mu_mu = PTHREAD_MUTEX_INITIALIZER;

#define MU_TYPES 32
typedef struct {
    void *key; VkDevice dev; long presents;
    long allocs, frees, dedicated, maps; VkDeviceSize alloc_bytes, live, peak, dedicated_bytes;
    VkDeviceSize type_live[MU_TYPES], type_peak[MU_TYPES];
    VkDeviceSize mapped_live, mapped_peak, mapped_ever; // bytes of live allocations mapped at least once; their peak; all ever mapped
    long buffers, staging; VkDeviceSize buffer_live, staging_live, staging_peak;
    VkDeviceSize img_opt_live, img_lin_live, img_opt_peak, img_lin_peak;
    long b2i, b2i_regions, b2i_lin, b2b, i2b, i2i, upd;
    VkDeviceSize b2i_bytes, b2i_lin_bytes, b2b_bytes, i2b_bytes, upd_bytes;
} MuDev;
// Each starts with its device, for mu_device_destroyed.
typedef struct { MuDev *d; VkDeviceSize size; uint32_t type; int mapped; } MuMem;
typedef struct { MuDev *d; VkDeviceSize size; int staging; } MuBuf;
typedef struct { MuDev *d; VkFormat fmt; int linear; VkDeviceSize bound; } MuImg;

static MuDev mu_devs[16];
static HMap mu_mems, mu_bufs, mu_imgs;
static FILE *mu_pf;

// The loader's dispatch table pointer, shared by a device and its queues and command buffers.
static void *mu_key(const void *dispatchable) { return *(void *const *)dispatchable; }
static MuDev *mu_dev(const void *dispatchable) {
    void *k = mu_key(dispatchable);
    for (int i = 0; i < 16; i++) if (mu_devs[i].key == k) return &mu_devs[i];
    return NULL;
}

// A format's texel block: bytes, width and height (core formats; extension formats as 4 bytes, 1x1).
static void mu_block(VkFormat f, uint32_t *bytes, uint32_t *bw, uint32_t *bh) {
    *bw = *bh = 1;
    uint32_t b = 4;
    if (f == 1 || (f >= 9 && f <= 15) || f == 127) b = 1;
    else if ((f >= 2 && f <= 8) || (f >= 16 && f <= 22) || (f >= 70 && f <= 76) || f == 124) b = 2;
    else if ((f >= 23 && f <= 36) || f == 128) b = 3;
    else if ((f >= 84 && f <= 90)) b = 6;
    else if ((f >= 91 && f <= 97) || (f >= 101 && f <= 103) || (f >= 110 && f <= 112) || f == 130) b = 8;
    else if (f >= 104 && f <= 106) b = 12;
    else if ((f >= 107 && f <= 109) || (f >= 113 && f <= 115)) b = 16;
    else if (f >= 116 && f <= 118) b = 24;
    else if (f >= 119 && f <= 121) b = 32;
    else if (f >= 131 && f <= 184) { // BC, ETC2/EAC, ASTC (as 4x4)
        *bw = *bh = 4;
        b = (f <= 134 || (f >= 139 && f <= 140) || (f >= 147 && f <= 150) || (f >= 153 && f <= 154)) ? 8 : 16;
    } else if (f == 1000470000 || f == 1000470001) b = 1; // A8_UNORM, A1B5G5R5
    *bytes = b;
}
static VkDeviceSize mu_copy_bytes(VkFormat f, const VkBufferImageCopy *r) {
    uint32_t b, bw, bh; mu_block(f, &b, &bw, &bh);
    return (VkDeviceSize)((r->imageExtent.width + bw - 1) / bw) * ((r->imageExtent.height + bh - 1) / bh) * r->imageExtent.depth * r->imageSubresource.layerCount * b;
}

static void mu_line(MuDev *d, const char *why) { // under mu_mu
    char types[512]; int n = 0;
    types[0] = 0;
    for (int t = 0; t < MU_TYPES && n < (int)sizeof types - 48; t++)
        if (d->type_peak[t]) n += snprintf(types + n, sizeof types - n, "%s%d:%llu/%llu", n ? "," : "", t, (unsigned long long)d->type_live[t], (unsigned long long)d->type_peak[t]);
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    L("memuse dev=%p slot=%d %s presents=%ld t=%lld.%03ld allocs=%ld frees=%ld alloc_bytes=%llu live=%llu peak=%llu dedicated=%ld/%llu types=%s"
      " maps=%ld mapped_live=%llu mapped_peak=%llu mapped_ever=%llu never_mapped_live=%llu buffers=%ld/%llu staging=%ld/%llu staging_peak=%llu"
      " img_opt=%llu/%llu img_lin=%llu/%llu b2i=%ld/%ld/%llu b2i_lin=%ld/%llu b2b=%ld/%llu i2b=%ld/%llu i2i=%ld upd=%ld/%llu\n",
      (void *)d->dev, (int)(d - mu_devs), why, d->presents, (long long)ts.tv_sec, ts.tv_nsec / 1000000, d->allocs, d->frees, (unsigned long long)d->alloc_bytes,
      (unsigned long long)d->live, (unsigned long long)d->peak, d->dedicated, (unsigned long long)d->dedicated_bytes, types,
      d->maps, (unsigned long long)d->mapped_live, (unsigned long long)d->mapped_peak, (unsigned long long)d->mapped_ever,
      (unsigned long long)(d->live - d->mapped_live), d->buffers, (unsigned long long)d->buffer_live, d->staging, (unsigned long long)d->staging_live,
      (unsigned long long)d->staging_peak, (unsigned long long)d->img_opt_live, (unsigned long long)d->img_opt_peak,
      (unsigned long long)d->img_lin_live, (unsigned long long)d->img_lin_peak, d->b2i, d->b2i_regions, (unsigned long long)d->b2i_bytes,
      d->b2i_lin, (unsigned long long)d->b2i_lin_bytes, d->b2b, (unsigned long long)d->b2b_bytes, d->i2b, (unsigned long long)d->i2b_bytes,
      d->i2i, d->upd, (unsigned long long)d->upd_bytes);
}

static void mu_device_created(VkDevice dev) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    for (int i = 0; i < 16; i++)
        if (!mu_devs[i].key) {
            memset(&mu_devs[i], 0, sizeof mu_devs[i]); mu_devs[i].key = mu_key(dev); mu_devs[i].dev = dev;
            L("memuse dev=%p slot=%d created\n", (void *)dev, i); // the slot present.PID.log names
            break;
        }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_device_destroyed(VkDevice dev) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(dev);
    if (d) {
        mu_line(d, "device");
        HMap *maps[3] = {&mu_mems, &mu_bufs, &mu_imgs}; // the device's objects are gone with it
        for (int m = 0; m < 3; m++)
            for (uint32_t i = 0; maps[m]->b && i < (1u << HMAP_BITS); i++)
                for (HNode **s = &maps[m]->b[i]; *s;) {
                    if (*(MuDev **)(*s)->v != d) { s = &(*s)->next; continue; }
                    HNode *n = *s; *s = n->next; free(n->v); free(n);
                }
        d->key = NULL;
    }
    if (mu_pf) fflush(mu_pf);
    pthread_mutex_unlock(&mu_mu);
}

/* memory */
static void mu_allocated(VkDevice dev, const VkMemoryAllocateInfo *ai, VkDeviceMemory mem) {
    if (!mu_enabled()) return;
    int dedicated = 0;
    for (const Hdr *h = ai->pNext; h; h = h->pNext)
        if (h->sType == VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO) {
            const VkMemoryDedicatedAllocateInfo *di = (const void *)h;
            dedicated = di->image || di->buffer;
        }
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(dev);
    if (d) {
        uint32_t t = ai->memoryTypeIndex < MU_TYPES ? ai->memoryTypeIndex : MU_TYPES - 1;
        MuMem *m = calloc(1, sizeof *m); m->size = ai->allocationSize; m->type = t; m->d = d;
        hm_put(&mu_mems, (uint64_t)(uintptr_t)mem, m);
        d->allocs++; d->alloc_bytes += m->size; d->live += m->size; if (d->live > d->peak) d->peak = d->live;
        d->type_live[t] += m->size; if (d->type_live[t] > d->type_peak[t]) d->type_peak[t] = d->type_live[t];
        if (dedicated) { d->dedicated++; d->dedicated_bytes += m->size; }
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_freed(VkDeviceMemory mem) {
    if (!mu_enabled() || !mem) return;
    pthread_mutex_lock(&mu_mu);
    MuMem *m = hm_del(&mu_mems, (uint64_t)(uintptr_t)mem);
    if (m) {
        MuDev *d = m->d;
        d->frees++; d->live -= m->size; d->type_live[m->type] -= m->size;
        if (m->mapped) d->mapped_live -= m->size;
        free(m);
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_mapped(VkDeviceMemory mem) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuMem *m = hm_get(&mu_mems, (uint64_t)(uintptr_t)mem);
    if (m) {
        MuDev *d = m->d;
        d->maps++;
        if (!m->mapped) {
            m->mapped = 1; d->mapped_live += m->size; d->mapped_ever += m->size;
            if (d->mapped_live > d->mapped_peak) d->mapped_peak = d->mapped_live;
        }
    }
    pthread_mutex_unlock(&mu_mu);
}

/* buffers and images */
static void mu_buffer_created(VkDevice dev, const VkBufferCreateInfo *ci, VkBuffer b) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(dev);
    if (d) {
        MuBuf *o = calloc(1, sizeof *o); o->size = ci->size; o->staging = ci->usage == VK_BUFFER_USAGE_TRANSFER_SRC_BIT; o->d = d;
        hm_put(&mu_bufs, (uint64_t)(uintptr_t)b, o);
        d->buffers++; d->buffer_live += o->size;
        if (o->staging) { d->staging++; d->staging_live += o->size; if (d->staging_live > d->staging_peak) d->staging_peak = d->staging_live; }
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_buffer_destroyed(VkBuffer b) {
    if (!mu_enabled() || !b) return;
    pthread_mutex_lock(&mu_mu);
    MuBuf *o = hm_del(&mu_bufs, (uint64_t)(uintptr_t)b);
    if (o) { o->d->buffer_live -= o->size; if (o->staging) o->d->staging_live -= o->size; free(o); }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_image_created(VkDevice dev, const VkImageCreateInfo *ci, VkImage img) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(dev);
    if (d) {
        MuImg *o = calloc(1, sizeof *o); o->fmt = ci->format; o->linear = ci->tiling == VK_IMAGE_TILING_LINEAR; o->d = d;
        hm_put(&mu_imgs, (uint64_t)(uintptr_t)img, o);
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_image_unbind(MuImg *o) { // under mu_mu
    if (o->linear) o->d->img_lin_live -= o->bound; else o->d->img_opt_live -= o->bound;
    o->bound = 0;
}
static void mu_image_bound(VkDevice dev, VkImage img) {
    if (!mu_enabled()) return;
    VkMemoryRequirements req = {0};
    p_ImgReq(dev, img, &req);
    pthread_mutex_lock(&mu_mu);
    MuImg *o = hm_get(&mu_imgs, (uint64_t)(uintptr_t)img);
    if (o) {
        MuDev *d = o->d;
        mu_image_unbind(o);
        o->bound = req.size;
        if (o->linear) { d->img_lin_live += o->bound; if (d->img_lin_live > d->img_lin_peak) d->img_lin_peak = d->img_lin_live; }
        else { d->img_opt_live += o->bound; if (d->img_opt_live > d->img_opt_peak) d->img_opt_peak = d->img_opt_live; }
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_image_destroyed(VkImage img) {
    if (!mu_enabled() || !img) return;
    pthread_mutex_lock(&mu_mu);
    MuImg *o = hm_del(&mu_imgs, (uint64_t)(uintptr_t)img);
    if (o) { mu_image_unbind(o); free(o); }
    pthread_mutex_unlock(&mu_mu);
}

/* copies, counted when recorded */
static void mu_copy_to_image(VkCommandBuffer c, VkImage img, uint32_t n, const VkBufferImageCopy *r, int to_buffer) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(c);
    MuImg *o = hm_get(&mu_imgs, (uint64_t)(uintptr_t)img);
    if (d) {
        VkDeviceSize bytes = 0;
        for (uint32_t k = 0; o && k < n; k++) bytes += mu_copy_bytes(o->fmt, &r[k]);
        if (to_buffer) { d->i2b++; d->i2b_bytes += bytes; }
        else {
            d->b2i++; d->b2i_regions += n; d->b2i_bytes += bytes;
            if (o && o->linear) { d->b2i_lin++; d->b2i_lin_bytes += bytes; }
        }
    }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_copy_buffer(VkCommandBuffer c, uint32_t n, const VkBufferCopy *r) {
    if (!mu_enabled()) return;
    VkDeviceSize bytes = 0;
    for (uint32_t k = 0; k < n; k++) bytes += r[k].size;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(c);
    if (d) { d->b2b++; d->b2b_bytes += bytes; }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_update_buffer(VkCommandBuffer c, VkDeviceSize bytes) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(c);
    if (d) { d->upd++; d->upd_bytes += bytes; }
    pthread_mutex_unlock(&mu_mu);
}
static void mu_copy_image(VkCommandBuffer c) {
    if (!mu_enabled()) return;
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(c);
    if (d) d->i2i++;
    pthread_mutex_unlock(&mu_mu);
}

/* presents */
static void mu_present(VkQueue q) {
    if (!mu_enabled()) return;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    pthread_mutex_lock(&mu_mu);
    MuDev *d = mu_dev(q);
    if (d) {
        if (!mu_pf) {
            char p[1200];
            pthread_mutex_lock(&mu); openlog_(); snprintf(p, sizeof p, "%s/present.%d.log", outdir, (int)getpid()); pthread_mutex_unlock(&mu);
            mu_pf = fopen(p, "a");
        }
        if (mu_pf) fprintf(mu_pf, "%d %lld\n", (int)(d - mu_devs), (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000);
        if (++d->presents % mu_every == 0) { mu_line(d, "every"); if (mu_pf) fflush(mu_pf); }
    }
    pthread_mutex_unlock(&mu_mu);
}
