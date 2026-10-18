/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The capture layer's profile: with PP_CAPTURE_PROFILE=REPORT, where REPORT
 * is devinfo's output for another device (build/mesa-host-test/devinfo.c, for
 * example KosmicKrisp on the host mock), the desktop device shows only that
 * device's extensions, its 1.0 features (ANDed), format features (ANDed,
 * VkFormatFeatureFlags2 too; an extension format the report does not list
 * has none), sample counts and line width, float controls (ANDed, the
 * narrower independence), subgroup sizes (within the desktop's range) and
 * size control (ANDed), one queue family with one queue, and one memory type
 * (DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT | HOST_CACHED) on one heap of
 * the report's heap 0 size, as KosmicKrisp has. With PP_CAPTURE_SPOOF=1 it
 * also takes the report's vendor, device ID, name, driver ID, driver name and
 * info, conformance version and an integrated device type. A property an
 * older report does not print is left as the desktop's, but for extension
 * formats. Included by capture.c.
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
// A format's features in the report: VkFormatFeatureFlags, and VkFormatFeatureFlags2
// when the report has them (has2).
typedef struct { VkFormatProperties p; int has2; VkFormatFeatureFlags2 lin2, opt2, buf2; } ProfFormat;
static ProfFormat prof_fmt[185]; // core formats, by value
// Extension formats (>= 1000000000) the report lists; any other has no features.
static struct { VkFormat f; ProfFormat p; } prof_xfmt[256]; static int prof_nxfmt;
static uint32_t prof_vendor, prof_devid;
static char prof_name[256];
// The driver (spoofed with the name), when the report has it.
static int prof_has_driver;
static VkDriverId prof_driver_id;
static char prof_driver_name[VK_MAX_DRIVER_NAME_SIZE], prof_driver_info[VK_MAX_DRIVER_INFO_SIZE];
static VkConformanceVersion prof_conformance;
// Float controls and subgroups, by devinfo's "fc", "subgroup" and "f13" names; -1 when the report lacks one.
static const char *fcnames[] = {"denormBehaviorIndependence","roundingModeIndependence",
    "shaderSignedZeroInfNanPreserveFloat16","shaderSignedZeroInfNanPreserveFloat32","shaderSignedZeroInfNanPreserveFloat64",
    "shaderDenormPreserveFloat16","shaderDenormPreserveFloat32","shaderDenormPreserveFloat64",
    "shaderDenormFlushToZeroFloat16","shaderDenormFlushToZeroFloat32","shaderDenormFlushToZeroFloat64",
    "shaderRoundingModeRTEFloat16","shaderRoundingModeRTEFloat32","shaderRoundingModeRTEFloat64",
    "shaderRoundingModeRTZFloat16","shaderRoundingModeRTZFloat32","shaderRoundingModeRTZFloat64"};
static long long prof_fc[17];
static const char *sgnames[] = {"subgroupSize","supportedStages","supportedOperations","quadOperationsInAllStages",
    "minSubgroupSize","maxSubgroupSize","maxComputeWorkgroupSubgroups","requiredSubgroupSizeStages"};
enum { SG_SIZE, SG_STAGES, SG_OPS, SG_QUAD, SG_MIN, SG_MAX, SG_MAXWGSG, SG_REQSTAGES, SG_N };
static long long prof_sg[SG_N];
static long long prof_size_control = -1, prof_full_subgroups = -1;
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
    for (int i = 0; i < 17; i++) prof_fc[i] = -1;
    for (int i = 0; i < SG_N; i++) prof_sg[i] = -1;
    // Every format these headers name, to read the report's format lines by name.
    static struct { VkFormat f; const char *name; } known[512]; int nknown = 0;
    for (long v = 1; v < 1001000000 && nknown < 512; v = v == 184 ? 1000000000 : v + 1) {
        const char *n = string_VkFormat((VkFormat)v);
        if (strncmp(n, "Unhandled", 9)) { known[nknown].f = (VkFormat)v; known[nknown++].name = n; }
    }
    prof_ext = calloc(1024, sizeof(char *));
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "ext ", 4)) prof_ext[prof_next++] = strdup(line + 4);
        else if (!strncmp(line, "f10 ", 4)) {
            char name[128]; unsigned v;
            if (sscanf(line + 4, "%127s %u", name, &v) == 2)
                for (int i = 0; i < 55; i++) if (!strcmp(name, f10names[i])) prof_f10[i] = v;
        } else if (!strncmp(line, "f13 subgroupSizeControl ", 24)) prof_size_control = strtoul(line + 24, NULL, 10);
        else if (!strncmp(line, "f13 computeFullSubgroups ", 25)) prof_full_subgroups = strtoul(line + 25, NULL, 10);
        else if (!strncmp(line, "fc ", 3) || !strncmp(line, "subgroup ", 9)) {
            int fc = line[0] == 'f';
            char name[128]; char val[32];
            if (sscanf(line + (fc ? 3 : 9), "%127s %31s", name, val) == 2) {
                const char **names = fc ? fcnames : sgnames;
                int n = fc ? 17 : SG_N;
                // devinfo prints stage and operation masks in hex, the rest in decimal
                int hex = !fc && (!strcmp(name, "supportedStages") || !strcmp(name, "supportedOperations") || !strcmp(name, "requiredSubgroupSizeStages"));
                for (int i = 0; i < n; i++) if (!strcmp(name, names[i])) (fc ? prof_fc : prof_sg)[i] = strtoll(val, NULL, hex ? 16 : 10);
            }
        } else if (!strncmp(line, "driver id ", 10)) { prof_driver_id = (VkDriverId)atoi(line + 10); prof_has_driver = 1; }
        else if (!strncmp(line, "driver name ", 12)) snprintf(prof_driver_name, sizeof prof_driver_name, "%.255s", line + 12);
        else if (!strncmp(line, "driver info ", 12)) snprintf(prof_driver_info, sizeof prof_driver_info, "%.255s", line + 12);
        else if (!strncmp(line, "driver conformance ", 19)) {
            unsigned a = 0, b = 0, c = 0, d = 0;
            sscanf(line + 19, "%u.%u.%u.%u", &a, &b, &c, &d);
            prof_conformance = (VkConformanceVersion){(uint8_t)a, (uint8_t)b, (uint8_t)c, (uint8_t)d};
        } else if (!strncmp(line, "format ", 7)) {
            unsigned lin, opt, buf; char name[128]; unsigned long long lin2, opt2, buf2;
            int got = sscanf(line + 7, "%127s lin=%x opt=%x buf=%x lin2=%llx opt2=%llx buf2=%llx", name, &lin, &opt, &buf, &lin2, &opt2, &buf2);
            if (got >= 4) {
                ProfFormat fp = {{lin, opt, buf}, got == 7, lin2, opt2, buf2};
                for (int i = 0; i < nknown; i++) {
                    if (strcmp(name, known[i].name)) continue;
                    if ((int)known[i].f < 185) prof_fmt[known[i].f] = fp;
                    else if (prof_nxfmt < 256) { prof_xfmt[prof_nxfmt].f = known[i].f; prof_xfmt[prof_nxfmt++].p = fp; }
                    break;
                }
            }
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
    L("profile %s: %d extensions, name '%s', driver %s %d, heap %llu, %d extension formats\n", p, prof_next, prof_name,
      prof_has_driver ? prof_driver_name : "-", prof_has_driver ? (int)prof_driver_id : -1, (unsigned long long)prof_heap, prof_nxfmt);
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
// ANDs a feature with the report's, when the report has it.
static void prof_and(VkBool32 *b, long long report) { if (report >= 0) *b = *b && report; }
static void VKAPI_CALL q_GetFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    p_GetFeatures2(pd, f); prof_mask10(&f->features);
    for (Hdr *h = (Hdr *)f->pNext; h; h = (Hdr *)h->pNext) {
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES) ((VkPhysicalDeviceVulkan11Features *)h)->storageInputOutput16 = 0;
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES) ((VkPhysicalDevice16BitStorageFeatures *)h)->storageInputOutput16 = 0;
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES) {
            VkPhysicalDeviceVulkan13Features *v = (void *)h;
            prof_and(&v->subgroupSizeControl, prof_size_control); prof_and(&v->computeFullSubgroups, prof_full_subgroups);
        }
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_FEATURES) {
            VkPhysicalDeviceSubgroupSizeControlFeatures *v = (void *)h;
            prof_and(&v->subgroupSizeControl, prof_size_control); prof_and(&v->computeFullSubgroups, prof_full_subgroups);
        }
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

