/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A Linux implicit Vulkan layer for measuring what an application asks of a
 * driver: it logs instance and device create infos (extensions, features,
 * feature chains), images, views, samplers, descriptor set and pipeline
 * layouts, query pools, render passes, graphics and compute pipelines,
 * memory allocations and some command counts, and saves every shader
 * module's SPIR-V by its FNV-1a hash. With PP_CAPTURE_PROFILE it also
 * presents the device as another one (profile.c). A workstation tool; not
 * shipped.
 *
 *    PP_CAPTURE_OUT     directory for capture.PID.log and spv/ (default .)
 *    PP_CAPTURE_GDPA=1  also log every vkGetDeviceProcAddr lookup
 *    PP_CAPTURE_LINEAR=1  log how linear images are bound, mapped and used (linear.c)
 *    PP_CAPTURE_MEMUSE=N  memory, copy and present counters per device (memuse.c)
 *
 * The manifest, capture.json, enables it with ENABLE_PP_CAPTURE=1.
 */
#define _GNU_SOURCE
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <vulkan/vk_enum_string_helper.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *logf_;
static char outdir[1024];
static PFN_vkGetInstanceProcAddr next_gipa;
static PFN_vkGetDeviceProcAddr next_gdpa;
static VkInstance g_inst;
static VkDevice g_dev;

static void openlog_(void) {
    if (logf_) return;
    const char *d = getenv("PP_CAPTURE_OUT");
    snprintf(outdir, sizeof outdir, "%s", d ? d : ".");
    mkdir(outdir, 0755);
    char p[1200];
    snprintf(p, sizeof p, "%s/spv", outdir); mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/capture.%d.log", outdir, (int)getpid());
    logf_ = fopen(p, "a");
    setvbuf(logf_, NULL, _IOLBF, 0);
}
#define L(...) do { pthread_mutex_lock(&mu); openlog_(); fprintf(logf_, __VA_ARGS__); pthread_mutex_unlock(&mu); } while (0)

typedef struct { VkStructureType sType; const void *pNext; } Hdr;

// A generic pNext dump: sType name, and every 32-bit word after the header
// (feature structs are VkBool32 arrays; others are logged raw for offline decode).
static void dump_chain(const char *what, const void *p) {
    for (const Hdr *h = p; h; h = h->pNext) {
        pthread_mutex_lock(&mu); openlog_();
        fprintf(logf_, "%s pNext %s (%d)", what, string_VkStructureType(h->sType), (int)h->sType);
        size_t n = 0;
        switch (h->sType) {
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: n = sizeof(VkPhysicalDeviceFeatures) / 4; break;
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES: n = (sizeof(VkPhysicalDeviceVulkan11Features) - 16) / 4; break;
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES: n = (sizeof(VkPhysicalDeviceVulkan12Features) - 16) / 4; break;
        case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES: n = (sizeof(VkPhysicalDeviceVulkan13Features) - 16) / 4; break;
        default: n = 8; break; // most single-extension feature structs are short
        }
        const uint32_t *w = (const uint32_t *)((const char *)h + 16);
        if (h->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) w = (const uint32_t *)&((const VkPhysicalDeviceFeatures2 *)h)->features;
        fprintf(logf_, " words=");
        for (size_t i = 0; i < n; i++) fprintf(logf_, "%s%u", i ? "," : "", w[i]);
        fprintf(logf_, "\n");
        pthread_mutex_unlock(&mu);
    }
}

static void dump_features10(const char *what, const VkPhysicalDeviceFeatures *f) {
    if (!f) return;
    const uint32_t *w = (const uint32_t *)f;
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "%s features10 words=", what);
    for (size_t i = 0; i < sizeof(*f) / 4; i++) fprintf(logf_, "%s%u", i ? "," : "", w[i]);
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
}

#include "profile.c"
#include "linear.c"
#include "memuse.c"

/* ---------------- instance ---------------- */
static PFN_vkCreateInstance n_CreateInstance;
static PFN_vkDestroyInstance n_DestroyInstance;
static PFN_vkCreateDevice n_CreateDevice;
static PFN_vkEnumerateDeviceExtensionProperties n_EnumDevExt;
static PFN_vkGetPhysicalDeviceProperties n_GetPDProps;

static VkResult VKAPI_CALL c_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *out) {
    VkLayerInstanceCreateInfo *li = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO))
        li = (VkLayerInstanceCreateInfo *)li->pNext;
    if (!li) return VK_ERROR_INITIALIZATION_FAILED;
    next_gipa = li->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    li->u.pLayerInfo = li->u.pLayerInfo->pNext;
    n_CreateInstance = (PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance");
    const VkApplicationInfo *ai = ci->pApplicationInfo;
    L("instance app=%s appver=%u engine=%s enginever=%u api=%u.%u.%u\n",
      ai && ai->pApplicationName ? ai->pApplicationName : "-", ai ? ai->applicationVersion : 0,
      ai && ai->pEngineName ? ai->pEngineName : "-", ai ? ai->engineVersion : 0,
      ai ? VK_API_VERSION_MAJOR(ai->apiVersion) : 0, ai ? VK_API_VERSION_MINOR(ai->apiVersion) : 0, ai ? VK_API_VERSION_PATCH(ai->apiVersion) : 0);
    for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) L("instance ext %s\n", ci->ppEnabledExtensionNames[i]);
    for (uint32_t i = 0; i < ci->enabledLayerCount; i++) L("instance layer %s\n", ci->ppEnabledLayerNames[i]);
    VkResult r = n_CreateInstance(ci, a, out);
    if (r == VK_SUCCESS) {
        g_inst = *out;
        prof_load(); prof_resolve(*out);
        n_DestroyInstance = (PFN_vkDestroyInstance)next_gipa(*out, "vkDestroyInstance");
        n_CreateDevice = (PFN_vkCreateDevice)next_gipa(*out, "vkCreateDevice");
        n_EnumDevExt = (PFN_vkEnumerateDeviceExtensionProperties)next_gipa(*out, "vkEnumerateDeviceExtensionProperties");
        n_GetPDProps = (PFN_vkGetPhysicalDeviceProperties)next_gipa(*out, "vkGetPhysicalDeviceProperties");
    }
    L("instance result %d\n", r);
    return r;
}

