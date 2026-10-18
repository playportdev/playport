/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A Vulkan device report: the extensions, core features (1.0 in full, some
 * of 1.1-1.3), the driver's ID, name and conformance version, selected
 * limits, float-controls and subgroup properties, queue families, memory
 * types and heaps and the format features of one device (every format the
 * Vulkan headers name, extension formats too), as plain "key value" lines,
 * for diffing a driver against what an application needs and as the capture
 * layer's profile (vk-capture-layer/profile.c).
 *
 *    devinfo [DEVICE_INDEX]     the loader's devices, default 0
 */
#include <vulkan/vulkan.h>
#include <vulkan/vk_enum_string_helper.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *f10[] = {"robustBufferAccess","fullDrawIndexUint32","imageCubeArray","independentBlend","geometryShader","tessellationShader","sampleRateShading","dualSrcBlend","logicOp","multiDrawIndirect","drawIndirectFirstInstance","depthClamp","depthBiasClamp","fillModeNonSolid","depthBounds","wideLines","largePoints","alphaToOne","multiViewport","samplerAnisotropy","textureCompressionETC2","textureCompressionASTC_LDR","textureCompressionBC","occlusionQueryPrecise","pipelineStatisticsQuery","vertexPipelineStoresAndAtomics","fragmentStoresAndAtomics","shaderTessellationAndGeometryPointSize","shaderImageGatherExtended","shaderStorageImageExtendedFormats","shaderStorageImageMultisample","shaderStorageImageReadWithoutFormat","shaderStorageImageWriteWithoutFormat","shaderUniformBufferArrayDynamicIndexing","shaderSampledImageArrayDynamicIndexing","shaderStorageBufferArrayDynamicIndexing","shaderStorageImageArrayDynamicIndexing","shaderClipDistance","shaderCullDistance","shaderFloat64","shaderInt64","shaderInt16","shaderResourceResidency","shaderResourceMinLod","sparseBinding","sparseResidencyBuffer","sparseResidencyImage2D","sparseResidencyImage3D","sparseResidency2Samples","sparseResidency4Samples","sparseResidency8Samples","sparseResidency16Samples","sparseResidencyAliased","variableMultisampleRate","inheritedQueries"};

int main(int argc, char **argv) {
    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "devinfo", 1, "devinfo", 1, VK_API_VERSION_1_3};
    const char *iext[] = {"VK_KHR_portability_enumeration"};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, &ai, 0, NULL, 1, iext};
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst)) { ici.flags = 0; ici.enabledExtensionCount = 0; if (vkCreateInstance(&ici, NULL, &inst)) { fprintf(stderr, "no instance\n"); return 1; } }
    uint32_t n = 8; VkPhysicalDevice pds[8];
    vkEnumeratePhysicalDevices(inst, &n, pds);
    int idx = argc > 1 ? atoi(argv[1]) : 0;
    if (idx < 0 || (uint32_t)idx >= n) { fprintf(stderr, "no device %d (%u devices)\n", idx, n); return 1; }
    VkPhysicalDevice pd = pds[idx];
    VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
    vkGetPhysicalDeviceProperties2(pd, &p2);
    VkPhysicalDeviceProperties *p = &p2.properties;
    printf("device %s api %u.%u.%u\n", p->deviceName, VK_API_VERSION_MAJOR(p->apiVersion), VK_API_VERSION_MINOR(p->apiVersion), VK_API_VERSION_PATCH(p->apiVersion));
    printf("vendor %x device %x type %d\n", p->vendorID, p->deviceID, p->deviceType);
    VkPhysicalDeviceSubgroupSizeControlProperties ssc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_PROPERTIES};
    VkPhysicalDeviceSubgroupProperties sg = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES, &ssc};
    VkPhysicalDeviceFloatControlsProperties fc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES, &sg};
    VkPhysicalDeviceDriverProperties drv = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES, &fc};
    VkPhysicalDeviceProperties2 dp2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &drv};
    vkGetPhysicalDeviceProperties2(pd, &dp2);
    printf("driver id %d\ndriver name %s\ndriver info %s\ndriver conformance %u.%u.%u.%u\n", drv.driverID, drv.driverName, drv.driverInfo,
           drv.conformanceVersion.major, drv.conformanceVersion.minor, drv.conformanceVersion.subminor, drv.conformanceVersion.patch);
    uint32_t ne = 0; vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, NULL);
    VkExtensionProperties *ep = calloc(ne, sizeof *ep); vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ep);
    for (uint32_t i = 0; i < ne; i++) printf("ext %s\n", ep[i].extensionName);
    VkPhysicalDeviceVulkan13Features v13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    VkPhysicalDeviceVulkan12Features v12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13};
    VkPhysicalDeviceVulkan11Features v11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11};
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    VkBool32 *b = (VkBool32 *)&f2.features;
    for (int i = 0; i < 55; i++) printf("f10 %s %u\n", f10[i], b[i]);
    printf("f11 storageBuffer16BitAccess %u\nf11 uniformAndStorageBuffer16BitAccess %u\nf11 storageInputOutput16 %u\nf11 multiview %u\nf11 shaderDrawParameters %u\n",
           v11.storageBuffer16BitAccess, v11.uniformAndStorageBuffer16BitAccess, v11.storageInputOutput16, v11.multiview, v11.shaderDrawParameters);
    printf("f12 scalarBlockLayout %u\nf12 uniformBufferStandardLayout %u\nf12 bufferDeviceAddress %u\nf12 timelineSemaphore %u\nf12 drawIndirectCount %u\nf12 samplerFilterMinmax %u\nf12 descriptorIndexing %u\nf12 shaderFloat16 %u\nf12 shaderInt8 %u\nf12 hostQueryReset %u\n",
           v12.scalarBlockLayout, v12.uniformBufferStandardLayout, v12.bufferDeviceAddress, v12.timelineSemaphore, v12.drawIndirectCount, v12.samplerFilterMinmax, v12.descriptorIndexing, v12.shaderFloat16, v12.shaderInt8, v12.hostQueryReset);
    printf("f13 inlineUniformBlock %u\nf13 descriptorBindingInlineUniformBlockUpdateAfterBind %u\nf13 dynamicRendering %u\nf13 synchronization2 %u\n",
           v13.inlineUniformBlock, v13.descriptorBindingInlineUniformBlockUpdateAfterBind, v13.dynamicRendering, v13.synchronization2);
    printf("f13 subgroupSizeControl %u\nf13 computeFullSubgroups %u\n", v13.subgroupSizeControl, v13.computeFullSubgroups);
    VkPhysicalDeviceLimits *l = &p->limits;
