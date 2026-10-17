/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The capture layer's profile: with PP_CAPTURE_PROFILE=REPORT, where REPORT
 * is devinfo's output for another device (build/mesa-host-test/devinfo.c, for
 * example KosmicKrisp on the host mock), the desktop device shows only that
 * device's extensions, its 1.0 features (ANDed), format features (ANDed),
 * sample counts and line width, one queue family with one queue, and one
 * memory type (DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT | HOST_CACHED) on
 * one heap of the report's heap 0 size, as KosmicKrisp has. With
 * PP_CAPTURE_SPOOF=1 it also takes the report's vendor, device ID, name and
 * an integrated device type. Included by capture.c.
 *
 * The report's memory type stands for the first desktop type that is
 * DEVICE_LOCAL, HOST_VISIBLE and HOST_COHERENT, chosen per physical device:
 * instances in one process can see different memory layouts (Mesa's driconf
 * matches by application name). The heap's size is the report's, not capped
 * by the size of the heap behind that type; PP_CAPTURE_HEAP_CAP=1 caps it.
 * VK_EXT_memory_budget's heap 0 follows KosmicKrisp's rule (prof_budget),
 * with the usage of the heap behind that type.
 */

static int prof_on;
static char **prof_ext; static int prof_next;
static VkBool32 prof_f10[55];
static VkFormatProperties prof_fmt[200];
static uint32_t prof_vendor, prof_devid;
static char prof_name[256];
static VkDeviceSize prof_heap = ~0ull;
// Sample count masks and the widest line, from the report's limits.
static VkSampleCountFlags prof_color_samples = ~0u, prof_depth_samples = ~0u, prof_storage_samples = ~0u;
static float prof_line_width = 1e9f;

static const char *f10names[] = {"robustBufferAccess","fullDrawIndexUint32","imageCubeArray","independentBlend","geometryShader","tessellationShader","sampleRateShading","dualSrcBlend","logicOp","multiDrawIndirect","drawIndirectFirstInstance","depthClamp","depthBiasClamp","fillModeNonSolid","depthBounds","wideLines","largePoints","alphaToOne","multiViewport","samplerAnisotropy","textureCompressionETC2","textureCompressionASTC_LDR","textureCompressionBC","occlusionQueryPrecise","pipelineStatisticsQuery","vertexPipelineStoresAndAtomics","fragmentStoresAndAtomics","shaderTessellationAndGeometryPointSize","shaderImageGatherExtended","shaderStorageImageExtendedFormats","shaderStorageImageMultisample","shaderStorageImageReadWithoutFormat","shaderStorageImageWriteWithoutFormat","shaderUniformBufferArrayDynamicIndexing","shaderSampledImageArrayDynamicIndexing","shaderStorageBufferArrayDynamicIndexing","shaderStorageImageArrayDynamicIndexing","shaderClipDistance","shaderCullDistance","shaderFloat64","shaderInt64","shaderInt16","shaderResourceResidency","shaderResourceMinLod","sparseBinding","sparseResidencyBuffer","sparseResidencyImage2D","sparseResidencyImage3D","sparseResidency2Samples","sparseResidency4Samples","sparseResidency8Samples","sparseResidency16Samples","sparseResidencyAliased","variableMultisampleRate","inheritedQueries"};