static void VKAPI_CALL c_DestroyInstance(VkInstance i, const VkAllocationCallbacks *a) { L("instance destroy\n"); n_DestroyInstance(i, a); }

/* ---------------- device-level next pointers ---------------- */
#define DEVFNS(X) \
    X(DestroyDevice) X(CreateShaderModule) X(CreateGraphicsPipelines) X(CreateComputePipelines) \
    X(CreateImage) X(CreateImageView) X(CreateSampler) X(CreateDescriptorSetLayout) X(CreateQueryPool) \
    X(CreateRenderPass) X(CreateRenderPass2) X(AllocateMemory) X(CreateBuffer) X(CreatePipelineLayout) \
    X(CmdDrawIndirect) X(CmdDrawIndexedIndirect) X(CmdDrawIndirectCount) X(CmdDrawIndexedIndirectCount) \
    X(CmdSetDepthBounds) X(CmdDispatchBase) X(CmdBeginQuery) X(CmdResolveImage) X(CmdBlitImage) \
    X(CmdPushDescriptorSetKHR) X(CmdBeginRenderPass) X(CreateSwapchainKHR) X(CreateDescriptorPool) \
    X(CmdDispatchIndirect) X(CmdFillBuffer) X(CmdCopyQueryPoolResults) X(CmdClearAttachments) \
    X(DestroyImage) X(DestroyImageView) X(DestroyBuffer) X(FreeMemory) X(BindImageMemory) X(BindImageMemory2) \
    X(BindBufferMemory) X(BindBufferMemory2) X(MapMemory) X(UnmapMemory) X(FlushMappedMemoryRanges) \
    X(InvalidateMappedMemoryRanges) X(GetImageSubresourceLayout) X(CmdCopyBufferToImage) X(CmdCopyImageToBuffer) \
    X(CmdCopyImage) X(CmdClearColorImage) X(CmdPipelineBarrier) X(CmdWaitEvents) X(CmdExecuteCommands) \
    X(BeginCommandBuffer) X(QueueSubmit) X(QueuePresentKHR) X(UpdateDescriptorSets) X(CreateDescriptorUpdateTemplate) \
    X(DestroyDescriptorUpdateTemplate) X(UpdateDescriptorSetWithTemplate) X(CreateFramebuffer) X(DestroyFramebuffer) \
    X(CmdCopyBuffer) X(CmdUpdateBuffer)
#define DECL(n) static PFN_vk##n n_##n;
DEVFNS(DECL)

static volatile long cnt_indirect_multi, cnt_indirect, cnt_indcount, cnt_depthbounds, cnt_dispatchbase, cnt_pushdesc,
    cnt_query_precise, cnt_resolve, cnt_blit, cnt_rp, cnt_dispatchind, cnt_fill, cnt_copyq, cnt_clearatt;

static void stats(void) {
    L("cmdstats indirect=%ld indirect_multi(drawCount>1)=%ld indirectCount=%ld depthBounds=%ld dispatchBase=%ld pushDescriptor=%ld preciseQuery=%ld resolve=%ld blit=%ld renderPasses=%ld dispatchIndirect=%ld fill=%ld copyQuery=%ld clearAtt=%ld\n",
      cnt_indirect, cnt_indirect_multi, cnt_indcount, cnt_depthbounds, cnt_dispatchbase, cnt_pushdesc, cnt_query_precise, cnt_resolve,
      cnt_blit, cnt_rp, cnt_dispatchind, cnt_fill, cnt_copyq, cnt_clearatt);
}

static VkResult VKAPI_CALL c_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *out) {
    VkLayerDeviceCreateInfo *li = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO))
        li = (VkLayerDeviceCreateInfo *)li->pNext;
    if (!li) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = li->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    next_gdpa = li->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    li->u.pLayerInfo = li->u.pLayerInfo->pNext;
    PFN_vkCreateDevice cd = (PFN_vkCreateDevice)gipa(g_inst, "vkCreateDevice");
    VkPhysicalDeviceProperties pp; n_GetPDProps(pd, &pp);
    L("device on %s api=%u.%u.%u\n", pp.deviceName, VK_API_VERSION_MAJOR(pp.apiVersion), VK_API_VERSION_MINOR(pp.apiVersion), VK_API_VERSION_PATCH(pp.apiVersion));
    for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) L("device ext %s\n", ci->ppEnabledExtensionNames[i]);
    for (uint32_t i = 0; i < ci->queueCreateInfoCount; i++)
        L("device queue family=%u count=%u flags=%u\n", ci->pQueueCreateInfos[i].queueFamilyIndex, ci->pQueueCreateInfos[i].queueCount, ci->pQueueCreateInfos[i].flags);
    dump_features10("device", ci->pEnabledFeatures);
    dump_chain("device", ci->pNext);
    VkResult r = cd(pd, ci, a, out);
    L("device result %d\n", r);
    if (r == VK_SUCCESS) {
        g_dev = *out;
        prof_resolve_dev(*out);
        prof_device_created(pd, *out);
        mu_device_created(*out);
#define LOAD(n) n_##n = (PFN_vk##n)next_gdpa(*out, "vk" #n);
        DEVFNS(LOAD)
    }
    return r;
}