#define LIM(x) printf("limit " #x " %llu\n", (unsigned long long)l->x);
    LIM(maxImageDimension2D) LIM(maxImageDimension3D) LIM(maxImageArrayLayers) LIM(maxTexelBufferElements) LIM(maxUniformBufferRange) LIM(maxStorageBufferRange)
    LIM(maxPushConstantsSize) LIM(maxMemoryAllocationCount) LIM(maxSamplerAllocationCount) LIM(bufferImageGranularity) LIM(maxBoundDescriptorSets)
    LIM(maxPerStageDescriptorSamplers) LIM(maxPerStageDescriptorUniformBuffers) LIM(maxPerStageDescriptorStorageBuffers) LIM(maxPerStageDescriptorSampledImages)
    LIM(maxPerStageDescriptorStorageImages) LIM(maxPerStageResources) LIM(maxDescriptorSetSamplers) LIM(maxDescriptorSetUniformBuffers)
    LIM(maxDescriptorSetUniformBuffersDynamic) LIM(maxDescriptorSetStorageBuffers) LIM(maxDescriptorSetStorageBuffersDynamic) LIM(maxDescriptorSetSampledImages)
    LIM(maxDescriptorSetStorageImages) LIM(maxVertexInputAttributes) LIM(maxVertexInputBindings) LIM(maxVertexOutputComponents)
    LIM(maxTessellationGenerationLevel) LIM(maxTessellationPatchSize) LIM(maxGeometryOutputVertices) LIM(maxGeometryShaderInvocations)
    LIM(maxFragmentOutputAttachments) LIM(maxFragmentDualSrcAttachments) LIM(maxComputeSharedMemorySize) LIM(maxComputeWorkGroupInvocations)
    LIM(maxSamplerAnisotropy) LIM(maxViewports) LIM(maxClipDistances) LIM(maxCullDistances) LIM(maxCombinedClipAndCullDistances)
    LIM(framebufferColorSampleCounts) LIM(framebufferDepthSampleCounts) LIM(sampledImageColorSampleCounts) LIM(sampledImageDepthSampleCounts)
    LIM(storageImageSampleCounts) LIM(timestampComputeAndGraphics) LIM(maxColorAttachments) LIM(minUniformBufferOffsetAlignment) LIM(minStorageBufferOffsetAlignment)
    LIM(maxSamplerLodBias) LIM(minTexelGatherOffset) LIM(maxTexelGatherOffset) LIM(subPixelPrecisionBits)
    printf("limit lineWidthRange %f %f\n", l->lineWidthRange[0], l->lineWidthRange[1]);
    VkPhysicalDeviceInlineUniformBlockProperties iub = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_INLINE_UNIFORM_BLOCK_PROPERTIES};
    VkPhysicalDevicePushDescriptorPropertiesKHR pdp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PUSH_DESCRIPTOR_PROPERTIES_KHR, &iub};
    VkPhysicalDeviceProperties2 pp2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &pdp};
    vkGetPhysicalDeviceProperties2(pd, &pp2);
    printf("limit maxPushDescriptors %u\nlimit maxInlineUniformBlockSize %u\nlimit maxPerStageDescriptorInlineUniformBlocks %u\nlimit maxDescriptorSetInlineUniformBlocks %u\n",
           pdp.maxPushDescriptors, iub.maxInlineUniformBlockSize, iub.maxPerStageDescriptorInlineUniformBlocks, iub.maxDescriptorSetInlineUniformBlocks);