static void prof_load(void) {
    static int done; if (done) return; done = 1;
    const char *p = getenv("PP_CAPTURE_PROFILE");
    if (!p) return;
    FILE *f = fopen(p, "r");
    if (!f) return;
    char line[512];
    int fmtidx = 1; // devinfo prints formats 1..184 in order
    prof_ext = calloc(1024, sizeof(char *));
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "ext ", 4)) prof_ext[prof_next++] = strdup(line + 4);
        else if (!strncmp(line, "f10 ", 4)) {
            char name[128]; unsigned v;
            if (sscanf(line + 4, "%127s %u", name, &v) == 2)
                for (int i = 0; i < 55; i++) if (!strcmp(name, f10names[i])) prof_f10[i] = v;
        } else if (!strncmp(line, "format ", 7)) {
            unsigned lin, opt, buf; char name[128];
            if (sscanf(line + 7, "%127s lin=%x opt=%x buf=%x", name, &lin, &opt, &buf) == 4 && fmtidx < 200) {
                prof_fmt[fmtidx].linearTilingFeatures = lin; prof_fmt[fmtidx].optimalTilingFeatures = opt; prof_fmt[fmtidx].bufferFeatures = buf;
            }
            fmtidx++;
        } else if (!strncmp(line, "device ", 7)) {
            char *api = strstr(line, " api ");
            if (api) *api = 0;
            snprintf(prof_name, sizeof prof_name, "%.255s", line + 7);
            char *m = strstr(prof_name, "Mock ");
            if (m == prof_name) memmove(prof_name, prof_name + 5, strlen(prof_name + 5) + 1);
        } else if (!strncmp(line, "heap 0 size=", 12)) prof_heap = strtoull(line + 12, NULL, 10);
        else if (!strncmp(line, "vendor ", 7)) sscanf(line + 7, "%x device %x", &prof_vendor, &prof_devid);
        else if (!strncmp(line, "limit framebufferColorSampleCounts ", 35)) prof_color_samples = strtoul(line + 35, NULL, 10);
        else if (!strncmp(line, "limit framebufferDepthSampleCounts ", 35)) prof_depth_samples = strtoul(line + 35, NULL, 10);
        else if (!strncmp(line, "limit storageImageSampleCounts ", 31)) prof_storage_samples = strtoul(line + 31, NULL, 10);
        else if (!strncmp(line, "limit lineWidthRange ", 21)) sscanf(line + 21, "%*f %f", &prof_line_width);
    }
    fclose(f);
    prof_on = 1;
    L("profile %s: %d extensions, name '%s', heap %llu\n", p, prof_next, prof_name, (unsigned long long)prof_heap);
}

static int prof_has_ext(const char *n) {
    for (int i = 0; i < prof_next; i++) if (!strcmp(prof_ext[i], n)) return 1;
    return 0;
}

static PFN_vkEnumerateDeviceExtensionProperties p_EnumDevExt;
static PFN_vkGetPhysicalDeviceFeatures p_GetFeatures;
static PFN_vkGetPhysicalDeviceFeatures2 p_GetFeatures2;
static PFN_vkGetPhysicalDeviceProperties p_GetProps;
static PFN_vkGetPhysicalDeviceProperties2 p_GetProps2;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties p_GetQF;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties2 p_GetQF2;
static PFN_vkGetPhysicalDeviceMemoryProperties p_GetMem;
static PFN_vkGetPhysicalDeviceMemoryProperties2 p_GetMem2;
static PFN_vkGetPhysicalDeviceFormatProperties p_GetFmt;
static PFN_vkGetPhysicalDeviceFormatProperties2 p_GetFmt2;
static PFN_vkGetPhysicalDeviceImageFormatProperties p_GetImgFmt;
static PFN_vkGetPhysicalDeviceImageFormatProperties2 p_GetImgFmt2;

static void prof_resolve(VkInstance i) {
#define R(v, n) v = (void *)next_gipa(i, n);
    R(p_EnumDevExt, "vkEnumerateDeviceExtensionProperties") R(p_GetFeatures, "vkGetPhysicalDeviceFeatures")
    R(p_GetFeatures2, "vkGetPhysicalDeviceFeatures2") R(p_GetProps, "vkGetPhysicalDeviceProperties")
    R(p_GetProps2, "vkGetPhysicalDeviceProperties2") R(p_GetQF, "vkGetPhysicalDeviceQueueFamilyProperties")
    R(p_GetQF2, "vkGetPhysicalDeviceQueueFamilyProperties2") R(p_GetMem, "vkGetPhysicalDeviceMemoryProperties")
    R(p_GetMem2, "vkGetPhysicalDeviceMemoryProperties2") R(p_GetFmt, "vkGetPhysicalDeviceFormatProperties")
    R(p_GetFmt2, "vkGetPhysicalDeviceFormatProperties2") R(p_GetImgFmt, "vkGetPhysicalDeviceImageFormatProperties")
    R(p_GetImgFmt2, "vkGetPhysicalDeviceImageFormatProperties2")
}