static void VKAPI_CALL c_DestroyDevice(VkDevice d, const VkAllocationCallbacks *a) { stats(); lin_device_destroyed(d); mu_device_destroyed(d); L("device destroy\n"); prof_device_destroyed(d); n_DestroyDevice(d, a); }

static uint64_t fnv(const void *p, size_t n) {
    const unsigned char *c = p; uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= c[i]; h *= 1099511628211ull; }
    return h;
}

static VkResult VKAPI_CALL c_CreateShaderModule(VkDevice d, const VkShaderModuleCreateInfo *ci, const VkAllocationCallbacks *a, VkShaderModule *out) {
    uint64_t h = fnv(ci->pCode, ci->codeSize);
    char p[1200];
    pthread_mutex_lock(&mu); openlog_();
    snprintf(p, sizeof p, "%s/spv/%016llx.spv", outdir, (unsigned long long)h);
    struct stat st;
    if (stat(p, &st) != 0) { FILE *f = fopen(p, "wb"); if (f) { fwrite(ci->pCode, 1, ci->codeSize, f); fclose(f); } }
    pthread_mutex_unlock(&mu);
    VkResult r = n_CreateShaderModule(d, ci, a, out);
    L("shader %016llx size=%zu result=%d module=%llx\n", (unsigned long long)h, ci->codeSize, r, (unsigned long long)(uintptr_t)*out);
    if (ci->pNext) dump_chain("shader", ci->pNext);
    return r;
}

static VkResult VKAPI_CALL c_CreateGraphicsPipelines(VkDevice d, VkPipelineCache c, uint32_t n, const VkGraphicsPipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out) {
    for (uint32_t i = 0; i < n; i++) {
        const VkGraphicsPipelineCreateInfo *g = &ci[i];
        pthread_mutex_lock(&mu); openlog_();
        fprintf(logf_, "gpipe flags=%x stages=", g->flags);
        for (uint32_t s = 0; s < g->stageCount; s++)
            fprintf(logf_, "%s%x:%llx:%s%s", s ? "," : "", g->pStages[s].stage, (unsigned long long)(uintptr_t)g->pStages[s].module,
                    g->pStages[s].pName, g->pStages[s].pSpecializationInfo ? "+spec" : "");
        if (g->pInputAssemblyState) fprintf(logf_, " topo=%d restart=%d", g->pInputAssemblyState->topology, g->pInputAssemblyState->primitiveRestartEnable);
        if (g->pTessellationState) fprintf(logf_, " patchcp=%u", g->pTessellationState->patchControlPoints);
        if (g->pVertexInputState) {
            fprintf(logf_, " vfmt=");
            for (uint32_t k = 0; k < g->pVertexInputState->vertexAttributeDescriptionCount; k++)
                fprintf(logf_, "%s%d", k ? "," : "", g->pVertexInputState->pVertexAttributeDescriptions[k].format);
            for (uint32_t k = 0; k < g->pVertexInputState->vertexBindingDescriptionCount; k++)
                if (g->pVertexInputState->pVertexBindingDescriptions[k].inputRate) fprintf(logf_, " instrate");
            if (g->pVertexInputState->pNext) fprintf(logf_, " vi_pnext=%d", ((const Hdr *)g->pVertexInputState->pNext)->sType);
        }
        const VkPipelineRasterizationStateCreateInfo *rs = g->pRasterizationState;
        if (rs) {
            fprintf(logf_, " clamp=%d discard=%d poly=%d cull=%d dbias=%d lw=%.1f", rs->depthClampEnable, rs->rasterizerDiscardEnable, rs->polygonMode, rs->cullMode, rs->depthBiasEnable, rs->lineWidth);
            for (const Hdr *h = rs->pNext; h; h = h->pNext) fprintf(logf_, " rs_pnext=%d", h->sType);
        }
        const VkPipelineMultisampleStateCreateInfo *ms = g->pMultisampleState;
        if (ms) fprintf(logf_, " samples=%d sshade=%d minss=%.2f a2c=%d a2o=%d mask=%d", ms->rasterizationSamples, ms->sampleShadingEnable, ms->minSampleShading, ms->alphaToCoverageEnable, ms->alphaToOneEnable, ms->pSampleMask != NULL);
        const VkPipelineDepthStencilStateCreateInfo *ds = g->pDepthStencilState;
        if (ds) fprintf(logf_, " dt=%d dw=%d dop=%d bounds=%d st=%d", ds->depthTestEnable, ds->depthWriteEnable, ds->depthCompareOp, ds->depthBoundsTestEnable, ds->stencilTestEnable);
        const VkPipelineColorBlendStateCreateInfo *cb = g->pColorBlendState;
        if (cb) {
            fprintf(logf_, " logic=%d/%d att=%u blend=", cb->logicOpEnable, cb->logicOp, cb->attachmentCount);
            for (uint32_t k = 0; k < cb->attachmentCount; k++) {
                const VkPipelineColorBlendAttachmentState *b = &cb->pAttachments[k];
                fprintf(logf_, "%s%d:%d/%d/%d:%d/%d/%d:%x", k ? "," : "", b->blendEnable, b->srcColorBlendFactor, b->dstColorBlendFactor, b->colorBlendOp,
                        b->srcAlphaBlendFactor, b->dstAlphaBlendFactor, b->alphaBlendOp, b->colorWriteMask);
            }
        }
        if (g->pDynamicState) {
            fprintf(logf_, " dyn=");
            for (uint32_t k = 0; k < g->pDynamicState->dynamicStateCount; k++) fprintf(logf_, "%s%d", k ? "," : "", g->pDynamicState->pDynamicStates[k]);
        }
        if (g->pViewportState) fprintf(logf_, " vp=%u sc=%u", g->pViewportState->viewportCount, g->pViewportState->scissorCount);
        fprintf(logf_, " rp=%llx sub=%u", (unsigned long long)(uintptr_t)g->renderPass, g->subpass);
        for (const Hdr *h = g->pNext; h; h = h->pNext) fprintf(logf_, " pnext=%d", h->sType);
        fprintf(logf_, "\n");
        pthread_mutex_unlock(&mu);
    }
    VkResult r = n_CreateGraphicsPipelines(d, c, n, ci, a, out);
    if (r != VK_SUCCESS) L("gpipe result %d\n", r);
    return r;
}