#define FC(x) printf("fc " #x " %u\n", fc.x);
    FC(denormBehaviorIndependence) FC(roundingModeIndependence)
    FC(shaderSignedZeroInfNanPreserveFloat16) FC(shaderSignedZeroInfNanPreserveFloat32) FC(shaderSignedZeroInfNanPreserveFloat64)
    FC(shaderDenormPreserveFloat16) FC(shaderDenormPreserveFloat32) FC(shaderDenormPreserveFloat64)
    FC(shaderDenormFlushToZeroFloat16) FC(shaderDenormFlushToZeroFloat32) FC(shaderDenormFlushToZeroFloat64)
    FC(shaderRoundingModeRTEFloat16) FC(shaderRoundingModeRTEFloat32) FC(shaderRoundingModeRTEFloat64)
    FC(shaderRoundingModeRTZFloat16) FC(shaderRoundingModeRTZFloat32) FC(shaderRoundingModeRTZFloat64)
    printf("subgroup subgroupSize %u\nsubgroup supportedStages %x\nsubgroup supportedOperations %x\nsubgroup quadOperationsInAllStages %u\n",
           sg.subgroupSize, sg.supportedStages, sg.supportedOperations, sg.quadOperationsInAllStages);
    printf("subgroup minSubgroupSize %u\nsubgroup maxSubgroupSize %u\nsubgroup maxComputeWorkgroupSubgroups %u\nsubgroup requiredSubgroupSizeStages %x\n",
           ssc.minSubgroupSize, ssc.maxSubgroupSize, ssc.maxComputeWorkgroupSubgroups, ssc.requiredSubgroupSizeStages);
    uint32_t nq = 0; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
    VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
    for (uint32_t i = 0; i < nq; i++) printf("queue %u flags=%x count=%u tsbits=%u\n", i, qf[i].queueFlags, qf[i].queueCount, qf[i].timestampValidBits);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) printf("memtype %u flags=%x heap=%u\n", i, mp.memoryTypes[i].propertyFlags, mp.memoryTypes[i].heapIndex);
    for (uint32_t i = 0; i < mp.memoryHeapCount; i++) printf("heap %u size=%llu flags=%x\n", i, (unsigned long long)mp.memoryHeaps[i].size, mp.memoryHeaps[i].flags);
    // The core formats, then every extension format these headers name (each
    // extension's enums are 1000000000 + 1000 * (number - 1) + offset).
    for (long fmt = 1; fmt < 1001000000; fmt = fmt == 184 ? 1000000000 : fmt + 1) {
        const char *name = string_VkFormat((VkFormat)fmt);
        if (!strncmp(name, "Unhandled", 9)) continue;
        VkFormatProperties fp; vkGetPhysicalDeviceFormatProperties(pd, (VkFormat)fmt, &fp);
        printf("format %s lin=%x opt=%x buf=%x", name, fp.linearTilingFeatures, fp.optimalTilingFeatures, fp.bufferFeatures);
        if (p->apiVersion >= VK_API_VERSION_1_3) { // and VkFormatFeatureFlags2, which has bits from 31 up
            VkFormatProperties3 f3 = {VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3};
            VkFormatProperties2 f2p = {VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, &f3};
            vkGetPhysicalDeviceFormatProperties2(pd, (VkFormat)fmt, &f2p);
            printf(" lin2=%llx opt2=%llx buf2=%llx", (unsigned long long)f3.linearTilingFeatures,
                   (unsigned long long)f3.optimalTilingFeatures, (unsigned long long)f3.bufferFeatures);
        }
        printf("\n");
    }
    return 0;
}