// The narrower of two float-controls independences (NONE < 32_BIT_ONLY < ALL).
static VkShaderFloatControlsIndependence prof_indep(VkShaderFloatControlsIndependence desk, long long report) {
    if (report < 0) return desk;
    static const int rank[] = {[VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_32_BIT_ONLY] = 1, [VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_ALL] = 2,
                               [VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_NONE] = 0};
    if (report > 2 || (unsigned)desk > 2) return desk;
    return rank[report] < rank[desk] ? (VkShaderFloatControlsIndependence)report : desk;
}
// One body for VkPhysicalDeviceVulkan12Properties and VkPhysicalDeviceFloatControlsProperties.
#define PROF_FLOAT_CONTROLS(q) do { \
    q->denormBehaviorIndependence = prof_indep(q->denormBehaviorIndependence, prof_fc[0]); \
    q->roundingModeIndependence = prof_indep(q->roundingModeIndependence, prof_fc[1]); \
    VkBool32 *b_[15] = {&q->shaderSignedZeroInfNanPreserveFloat16, &q->shaderSignedZeroInfNanPreserveFloat32, &q->shaderSignedZeroInfNanPreserveFloat64, \
        &q->shaderDenormPreserveFloat16, &q->shaderDenormPreserveFloat32, &q->shaderDenormPreserveFloat64, \
        &q->shaderDenormFlushToZeroFloat16, &q->shaderDenormFlushToZeroFloat32, &q->shaderDenormFlushToZeroFloat64, \
        &q->shaderRoundingModeRTEFloat16, &q->shaderRoundingModeRTEFloat32, &q->shaderRoundingModeRTEFloat64, \
        &q->shaderRoundingModeRTZFloat16, &q->shaderRoundingModeRTZFloat32, &q->shaderRoundingModeRTZFloat64}; \
    for (int i_ = 0; i_ < 15; i_++) prof_and(b_[i_], prof_fc[2 + i_]); } while (0)