static VkResult VKAPI_CALL c_CreateComputePipelines(VkDevice d, VkPipelineCache c, uint32_t n, const VkComputePipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *out) {
    for (uint32_t i = 0; i < n; i++)
        L("cpipe flags=%x module=%llx entry=%s spec=%d sflags=%x pnext=%d\n", ci[i].flags, (unsigned long long)(uintptr_t)ci[i].stage.module, ci[i].stage.pName,
          ci[i].stage.pSpecializationInfo != NULL, ci[i].stage.flags, ci[i].stage.pNext ? ((const Hdr *)ci[i].stage.pNext)->sType : 0);
    VkResult r = n_CreateComputePipelines(d, c, n, ci, a, out);
    if (r != VK_SUCCESS) L("cpipe result %d\n", r);
    return r;
}

static VkResult VKAPI_CALL c_CreateImage(VkDevice d, const VkImageCreateInfo *ci, const VkAllocationCallbacks *a, VkImage *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "image type=%d fmt=%s %ux%ux%u mips=%u layers=%u samples=%d tiling=%d usage=%x flags=%x share=%d",
            ci->imageType, string_VkFormat(ci->format), ci->extent.width, ci->extent.height, ci->extent.depth, ci->mipLevels, ci->arrayLayers,
            ci->samples, ci->tiling, ci->usage, ci->flags, ci->sharingMode);
    for (const Hdr *h = ci->pNext; h; h = h->pNext) {
        fprintf(logf_, " pnext=%d", h->sType);
        if (h->sType == VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO) {
            const VkImageFormatListCreateInfo *fl = (const void *)h;
            for (uint32_t k = 0; k < fl->viewFormatCount; k++) fprintf(logf_, "%s%s", k ? "," : ":", string_VkFormat(fl->pViewFormats[k]));
        }
    }
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    VkResult r = n_CreateImage(d, ci, a, out);
    if (r != VK_SUCCESS) L("image result %d\n", r);
    else { lin_image_created(d, ci, *out); mu_image_created(d, ci, *out); }
    return r;
}

static VkResult VKAPI_CALL c_CreateImageView(VkDevice d, const VkImageViewCreateInfo *ci, const VkAllocationCallbacks *a, VkImageView *out) {
    L("view type=%d fmt=%s swz=%d%d%d%d aspect=%x pnext=%d\n", ci->viewType, string_VkFormat(ci->format), ci->components.r, ci->components.g, ci->components.b, ci->components.a,
      ci->subresourceRange.aspectMask, ci->pNext ? ((const Hdr *)ci->pNext)->sType : 0);
    VkResult r = n_CreateImageView(d, ci, a, out);
    if (r == VK_SUCCESS) lin_view_created(ci, *out);
    return r;
}

static VkResult VKAPI_CALL c_CreateSampler(VkDevice d, const VkSamplerCreateInfo *ci, const VkAllocationCallbacks *a, VkSampler *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "sampler mag=%d min=%d mip=%d addr=%d,%d,%d bias=%.2f aniso=%d/%.0f cmp=%d/%d lod=%.1f..%.1f border=%d unnorm=%d",
            ci->magFilter, ci->minFilter, ci->mipmapMode, ci->addressModeU, ci->addressModeV, ci->addressModeW, ci->mipLodBias, ci->anisotropyEnable,
            ci->maxAnisotropy, ci->compareEnable, ci->compareOp, ci->minLod, ci->maxLod, ci->borderColor, ci->unnormalizedCoordinates);
    for (const Hdr *h = ci->pNext; h; h = h->pNext) fprintf(logf_, " pnext=%d", h->sType);
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    return n_CreateSampler(d, ci, a, out);
}

static VkResult VKAPI_CALL c_CreateDescriptorSetLayout(VkDevice d, const VkDescriptorSetLayoutCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorSetLayout *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "dsl flags=%x n=%u b=", ci->flags, ci->bindingCount);
    for (uint32_t k = 0; k < ci->bindingCount; k++)
        fprintf(logf_, "%s%u:%d:%u:%x%s", k ? "," : "", ci->pBindings[k].binding, ci->pBindings[k].descriptorType, ci->pBindings[k].descriptorCount,
                ci->pBindings[k].stageFlags, ci->pBindings[k].pImmutableSamplers ? ":imm" : "");
    for (const Hdr *h = ci->pNext; h; h = h->pNext) {
        fprintf(logf_, " pnext=%d", h->sType);
        if (h->sType == VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO) {
            const VkDescriptorSetLayoutBindingFlagsCreateInfo *bf = (const void *)h;
            for (uint32_t k = 0; k < bf->bindingCount; k++) fprintf(logf_, "%s%x", k ? "," : ":", bf->pBindingFlags[k]);
        }
    }
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    return n_CreateDescriptorSetLayout(d, ci, a, out);
}