static VkResult VKAPI_CALL q_EnumDevExt(VkPhysicalDevice pd, const char *layer, uint32_t *n, VkExtensionProperties *out) {
    if (layer) return p_EnumDevExt(pd, layer, n, out);
    uint32_t all = 0; p_EnumDevExt(pd, NULL, &all, NULL);
    VkExtensionProperties *e = calloc(all, sizeof *e); p_EnumDevExt(pd, NULL, &all, e);
    uint32_t k = 0;
    for (uint32_t i = 0; i < all; i++) if (prof_has_ext(e[i].extensionName)) e[k++] = e[i];
    VkResult r = VK_SUCCESS;
    if (!out) *n = k;
    else { uint32_t c = *n < k ? *n : k; memcpy(out, e, c * sizeof *e); if (c < k) r = VK_INCOMPLETE; *n = c; }
    free(e);
    return r;
}

static void prof_mask10(VkPhysicalDeviceFeatures *f) {
    VkBool32 *b = (VkBool32 *)f;
    for (int i = 0; i < 55; i++) b[i] = b[i] && prof_f10[i];
}
static void VKAPI_CALL q_GetFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) { p_GetFeatures(pd, f); prof_mask10(f); }
static void VKAPI_CALL q_GetFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    p_GetFeatures2(pd, f); prof_mask10(&f->features);
    for (Hdr *h = (Hdr *)f->pNext; h; h = (Hdr *)h->pNext) {
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES) ((VkPhysicalDeviceVulkan11Features *)h)->storageInputOutput16 = 0;
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES) ((VkPhysicalDevice16BitStorageFeatures *)h)->storageInputOutput16 = 0;
    }
}

static void prof_limits(VkPhysicalDeviceProperties *p) {
    VkPhysicalDeviceLimits *l = &p->limits;
    l->framebufferColorSampleCounts &= prof_color_samples; l->framebufferDepthSampleCounts &= prof_depth_samples;
    l->framebufferStencilSampleCounts &= prof_depth_samples; l->framebufferNoAttachmentsSampleCounts &= prof_color_samples;
    l->sampledImageColorSampleCounts &= prof_color_samples; l->sampledImageIntegerSampleCounts &= prof_color_samples;
    l->sampledImageDepthSampleCounts &= prof_depth_samples; l->sampledImageStencilSampleCounts &= prof_depth_samples;
    l->storageImageSampleCounts &= prof_storage_samples;
    if (l->lineWidthRange[1] > prof_line_width) l->lineWidthRange[1] = prof_line_width;
    if (getenv("PP_CAPTURE_SPOOF")) {
        p->vendorID = prof_vendor; p->deviceID = prof_devid;
        snprintf(p->deviceName, sizeof p->deviceName, "%s", prof_name);
        p->deviceType = VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;
    }
}
static void VKAPI_CALL q_GetProps(VkPhysicalDevice pd, VkPhysicalDeviceProperties *p) { p_GetProps(pd, p); prof_limits(p); }
static void VKAPI_CALL q_GetProps2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) { p_GetProps2(pd, p); prof_limits(&p->properties); }

static void VKAPI_CALL q_GetQF(VkPhysicalDevice pd, uint32_t *n, VkQueueFamilyProperties *q) {
    uint32_t all = 0; p_GetQF(pd, &all, NULL);
    VkQueueFamilyProperties *a = calloc(all, sizeof *a); p_GetQF(pd, &all, a);
    if (!q) *n = 1;
    else if (*n >= 1) { q[0] = a[0]; q[0].queueCount = 1; q[0].queueFlags &= 7; *n = 1; }
    free(a);
}
static void VKAPI_CALL q_GetQF2(VkPhysicalDevice pd, uint32_t *n, VkQueueFamilyProperties2 *q) {
    if (!q) { *n = 1; return; }
    uint32_t all = 0; p_GetQF2(pd, &all, NULL);
    VkQueueFamilyProperties2 *a = calloc(all, sizeof *a);
    for (uint32_t i = 0; i < all; i++) a[i].sType = VK_STRUCTURE_TYPE_QUEUE_FAMILY_PROPERTIES_2;
    p_GetQF2(pd, &all, a);
    if (*n >= 1) { q[0].queueFamilyProperties = a[0].queueFamilyProperties; q[0].queueFamilyProperties.queueCount = 1; q[0].queueFamilyProperties.queueFlags &= 7; *n = 1; }
    free(a);
}