#define PROF_DRIVER(q) do { if (prof_has_driver && getenv("PP_CAPTURE_SPOOF")) { \
    q->driverID = prof_driver_id; q->conformanceVersion = prof_conformance; \
    snprintf(q->driverName, sizeof q->driverName, "%s", prof_driver_name); \
    snprintf(q->driverInfo, sizeof q->driverInfo, "%s", prof_driver_info); } } while (0)
// The report's subgroup size, when the desktop can run at it (min..max).
static void prof_subgroup_size(uint32_t *size, uint32_t min, uint32_t max) {
    if (prof_sg[SG_SIZE] >= min && prof_sg[SG_SIZE] <= max) *size = (uint32_t)prof_sg[SG_SIZE];
}
static void prof_mask32(uint32_t *v, long long report) { if (report >= 0) *v &= (uint32_t)report; }
// The report's size range, narrowed to the desktop's; left as the desktop's when they do not meet.
static void prof_size_range(uint32_t *min, uint32_t *max) {
    long long lo = prof_sg[SG_MIN], hi = prof_sg[SG_MAX];
    if (lo < 0 || hi < 0) return;
    if (lo < *min) lo = *min;
    if (hi > *max) hi = *max;
    if (lo <= hi) { *min = (uint32_t)lo; *max = (uint32_t)hi; }
}
static void VKAPI_CALL q_GetProps2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    p_GetProps2(pd, p); prof_limits(&p->properties);
    // The desktop's size range first: the subgroup size must stay inside it.
    VkPhysicalDeviceSubgroupSizeControlProperties desk = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_PROPERTIES};
    VkPhysicalDeviceProperties2 dp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &desk};
    p_GetProps2(pd, &dp);
    uint32_t lo = desk.minSubgroupSize, hi = desk.maxSubgroupSize;
    prof_size_range(&lo, &hi);
    for (Hdr *h = (Hdr *)p->pNext; h; h = (Hdr *)h->pNext) {
        switch (h->sType) {
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES: {
            VkPhysicalDeviceVulkan11Properties *q = (void *)h;
            prof_subgroup_size(&q->subgroupSize, lo, hi);
            prof_mask32(&q->subgroupSupportedStages, prof_sg[SG_STAGES]); prof_mask32(&q->subgroupSupportedOperations, prof_sg[SG_OPS]);
            prof_and(&q->subgroupQuadOperationsInAllStages, prof_sg[SG_QUAD]);
            break;
        }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES: {
            VkPhysicalDeviceSubgroupProperties *q = (void *)h;
            prof_subgroup_size(&q->subgroupSize, lo, hi);
            prof_mask32(&q->supportedStages, prof_sg[SG_STAGES]); prof_mask32(&q->supportedOperations, prof_sg[SG_OPS]);
            prof_and(&q->quadOperationsInAllStages, prof_sg[SG_QUAD]);
            break;
        }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES: { VkPhysicalDeviceVulkan12Properties *q = (void *)h; PROF_FLOAT_CONTROLS(q); PROF_DRIVER(q); break; }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES: { VkPhysicalDeviceFloatControlsProperties *q = (void *)h; PROF_FLOAT_CONTROLS(q); break; }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES: { VkPhysicalDeviceDriverProperties *q = (void *)h; PROF_DRIVER(q); break; }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES: {
            VkPhysicalDeviceVulkan13Properties *q = (void *)h;
            q->minSubgroupSize = lo; q->maxSubgroupSize = hi;
            if (prof_sg[SG_MAXWGSG] >= 0 && prof_sg[SG_MAXWGSG] < q->maxComputeWorkgroupSubgroups) q->maxComputeWorkgroupSubgroups = (uint32_t)prof_sg[SG_MAXWGSG];
            prof_mask32(&q->requiredSubgroupSizeStages, prof_sg[SG_REQSTAGES]);
            break;
        }
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_PROPERTIES: {
            VkPhysicalDeviceSubgroupSizeControlProperties *q = (void *)h;
            q->minSubgroupSize = lo; q->maxSubgroupSize = hi;
            if (prof_sg[SG_MAXWGSG] >= 0 && prof_sg[SG_MAXWGSG] < q->maxComputeWorkgroupSubgroups) q->maxComputeWorkgroupSubgroups = (uint32_t)prof_sg[SG_MAXWGSG];
            prof_mask32(&q->requiredSubgroupSizeStages, prof_sg[SG_REQSTAGES]);
            break;
        }
        default: break;
        }
    }
}

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