static VkResult VKAPI_CALL c_CreatePipelineLayout(VkDevice d, const VkPipelineLayoutCreateInfo *ci, const VkAllocationCallbacks *a, VkPipelineLayout *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "playout sets=%u push=", ci->setLayoutCount);
    for (uint32_t k = 0; k < ci->pushConstantRangeCount; k++) fprintf(logf_, "%s%x:%u+%u", k ? "," : "", ci->pPushConstantRanges[k].stageFlags, ci->pPushConstantRanges[k].offset, ci->pPushConstantRanges[k].size);
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    return n_CreatePipelineLayout(d, ci, a, out);
}

static VkResult VKAPI_CALL c_CreateDescriptorPool(VkDevice d, const VkDescriptorPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorPool *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "dpool flags=%x max=%u sizes=", ci->flags, ci->maxSets);
    for (uint32_t k = 0; k < ci->poolSizeCount; k++) fprintf(logf_, "%s%d:%u", k ? "," : "", ci->pPoolSizes[k].type, ci->pPoolSizes[k].descriptorCount);
    for (const Hdr *h = ci->pNext; h; h = h->pNext) fprintf(logf_, " pnext=%d", h->sType);
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    return n_CreateDescriptorPool(d, ci, a, out);
}

static VkResult VKAPI_CALL c_CreateQueryPool(VkDevice d, const VkQueryPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkQueryPool *out) {
    L("querypool type=%d count=%u stats=%x\n", ci->queryType, ci->queryCount, ci->pipelineStatistics);
    return n_CreateQueryPool(d, ci, a, out);
}

static VkResult VKAPI_CALL c_CreateRenderPass(VkDevice d, const VkRenderPassCreateInfo *ci, const VkAllocationCallbacks *a, VkRenderPass *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "renderpass att=");
    for (uint32_t k = 0; k < ci->attachmentCount; k++) fprintf(logf_, "%s%s/%d/%d%d", k ? "," : "", string_VkFormat(ci->pAttachments[k].format), ci->pAttachments[k].samples, ci->pAttachments[k].loadOp, ci->pAttachments[k].storeOp);
    fprintf(logf_, " subpasses=%u deps=%u", ci->subpassCount, ci->dependencyCount);
    for (uint32_t s = 0; s < ci->subpassCount; s++) {
        const VkSubpassDescription *sp = &ci->pSubpasses[s];
        fprintf(logf_, " sp%u:in=%u col=%u res=%d ds=%d", s, sp->inputAttachmentCount, sp->colorAttachmentCount, sp->pResolveAttachments != NULL, sp->pDepthStencilAttachment != NULL);
    }
    for (const Hdr *h = ci->pNext; h; h = h->pNext) fprintf(logf_, " pnext=%d", h->sType);
    fprintf(logf_, " -> %p\n", (void *)out);
    pthread_mutex_unlock(&mu);
    VkResult r = n_CreateRenderPass(d, ci, a, out);
    L("renderpass handle=%llx\n", (unsigned long long)(uintptr_t)*out);
    return r;
}

static VkResult VKAPI_CALL c_CreateRenderPass2(VkDevice d, const VkRenderPassCreateInfo2 *ci, const VkAllocationCallbacks *a, VkRenderPass *out) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "renderpass2 att=");
    for (uint32_t k = 0; k < ci->attachmentCount; k++) fprintf(logf_, "%s%s/%d", k ? "," : "", string_VkFormat(ci->pAttachments[k].format), ci->pAttachments[k].samples);
    fprintf(logf_, " subpasses=%u\n", ci->subpassCount);
    pthread_mutex_unlock(&mu);
    return n_CreateRenderPass2(d, ci, a, out);
}

static VkResult VKAPI_CALL c_AllocateMemory(VkDevice d, const VkMemoryAllocateInfo *ai, const VkAllocationCallbacks *a, VkDeviceMemory *m) {
    pthread_mutex_lock(&mu); openlog_();
    fprintf(logf_, "alloc type=%u size=%llu", ai->memoryTypeIndex, (unsigned long long)ai->allocationSize);
    for (const Hdr *h = ai->pNext; h; h = h->pNext) fprintf(logf_, " pnext=%d", h->sType);
    fprintf(logf_, "\n");
    pthread_mutex_unlock(&mu);
    VkMemoryAllocateInfo tai = *ai;
    uint32_t standin = prof_memtype_dev(d);
    if (standin != UINT32_MAX) tai.memoryTypeIndex = standin;
    VkResult r = n_AllocateMemory(d, &tai, a, m);
    if (r != VK_SUCCESS) L("alloc result %d\n", r);
    else { lin_mem_allocated(ai, tai.memoryTypeIndex, *m); mu_allocated(d, ai, *m); }
    return r;
}

static VkResult VKAPI_CALL c_CreateBuffer(VkDevice d, const VkBufferCreateInfo *ci, const VkAllocationCallbacks *a, VkBuffer *b) {
    L("buffer size=%llu usage=%x flags=%x\n", (unsigned long long)ci->size, ci->usage, ci->flags);
    VkResult r = n_CreateBuffer(d, ci, a, b);
    if (r == VK_SUCCESS) mu_buffer_created(d, ci, *b);
    return r;
}