// The desktop memory type that stands for the report's one in this layout, or UINT32_MAX.
static uint32_t prof_memtype_of(const VkPhysicalDeviceMemoryProperties *m) {
    uint32_t want = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < m->memoryTypeCount; i++)
        if ((m->memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

// Translates the memory properties to the report's one type and heap; returns the
// desktop heap behind the stand-in type, or UINT32_MAX when they are left as the driver's.
static uint32_t prof_mem(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *m) {
    static VkPhysicalDevice last_pd; // log a physical device's answer once in a row
    int log = pd != last_pd; last_pd = pd;
    uint32_t t = prof_memtype_of(m);
    if (t == UINT32_MAX) { if (log) L("profile memory pd %p: no stand-in type, left as the driver's\n", (void *)pd); return UINT32_MAX; }
    uint32_t hi = m->memoryTypes[t].heapIndex;
    VkMemoryHeap h = m->memoryHeaps[hi];
    VkDeviceSize size = prof_heap;
    if (size == ~0ull || (getenv("PP_CAPTURE_HEAP_CAP") && h.size < size)) size = h.size;
    if (log) L("profile memory pd %p: desktop type %u on heap %u (%llu), reported heap %llu\n", (void *)pd, t,
               hi, (unsigned long long)h.size, (unsigned long long)size);
    memset(m, 0, sizeof *m);
    m->memoryTypeCount = 1; m->memoryTypes[0].propertyFlags = 0xf; m->memoryTypes[0].heapIndex = 0;
    m->memoryHeapCount = 1; m->memoryHeaps[0].size = size; m->memoryHeaps[0].flags = VK_MEMORY_HEAP_DEVICE_LOCAL_BIT;
    return hi;
}

// KosmicKrisp's heap budget (kk_get_sysmem_heap_budget): 90% of the system's
// available memory plus the heap's usage, at most the heap, in whole MiB. The
// system here is the workstation's (MemAvailable, as Mesa reads it on Linux).
static VkDeviceSize prof_budget(VkDeviceSize heap, VkDeviceSize used) {
    unsigned long long kb = 0;
    FILE *f = fopen("/proc/meminfo", "r");
    char line[256];
    while (f && fgets(line, sizeof line, f)) if (sscanf(line, "MemAvailable: %llu", &kb) == 1) break;
    if (f) fclose(f);
    VkDeviceSize b = (VkDeviceSize)((kb << 10) * 0.9f) + used;
    if (b > heap) b = heap;
    return b & ~((VkDeviceSize)(1 << 20) - 1);
}

static void VKAPI_CALL q_GetMem(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *m) { p_GetMem(pd, m); prof_mem(pd, m); }
static void VKAPI_CALL q_GetMem2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *m) {
    p_GetMem2(pd, m);
    uint32_t hi = prof_mem(pd, &m->memoryProperties);
    if (hi == UINT32_MAX) return;
    for (Hdr *h = (Hdr *)m->pNext; h; h = (Hdr *)h->pNext) {
        if (h->sType != VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT) continue;
        VkPhysicalDeviceMemoryBudgetPropertiesEXT *b = (VkPhysicalDeviceMemoryBudgetPropertiesEXT *)h;
        VkDeviceSize desk = b->heapBudget[hi], used = b->heapUsage[hi];
        memset(b->heapBudget, 0, sizeof b->heapBudget); memset(b->heapUsage, 0, sizeof b->heapUsage);
        b->heapBudget[0] = prof_budget(m->memoryProperties.memoryHeaps[0].size, used); b->heapUsage[0] = used;
        static VkPhysicalDevice last_pd; // as prof_mem's log
        if (pd != last_pd) L("profile budget pd %p: heap 0 budget %llu, usage %llu (desktop heap %u budget %llu)\n", (void *)pd,
                             (unsigned long long)b->heapBudget[0], (unsigned long long)used, hi, (unsigned long long)desk);
        last_pd = pd;
    }
}

static void prof_fmtmask(VkFormat f, VkFormatProperties *p) {
    if ((int)f <= 0 || (int)f >= 200) return; // extension formats: leave as the driver says
    p->linearTilingFeatures &= prof_fmt[f].linearTilingFeatures;
    p->optimalTilingFeatures &= prof_fmt[f].optimalTilingFeatures;
    p->bufferFeatures &= prof_fmt[f].bufferFeatures;
}
static void VKAPI_CALL q_GetFmt(VkPhysicalDevice pd, VkFormat f, VkFormatProperties *p) { p_GetFmt(pd, f, p); prof_fmtmask(f, p); }
static void VKAPI_CALL q_GetFmt2(VkPhysicalDevice pd, VkFormat f, VkFormatProperties2 *p) { p_GetFmt2(pd, f, p); prof_fmtmask(f, &p->formatProperties); }

static uint32_t usage_feats(VkImageUsageFlags u) {
    uint32_t r = 0;
    if (u & VK_IMAGE_USAGE_SAMPLED_BIT) r |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
    if (u & VK_IMAGE_USAGE_STORAGE_BIT) r |= VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT;
    if (u & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) r |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    if (u & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) r |= VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    return r;
}
static VkResult prof_imgfmt(VkFormat f, VkImageTiling t, VkImageUsageFlags u, VkImageFormatProperties *p) {
    if ((int)f > 0 && (int)f < 200) {
        uint32_t have = t == VK_IMAGE_TILING_LINEAR ? prof_fmt[f].linearTilingFeatures : prof_fmt[f].optimalTilingFeatures;
        uint32_t need = usage_feats(u);
        if ((have & need) != need) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    }
    p->sampleCounts &= (u & VK_IMAGE_USAGE_STORAGE_BIT) ? prof_storage_samples
                     : (u & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) ? prof_depth_samples : prof_color_samples;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL q_GetImgFmt(VkPhysicalDevice pd, VkFormat f, VkImageType ty, VkImageTiling t, VkImageUsageFlags u, VkImageCreateFlags fl, VkImageFormatProperties *p) {
    VkResult r = p_GetImgFmt(pd, f, ty, t, u, fl, p);
    if (r) return r;
    return prof_imgfmt(f, t, u, p);
}
static VkResult VKAPI_CALL q_GetImgFmt2(VkPhysicalDevice pd, const VkPhysicalDeviceImageFormatInfo2 *i, VkImageFormatProperties2 *p) {
    VkResult r = p_GetImgFmt2(pd, i, p);
    if (r) return r;
    return prof_imgfmt(i->format, i->tiling, i->usage, &p->imageFormatProperties);
}

static PFN_vkVoidFunction prof_lookup_inst(const char *n) {
    if (!prof_on) return NULL;
#define Q(name, fn) if (!strcmp(n, name) || !strcmp(n, name "KHR")) return (PFN_vkVoidFunction)fn;
    Q("vkEnumerateDeviceExtensionProperties", q_EnumDevExt)
    Q("vkGetPhysicalDeviceFeatures", q_GetFeatures) Q("vkGetPhysicalDeviceFeatures2", q_GetFeatures2)
    Q("vkGetPhysicalDeviceProperties", q_GetProps) Q("vkGetPhysicalDeviceProperties2", q_GetProps2)
    Q("vkGetPhysicalDeviceQueueFamilyProperties", q_GetQF) Q("vkGetPhysicalDeviceQueueFamilyProperties2", q_GetQF2)
    Q("vkGetPhysicalDeviceMemoryProperties", q_GetMem) Q("vkGetPhysicalDeviceMemoryProperties2", q_GetMem2)
    Q("vkGetPhysicalDeviceFormatProperties", q_GetFmt) Q("vkGetPhysicalDeviceFormatProperties2", q_GetFmt2)
    Q("vkGetPhysicalDeviceImageFormatProperties", q_GetImgFmt) Q("vkGetPhysicalDeviceImageFormatProperties2", q_GetImgFmt2)
    return NULL;
}

/* device side: memory type translation, by each device's stand-in type */
static PFN_vkGetBufferMemoryRequirements p_BufReq; static PFN_vkGetImageMemoryRequirements p_ImgReq;
static PFN_vkGetBufferMemoryRequirements2 p_BufReq2; static PFN_vkGetImageMemoryRequirements2 p_ImgReq2;
static pthread_mutex_t prof_dev_mu = PTHREAD_MUTEX_INITIALIZER;
static struct { VkDevice dev; uint32_t memtype; } prof_devs[64];

static void prof_device_created(VkPhysicalDevice pd, VkDevice d) {
    if (!prof_on) return;
    VkPhysicalDeviceMemoryProperties m; p_GetMem(pd, &m);
    uint32_t t = prof_memtype_of(&m);
    pthread_mutex_lock(&prof_dev_mu);
    int k = 0;
    while (k < 64 && prof_devs[k].dev && prof_devs[k].dev != d) k++;
    if (k < 64) { prof_devs[k].dev = d; prof_devs[k].memtype = t; }
    pthread_mutex_unlock(&prof_dev_mu);
    L("profile device %p on pd %p: desktop memory type %u%s\n", (void *)d, (void *)pd, t, k < 64 ? "" : " (table full: not translated)");
}
static void prof_device_destroyed(VkDevice d) {
    pthread_mutex_lock(&prof_dev_mu);
    for (int k = 0; k < 64; k++) if (prof_devs[k].dev == d) prof_devs[k].dev = NULL;
    pthread_mutex_unlock(&prof_dev_mu);
}
// The device's stand-in type, or UINT32_MAX (no profile, or its memory left as the driver's).
static uint32_t prof_memtype_dev(VkDevice d) {
    uint32_t t = UINT32_MAX;
    pthread_mutex_lock(&prof_dev_mu);
    for (int k = 0; k < 64; k++) if (prof_devs[k].dev == d) { t = prof_devs[k].memtype; break; }
    pthread_mutex_unlock(&prof_dev_mu);
    return t;
}
static uint32_t prof_bits(VkDevice d, uint32_t b) { uint32_t t = prof_memtype_dev(d); return t == UINT32_MAX ? b : (b >> t) & 1; }
static void VKAPI_CALL q_BufReq(VkDevice d, VkBuffer b, VkMemoryRequirements *r) { p_BufReq(d, b, r); r->memoryTypeBits = prof_bits(d, r->memoryTypeBits); }
static void VKAPI_CALL q_ImgReq(VkDevice d, VkImage i, VkMemoryRequirements *r) { p_ImgReq(d, i, r); r->memoryTypeBits = prof_bits(d, r->memoryTypeBits); }
static void VKAPI_CALL q_BufReq2(VkDevice d, const VkBufferMemoryRequirementsInfo2 *i, VkMemoryRequirements2 *r) { p_BufReq2(d, i, r); r->memoryRequirements.memoryTypeBits = prof_bits(d, r->memoryRequirements.memoryTypeBits); }
static void VKAPI_CALL q_ImgReq2(VkDevice d, const VkImageMemoryRequirementsInfo2 *i, VkMemoryRequirements2 *r) { p_ImgReq2(d, i, r); r->memoryRequirements.memoryTypeBits = prof_bits(d, r->memoryRequirements.memoryTypeBits); }

static void prof_resolve_dev(VkDevice d) {
    p_BufReq = (void *)next_gdpa(d, "vkGetBufferMemoryRequirements"); p_ImgReq = (void *)next_gdpa(d, "vkGetImageMemoryRequirements");
    p_BufReq2 = (void *)next_gdpa(d, "vkGetBufferMemoryRequirements2"); p_ImgReq2 = (void *)next_gdpa(d, "vkGetImageMemoryRequirements2");
}
static PFN_vkVoidFunction prof_lookup_dev(const char *n) {
    if (!prof_on) return NULL;
    Q("vkGetBufferMemoryRequirements", q_BufReq) Q("vkGetImageMemoryRequirements", q_ImgReq)
    Q("vkGetBufferMemoryRequirements2", q_BufReq2) Q("vkGetImageMemoryRequirements2", q_ImgReq2)
    return NULL;
}