// The report's features of a format: a core one's line, an extension one's
// line or none at all; NULL for VK_FORMAT_UNDEFINED, left as the driver says.
static const ProfFormat *prof_format(VkFormat f) {
    static const ProfFormat none = {{0, 0, 0}, 1, 0, 0, 0};
    if ((int)f <= 0) return NULL;
    if ((int)f < 185) return &prof_fmt[f];
    for (int i = 0; i < prof_nxfmt; i++) if (prof_xfmt[i].f == f) return &prof_xfmt[i].p;
    return &none;
}
static void prof_fmtmask(VkFormat f, VkFormatProperties *p) {
    const ProfFormat *r = prof_format(f);
    if (!r) return;
    p->linearTilingFeatures &= r->p.linearTilingFeatures;
    p->optimalTilingFeatures &= r->p.optimalTilingFeatures;
    p->bufferFeatures &= r->p.bufferFeatures;
}
// VkFormatProperties3: ANDed with the report's flags2; from a report without
// them, its 32 bits ANDed and the bits from 31 up (no VkFormatFeatureFlags
// equivalent) kept, unless the report has no feature at all.
static void prof_fmtmask2(VkFormatFeatureFlags2 *v, int has2, VkFormatFeatureFlags2 r2, VkFormatFeatureFlags r) {
    if (has2) *v &= r2;
    else *v = r ? *v & ((VkFormatFeatureFlags2)r | ~(VkFormatFeatureFlags2)0x7fffffff) : 0;
}
static void VKAPI_CALL q_GetFmt(VkPhysicalDevice pd, VkFormat f, VkFormatProperties *p) { p_GetFmt(pd, f, p); prof_fmtmask(f, p); }
static void VKAPI_CALL q_GetFmt2(VkPhysicalDevice pd, VkFormat f, VkFormatProperties2 *p) {
    p_GetFmt2(pd, f, p); prof_fmtmask(f, &p->formatProperties);
    const ProfFormat *r = prof_format(f);
    for (Hdr *h = (Hdr *)p->pNext; r && h; h = (Hdr *)h->pNext)
        if (h->sType == VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3) {
            VkFormatProperties3 *q = (void *)h;
            prof_fmtmask2(&q->linearTilingFeatures, r->has2, r->lin2, r->p.linearTilingFeatures);
            prof_fmtmask2(&q->optimalTilingFeatures, r->has2, r->opt2, r->p.optimalTilingFeatures);
            prof_fmtmask2(&q->bufferFeatures, r->has2, r->buf2, r->p.bufferFeatures);
        }
}

static uint32_t usage_feats(VkImageUsageFlags u) {
    uint32_t r = 0;
    if (u & VK_IMAGE_USAGE_SAMPLED_BIT) r |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
    if (u & VK_IMAGE_USAGE_STORAGE_BIT) r |= VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT;
    if (u & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) r |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT;
    if (u & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) r |= VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    return r;
}
static VkResult prof_imgfmt(VkFormat f, VkImageTiling t, VkImageUsageFlags u, VkImageFormatProperties *p) {
    const ProfFormat *r = prof_format(f);
    if (r) {
        uint32_t have = t == VK_IMAGE_TILING_LINEAR ? r->p.linearTilingFeatures : r->p.optimalTilingFeatures;
        uint32_t need = usage_feats(u);
        if ((have & need) != need || !have) return VK_ERROR_FORMAT_NOT_SUPPORTED;
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