static VkResult VKAPI_CALL c_CreateSwapchainKHR(VkDevice d, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSwapchainKHR *s) {
    L("swapchain fmt=%s cs=%d %ux%u images=%u usage=%x present=%d flags=%x\n", string_VkFormat(ci->imageFormat), ci->imageColorSpace, ci->imageExtent.width, ci->imageExtent.height,
      ci->minImageCount, ci->imageUsage, ci->presentMode, ci->flags);
    return n_CreateSwapchainKHR(d, ci, a, s);
}

static void VKAPI_CALL c_CmdDrawIndirect(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t s) { cnt_indirect++; if (n > 1) cnt_indirect_multi++; n_CmdDrawIndirect(c, b, o, n, s); }
static void VKAPI_CALL c_CmdDrawIndexedIndirect(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t s) { cnt_indirect++; if (n > 1) cnt_indirect_multi++; n_CmdDrawIndexedIndirect(c, b, o, n, s); }
static void VKAPI_CALL c_CmdDrawIndirectCount(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, VkBuffer cb, VkDeviceSize co, uint32_t n, uint32_t s) { cnt_indcount++; n_CmdDrawIndirectCount(c, b, o, cb, co, n, s); }
static void VKAPI_CALL c_CmdDrawIndexedIndirectCount(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, VkBuffer cb, VkDeviceSize co, uint32_t n, uint32_t s) { cnt_indcount++; n_CmdDrawIndexedIndirectCount(c, b, o, cb, co, n, s); }
static void VKAPI_CALL c_CmdSetDepthBounds(VkCommandBuffer c, float a, float b) { cnt_depthbounds++; n_CmdSetDepthBounds(c, a, b); }
static void VKAPI_CALL c_CmdDispatchBase(VkCommandBuffer c, uint32_t a, uint32_t b, uint32_t d, uint32_t x, uint32_t y, uint32_t z) { cnt_dispatchbase++; n_CmdDispatchBase(c, a, b, d, x, y, z); }
static void VKAPI_CALL c_CmdBeginQuery(VkCommandBuffer c, VkQueryPool p, uint32_t q, VkQueryControlFlags f) { if (f & VK_QUERY_CONTROL_PRECISE_BIT) cnt_query_precise++; n_CmdBeginQuery(c, p, q, f); }
static void VKAPI_CALL c_CmdResolveImage(VkCommandBuffer c, VkImage s, VkImageLayout sl, VkImage d, VkImageLayout dl, uint32_t n, const VkImageResolve *r) { cnt_resolve++; LIN_CMD(c, s, 0, res_src); LIN_CMD(c, d, 1, res_dst); n_CmdResolveImage(c, s, sl, d, dl, n, r); }
static void VKAPI_CALL c_CmdBlitImage(VkCommandBuffer c, VkImage s, VkImageLayout sl, VkImage d, VkImageLayout dl, uint32_t n, const VkImageBlit *r, VkFilter f) { cnt_blit++; LIN_CMD(c, s, 0, blit_src); LIN_CMD(c, d, 1, blit_dst); n_CmdBlitImage(c, s, sl, d, dl, n, r, f); }
static void VKAPI_CALL c_CmdPushDescriptorSetKHR(VkCommandBuffer c, VkPipelineBindPoint bp, VkPipelineLayout l, uint32_t s, uint32_t n, const VkWriteDescriptorSet *w) { cnt_pushdesc++; lin_descriptor_writes(n, w); n_CmdPushDescriptorSetKHR(c, bp, l, s, n, w); }
static void VKAPI_CALL c_CmdBeginRenderPass(VkCommandBuffer c, const VkRenderPassBeginInfo *b, VkSubpassContents s) { if ((++cnt_rp % 20000) == 0) stats(); lin_render_pass(c, b); n_CmdBeginRenderPass(c, b, s); }
static void VKAPI_CALL c_CmdDispatchIndirect(VkCommandBuffer c, VkBuffer b, VkDeviceSize o) { cnt_dispatchind++; n_CmdDispatchIndirect(c, b, o); }
static void VKAPI_CALL c_CmdFillBuffer(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, VkDeviceSize s, uint32_t d) { cnt_fill++; n_CmdFillBuffer(c, b, o, s, d); }
static void VKAPI_CALL c_CmdCopyQueryPoolResults(VkCommandBuffer c, VkQueryPool p, uint32_t f, uint32_t n, VkBuffer b, VkDeviceSize o, VkDeviceSize s, VkQueryResultFlags fl) { cnt_copyq++; n_CmdCopyQueryPoolResults(c, p, f, n, b, o, s, fl); }
static void VKAPI_CALL c_CmdClearAttachments(VkCommandBuffer c, uint32_t n, const VkClearAttachment *a, uint32_t r, const VkClearRect *rc) { cnt_clearatt++; n_CmdClearAttachments(c, n, a, r, rc); }

/* linear-image use (linear.c) and memory counters (memuse.c) */
static void VKAPI_CALL c_DestroyImage(VkDevice d, VkImage i, const VkAllocationCallbacks *a) { lin_image_destroyed(i); mu_image_destroyed(i); n_DestroyImage(d, i, a); }
static void VKAPI_CALL c_DestroyImageView(VkDevice d, VkImageView v, const VkAllocationCallbacks *a) { lin_view_destroyed(v); n_DestroyImageView(d, v, a); }
static void VKAPI_CALL c_DestroyBuffer(VkDevice d, VkBuffer b, const VkAllocationCallbacks *a) { lin_buffer_destroyed(b); mu_buffer_destroyed(b); n_DestroyBuffer(d, b, a); }
static void VKAPI_CALL c_FreeMemory(VkDevice d, VkDeviceMemory m, const VkAllocationCallbacks *a) { lin_mem_freed(m); mu_freed(m); n_FreeMemory(d, m, a); }
static VkResult VKAPI_CALL c_BindImageMemory(VkDevice d, VkImage i, VkDeviceMemory m, VkDeviceSize o) {
    VkResult r = n_BindImageMemory(d, i, m, o);
    if (r == VK_SUCCESS) { lin_image_bound(d, i, m, o); mu_image_bound(d, i); }
    return r;
}
static VkResult VKAPI_CALL c_BindImageMemory2(VkDevice d, uint32_t n, const VkBindImageMemoryInfo *b) {
    VkResult r = n_BindImageMemory2(d, n, b);
    for (uint32_t k = 0; r == VK_SUCCESS && k < n; k++) if (b[k].memory) { lin_image_bound(d, b[k].image, b[k].memory, b[k].memoryOffset); mu_image_bound(d, b[k].image); }
    return r;
}
static VkResult VKAPI_CALL c_BindBufferMemory(VkDevice d, VkBuffer b, VkDeviceMemory m, VkDeviceSize o) {
    VkResult r = n_BindBufferMemory(d, b, m, o);
    if (r == VK_SUCCESS) lin_buffer_bound(d, b, m, o);
    return r;
}
static VkResult VKAPI_CALL c_BindBufferMemory2(VkDevice d, uint32_t n, const VkBindBufferMemoryInfo *b) {
    VkResult r = n_BindBufferMemory2(d, n, b);
    for (uint32_t k = 0; r == VK_SUCCESS && k < n; k++) lin_buffer_bound(d, b[k].buffer, b[k].memory, b[k].memoryOffset);
    return r;
}
static VkResult VKAPI_CALL c_MapMemory(VkDevice d, VkDeviceMemory m, VkDeviceSize o, VkDeviceSize s, VkMemoryMapFlags f, void **p) {
    VkResult r = n_MapMemory(d, m, o, s, f, p);
    if (r == VK_SUCCESS) { lin_mapped(m, o, s, *p); mu_mapped(m); }
    return r;
}
static void VKAPI_CALL c_UnmapMemory(VkDevice d, VkDeviceMemory m) { lin_unmapped(m); n_UnmapMemory(d, m); }
static VkResult VKAPI_CALL c_FlushMappedMemoryRanges(VkDevice d, uint32_t n, const VkMappedMemoryRange *r) { lin_ranges(n, r, 0); return n_FlushMappedMemoryRanges(d, n, r); }
static VkResult VKAPI_CALL c_InvalidateMappedMemoryRanges(VkDevice d, uint32_t n, const VkMappedMemoryRange *r) { lin_ranges(n, r, 1); return n_InvalidateMappedMemoryRanges(d, n, r); }
static void VKAPI_CALL c_GetImageSubresourceLayout(VkDevice d, VkImage i, const VkImageSubresource *s, VkSubresourceLayout *l) {
    n_GetImageSubresourceLayout(d, i, s, l);
    lin_layout_queried(i, s, l);
}
static void VKAPI_CALL c_CmdCopyBufferToImage(VkCommandBuffer c, VkBuffer b, VkImage i, VkImageLayout l, uint32_t n, const VkBufferImageCopy *r) {
    LIN_CMD(c, i, 1, b2i); mu_copy_to_image(c, i, n, r, 0); n_CmdCopyBufferToImage(c, b, i, l, n, r);
}
static void VKAPI_CALL c_CmdCopyImageToBuffer(VkCommandBuffer c, VkImage i, VkImageLayout l, VkBuffer b, uint32_t n, const VkBufferImageCopy *r) {
    LIN_CMD(c, i, 0, i2b); mu_copy_to_image(c, i, n, r, 1); n_CmdCopyImageToBuffer(c, i, l, b, n, r);
}
static void VKAPI_CALL c_CmdCopyImage(VkCommandBuffer c, VkImage s, VkImageLayout sl, VkImage d, VkImageLayout dl, uint32_t n, const VkImageCopy *r) {
    if (lin_enabled()) __atomic_fetch_add(&lin_copy_images, 1, __ATOMIC_RELAXED);
    mu_copy_image(c); LIN_CMD(c, s, 0, ci_src); LIN_CMD(c, d, 1, ci_dst); n_CmdCopyImage(c, s, sl, d, dl, n, r);
}
static void VKAPI_CALL c_CmdClearColorImage(VkCommandBuffer c, VkImage i, VkImageLayout l, const VkClearColorValue *v, uint32_t n, const VkImageSubresourceRange *r) {
    LIN_CMD(c, i, 1, clears); n_CmdClearColorImage(c, i, l, v, n, r);
}
static void VKAPI_CALL c_CmdPipelineBarrier(VkCommandBuffer c, VkPipelineStageFlags s, VkPipelineStageFlags d, VkDependencyFlags f, uint32_t nm, const VkMemoryBarrier *m,
                                            uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *i) {
    lin_barriers(s, d, nm, m, ni, i); n_CmdPipelineBarrier(c, s, d, f, nm, m, nb, b, ni, i);
}
static void VKAPI_CALL c_CmdWaitEvents(VkCommandBuffer c, uint32_t ne, const VkEvent *e, VkPipelineStageFlags s, VkPipelineStageFlags d, uint32_t nm, const VkMemoryBarrier *m,
                                       uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *i) {
    lin_barriers(s, d, nm, m, ni, i); n_CmdWaitEvents(c, ne, e, s, d, nm, m, nb, b, ni, i);
}
static void VKAPI_CALL c_CmdExecuteCommands(VkCommandBuffer c, uint32_t n, const VkCommandBuffer *s) { lin_execute(c, n, s); n_CmdExecuteCommands(c, n, s); }
static VkResult VKAPI_CALL c_BeginCommandBuffer(VkCommandBuffer c, const VkCommandBufferBeginInfo *b) { lin_cb_begin(c); return n_BeginCommandBuffer(c, b); }
static VkResult VKAPI_CALL c_QueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f) { lin_submit(n, s); return n_QueueSubmit(q, n, s, f); }
static VkResult VKAPI_CALL c_QueuePresentKHR(VkQueue q, const VkPresentInfoKHR *p) { lin_present(); mu_present(q); return n_QueuePresentKHR(q, p); }
static void VKAPI_CALL c_CmdCopyBuffer(VkCommandBuffer c, VkBuffer s, VkBuffer d, uint32_t n, const VkBufferCopy *r) { mu_copy_buffer(c, n, r); n_CmdCopyBuffer(c, s, d, n, r); }
static void VKAPI_CALL c_CmdUpdateBuffer(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, VkDeviceSize s, const void *p) { mu_update_buffer(c, s); n_CmdUpdateBuffer(c, b, o, s, p); }
static void VKAPI_CALL c_UpdateDescriptorSets(VkDevice d, uint32_t nw, const VkWriteDescriptorSet *w, uint32_t nc, const VkCopyDescriptorSet *c) {
    lin_descriptor_writes(nw, w); n_UpdateDescriptorSets(d, nw, w, nc, c);
}
static VkResult VKAPI_CALL c_CreateDescriptorUpdateTemplate(VkDevice d, const VkDescriptorUpdateTemplateCreateInfo *ci, const VkAllocationCallbacks *a, VkDescriptorUpdateTemplate *t) {
    VkResult r = n_CreateDescriptorUpdateTemplate(d, ci, a, t);
    if (r == VK_SUCCESS) lin_template_created(ci, *t);
    return r;
}
static void VKAPI_CALL c_DestroyDescriptorUpdateTemplate(VkDevice d, VkDescriptorUpdateTemplate t, const VkAllocationCallbacks *a) { lin_template_destroyed(t); n_DestroyDescriptorUpdateTemplate(d, t, a); }
static void VKAPI_CALL c_UpdateDescriptorSetWithTemplate(VkDevice d, VkDescriptorSet s, VkDescriptorUpdateTemplate t, const void *p) {
    lin_template_write(t, p); n_UpdateDescriptorSetWithTemplate(d, s, t, p);
}
static VkResult VKAPI_CALL c_CreateFramebuffer(VkDevice d, const VkFramebufferCreateInfo *ci, const VkAllocationCallbacks *a, VkFramebuffer *fb) {
    VkResult r = n_CreateFramebuffer(d, ci, a, fb);
    if (r == VK_SUCCESS) lin_framebuffer_created(ci, *fb);
    return r;
}
static void VKAPI_CALL c_DestroyFramebuffer(VkDevice d, VkFramebuffer fb, const VkAllocationCallbacks *a) { lin_framebuffer_destroyed(fb); n_DestroyFramebuffer(d, fb, a); }

static PFN_vkVoidFunction lookup_dev(const char *n) {
#define MAP(x) if (!strcmp(n, "vk" #x)) return n_##x ? (PFN_vkVoidFunction)c_##x : NULL;
    DEVFNS(MAP)
    return NULL;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ppcap_GetDeviceProcAddr(VkDevice d, const char *n) {
    if (!strcmp(n, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ppcap_GetDeviceProcAddr;
    { PFN_vkVoidFunction q = prof_lookup_dev(n); if (q && next_gdpa(d, n)) return q; }
    PFN_vkVoidFunction f = lookup_dev(n);
    PFN_vkVoidFunction nx = next_gdpa(d, n);
    if (getenv("PP_CAPTURE_GDPA")) L("gdpa %s %s\n", n, nx ? "ok" : "null");
    if (f && nx) return f;
    return nx;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ppcap_GetInstanceProcAddr(VkInstance i, const char *n) {
    if (!strcmp(n, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)ppcap_GetInstanceProcAddr;
    if (!strcmp(n, "vkCreateInstance")) return (PFN_vkVoidFunction)c_CreateInstance;
    if (!strcmp(n, "vkDestroyInstance")) return (PFN_vkVoidFunction)c_DestroyInstance;
    if (!strcmp(n, "vkCreateDevice")) return (PFN_vkVoidFunction)c_CreateDevice;
    if (!strcmp(n, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)ppcap_GetDeviceProcAddr;
    if (i && p_EnumDevExt) { PFN_vkVoidFunction q = prof_lookup_inst(n); if (q) return q; }
    if (!strncmp(n, "vk", 2)) {
        PFN_vkVoidFunction f = lookup_dev(n);
        if (f) {
            // device functions fetched through the instance: only wrap once the device exists
            if (n_DestroyDevice) return f;
        }
    }
    return next_gipa ? next_gipa(i, n) : NULL;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL ppcap_NegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr = ppcap_GetInstanceProcAddr;
    v->pfnGetDeviceProcAddr = ppcap_GetDeviceProcAddr;
    v->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
