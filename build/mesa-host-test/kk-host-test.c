/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Drive KosmicKrisp, built for Linux on the mock Metal bridge
 * (make-mock-bridge.py), through the Vulkan API: create a device, build
 * graphics pipelines and record and submit draws with them. Nothing is
 * rendered; the mock completes every commit at once. What this checks is the
 * driver's CPU side: that every pipeline compiles (NIR validation runs in a
 * debug build), that every MSL library is fully translated (the mock exits 3
 * otherwise) and that recording the draws does not crash or assert.
 *
 *    kk-host-test DRIVER.so SPV_DIR
 *
 * SPV_DIR holds the SPIR-V the test script compiled from shaders/.
 */
#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHECK(x)                                                               \
   do {                                                                        \
      VkResult r_ = (x);                                                       \
      if (r_ != VK_SUCCESS) {                                                  \
         fprintf(stderr, "%s:%d: %s = %d\n", __FILE__, __LINE__, #x, r_);     \
         exit(1);                                                              \
      }                                                                        \
   } while (0)

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance inst;
static VkDevice dev;
static const char *spv_dir;

#define IPROC(name) PFN_##name name = (PFN_##name)gipa(inst, #name)
#define DPROC(name) PFN_##name name = (PFN_##name)gipa(inst, #name)

/* How many MSL libraries the mock has written so far, to tell which
 * belong to which pipeline. */
static int
msl_count(void)
{
   const char *dir = getenv("KK_MOCK_MSL_DIR");
   DIR *d = dir ? opendir(dir) : NULL;
   int n = 0;
   if (!d)
      return -1;
   for (struct dirent *e; (e = readdir(d));)
      n += e->d_name[0] != '.';
   closedir(d);
   return n;
}

/* Whether any MSL vertex function among libraries [first, last) of the mock
 * stores to device memory: with transform feedback, the vertex function that
 * feeds the rasterizer writes the captured vertices. */
static bool
msl_vertex_stores(int first, int last)
{
   const char *dir = getenv("KK_MOCK_MSL_DIR");
   for (int i = first; dir && i < last; ++i) {
      char path[4096];
      snprintf(path, sizeof(path), "%s/%04d.metal", dir, i);
      FILE *f = fopen(path, "r");
      if (!f)
         continue;
      static char text[1 << 20];
      size_t n = fread(text, 1, sizeof(text) - 1, f);
      fclose(f);
      text[n] = 0;
      if (strstr(text, "\nvertex ") && strstr(text, "(*(device"))
         return true;
   }
   return false;
}

static VkShaderModule load_module(const char *name);
static VkShaderModule
load_module(const char *name)
{
   char path[4096];
   snprintf(path, sizeof(path), "%s/%s.spv", spv_dir, name);
   FILE *f = fopen(path, "rb");
   if (!f) {
      fprintf(stderr, "no %s\n", path);
      exit(1);
   }
   fseek(f, 0, SEEK_END);
   long n = ftell(f);
   fseek(f, 0, SEEK_SET);
   uint32_t *code = malloc(n);
   if (fread(code, 1, n, f) != (size_t)n)
      exit(1);
   fclose(f);

   DPROC(vkCreateShaderModule);
   VkShaderModuleCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
      .codeSize = n,
      .pCode = code,
   };
   VkShaderModule m;
   CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
   free(code);
   return m;
}

struct pipe_desc {
   const char *name;
   const char *vs, *tcs, *tes, *gs, *fs;
   VkPrimitiveTopology topology;
   bool restart;
   VkProvokingVertexModeEXT provoking;
   VkPolygonMode polygon_mode;
   VkCullModeFlags cull;
   /* Record transform feedback around the draws, with a stream query */
   bool xfb;
   bool discard;
   uint32_t rast_stream;
};

static VkPipeline
make_pipeline(const struct pipe_desc *d, VkPipelineLayout layout)
{
   DPROC(vkCreateGraphicsPipelines);
   VkPipelineShaderStageCreateInfo stages[5];
   uint32_t n = 0;
   const struct {
      const char *m;
      VkShaderStageFlagBits s;
   } list[] = {
      {d->vs, VK_SHADER_STAGE_VERTEX_BIT},
      {d->tcs, VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT},
      {d->tes, VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT},
      {d->gs, VK_SHADER_STAGE_GEOMETRY_BIT},
      {d->fs, VK_SHADER_STAGE_FRAGMENT_BIT},
   };
   for (unsigned i = 0; i < 5; i++) {
      if (!list[i].m)
         continue;
      stages[n++] = (VkPipelineShaderStageCreateInfo){
         .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = list[i].s,
         .module = load_module(list[i].m),
         .pName = "main",
      };
   }

   VkVertexInputBindingDescription binding = {0, 16,
                                              VK_VERTEX_INPUT_RATE_VERTEX};
   VkVertexInputAttributeDescription attr = {0, 0,
                                             VK_FORMAT_R32G32B32A32_SFLOAT, 0};
   VkPipelineVertexInputStateCreateInfo vi = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
      .vertexBindingDescriptionCount = 1,
      .pVertexBindingDescriptions = &binding,
      .vertexAttributeDescriptionCount = 1,
      .pVertexAttributeDescriptions = &attr,
   };
   VkPipelineInputAssemblyStateCreateInfo ia = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = d->topology,
      .primitiveRestartEnable = d->restart,
   };
   VkPipelineTessellationStateCreateInfo ts = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO,
      .patchControlPoints = 3,
   };
   VkPipelineViewportStateCreateInfo vp = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .scissorCount = 1,
   };
   VkPipelineRasterizationProvokingVertexStateCreateInfoEXT pv = {
      .sType =
         VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
      .provokingVertexMode = d->provoking,
   };
   VkPipelineRasterizationStateStreamCreateInfoEXT stream = {
      .sType =
         VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_STREAM_CREATE_INFO_EXT,
      .pNext = &pv,
      .rasterizationStream = d->rast_stream,
   };
   VkPipelineRasterizationStateCreateInfo rs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .pNext = &stream,
      .rasterizerDiscardEnable = d->discard,
      .polygonMode = d->polygon_mode,
      .cullMode = d->cull,
      .lineWidth = 1.0f,
   };
   VkPipelineMultisampleStateCreateInfo ms = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
   };
   VkPipelineColorBlendAttachmentState att = {.colorWriteMask = 0xf};
   VkPipelineColorBlendStateCreateInfo cb = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1,
      .pAttachments = &att,
   };
   VkDynamicState dyn_states[] = {VK_DYNAMIC_STATE_VIEWPORT,
                                  VK_DYNAMIC_STATE_SCISSOR};
   VkPipelineDynamicStateCreateInfo dyn = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
      .dynamicStateCount = 2,
      .pDynamicStates = dyn_states,
   };
   VkFormat color = VK_FORMAT_R8G8B8A8_UNORM;
   VkPipelineRenderingCreateInfo rinfo = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
      .colorAttachmentCount = 1,
      .pColorAttachmentFormats = &color,
   };
   VkGraphicsPipelineCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .pNext = &rinfo,
      .stageCount = n,
      .pStages = stages,
      .pVertexInputState = &vi,
      .pInputAssemblyState = &ia,
      .pTessellationState = d->tcs ? &ts : NULL,
      .pViewportState = &vp,
      .pRasterizationState = &rs,
      .pMultisampleState = &ms,
      .pColorBlendState = &cb,
      .pDynamicState = &dyn,
      .layout = layout,
   };
   VkPipeline p;
   VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
   if (r != VK_SUCCESS) {
      fprintf(stderr, "pipeline %s: vkCreateGraphicsPipelines = %d\n", d->name,
              r);
      exit(1);
   }
   return p;
}

static uint32_t
find_memory(VkPhysicalDevice pd, uint32_t bits)
{
   IPROC(vkGetPhysicalDeviceMemoryProperties);
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
      if ((bits & (1u << i)) &&
          (mp.memoryTypes[i].propertyFlags &
           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
         return i;
   return 0;
}

int
main(int argc, char **argv)
{
   if (argc != 3) {
      fprintf(stderr, "usage: %s DRIVER.so SPV_DIR\n", argv[0]);
      return 2;
   }
   setvbuf(stdout, NULL, _IONBF, 0);
   spv_dir = argv[2];
   void *so = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
   if (!so) {
      fprintf(stderr, "%s\n", dlerror());
      return 1;
   }
   gipa = (PFN_vkGetInstanceProcAddr)dlsym(so, "vk_icdGetInstanceProcAddr");

   PFN_vkCreateInstance vkCreateInstance =
      (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                            .apiVersion = VK_API_VERSION_1_3};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                               .pApplicationInfo = &app};
   CHECK(vkCreateInstance(&ici, NULL, &inst));

   IPROC(vkEnumeratePhysicalDevices);
   uint32_t count = 1;
   VkPhysicalDevice pd;
   CHECK(vkEnumeratePhysicalDevices(inst, &count, &pd));
   if (count == 0) {
      fprintf(stderr, "no physical device\n");
      return 1;
   }

   IPROC(vkGetPhysicalDeviceProperties);
   IPROC(vkGetPhysicalDeviceFeatures2);
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb_feat = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
   };
   VkPhysicalDeviceProvokingVertexFeaturesEXT pv_feat = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
      .pNext = &xfb_feat,
   };
   VkPhysicalDeviceFeatures2 f2 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
      .pNext = &pv_feat,
   };
   vkGetPhysicalDeviceFeatures2(pd, &f2);
   printf("device: %s, geometryShader %d, tessellationShader %d, "
          "fillModeNonSolid %d, provokingVertexLast %d, transformFeedback %d, "
          "geometryStreams %d\n",
          props.deviceName, f2.features.geometryShader,
          f2.features.tessellationShader, f2.features.fillModeNonSolid,
          pv_feat.provokingVertexLast, xfb_feat.transformFeedback,
          xfb_feat.geometryStreams);
   if (!xfb_feat.transformFeedback || !xfb_feat.geometryStreams) {
      fprintf(stderr, "transform feedback not exposed\n");
      return 1;
   }
   if (!f2.features.geometryShader) {
      fprintf(stderr, "geometryShader not exposed\n");
      return 1;
   }

   float prio = 1.0f;
   VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   VkPhysicalDeviceVulkan13Features v13 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .dynamicRendering = VK_TRUE,
      .synchronization2 = VK_TRUE,
   };
   VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb_enable = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
      .pNext = &v13,
      .transformFeedback = VK_TRUE,
      .geometryStreams = VK_TRUE,
   };
   VkPhysicalDeviceProvokingVertexFeaturesEXT pv_enable = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
      .pNext = &xfb_enable,
      .provokingVertexLast = pv_feat.provokingVertexLast,
   };
   VkPhysicalDeviceFeatures feats = {
      .geometryShader = VK_TRUE,
      .tessellationShader = VK_TRUE,
      .fillModeNonSolid = f2.features.fillModeNonSolid,
      .shaderClipDistance = VK_TRUE,
      .shaderCullDistance = VK_TRUE,
   };
   const char *exts[] = {"VK_EXT_transform_feedback", "VK_EXT_provoking_vertex"};
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &pv_enable,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
      .enabledExtensionCount = pv_feat.provokingVertexLast ? 2 : 1,
      .ppEnabledExtensionNames = exts,
      .pEnabledFeatures = &feats,
   };
   IPROC(vkCreateDevice);
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));

   DPROC(vkGetDeviceQueue);
   DPROC(vkCreateImage);
   DPROC(vkGetImageMemoryRequirements);
   DPROC(vkAllocateMemory);
   DPROC(vkBindImageMemory);
   DPROC(vkCreateImageView);
   DPROC(vkCreateBuffer);
   DPROC(vkGetBufferMemoryRequirements);
   DPROC(vkBindBufferMemory);
   DPROC(vkMapMemory);
   DPROC(vkCreatePipelineLayout);
   DPROC(vkCreateCommandPool);
   DPROC(vkAllocateCommandBuffers);
   DPROC(vkBeginCommandBuffer);
   DPROC(vkEndCommandBuffer);
   DPROC(vkCmdBeginRendering);
   DPROC(vkCmdEndRendering);
   DPROC(vkCmdBindPipeline);
   DPROC(vkCmdSetViewport);
   DPROC(vkCmdSetScissor);
   DPROC(vkCmdBindVertexBuffers);
   DPROC(vkCmdBindIndexBuffer);
   DPROC(vkCmdDraw);
   DPROC(vkCmdDrawIndexed);
   DPROC(vkCmdDrawIndirect);
   DPROC(vkCmdDrawIndexedIndirect);
   DPROC(vkQueueSubmit);
   DPROC(vkCmdBindTransformFeedbackBuffersEXT);
   DPROC(vkCmdBeginTransformFeedbackEXT);
   DPROC(vkCmdEndTransformFeedbackEXT);
   DPROC(vkCmdDrawIndirectByteCountEXT);
   DPROC(vkCmdBeginQueryIndexedEXT);
   DPROC(vkCmdEndQueryIndexedEXT);
   DPROC(vkCmdResetQueryPool);
   DPROC(vkCreateQueryPool);
   DPROC(vkGetQueryPoolResults);
   DPROC(vkQueueWaitIdle);

   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   /* Color target */
   VkImageCreateInfo imci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {64, 64, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
   };
   VkImage image;
   CHECK(vkCreateImage(dev, &imci, NULL, &image));
   VkMemoryRequirements mr;
   vkGetImageMemoryRequirements(dev, image, &mr);
   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                               .allocationSize = mr.size,
                               .memoryTypeIndex =
                                  find_memory(pd, mr.memoryTypeBits)};
   VkDeviceMemory imem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &imem));
   CHECK(vkBindImageMemory(dev, image, imem, 0));
   VkImageViewCreateInfo ivci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = image,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
   };
   VkImageView view;
   CHECK(vkCreateImageView(dev, &ivci, NULL, &view));

   /* One host-visible buffer for vertices, indices and indirect commands */
   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 65536 + 16384,
      .usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
               VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
               VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT |
               VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT |
               VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_COUNTER_BUFFER_BIT_EXT,
   };
   VkBuffer buf;
   CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
   vkGetBufferMemoryRequirements(dev, buf, &mr);
   mai.allocationSize = mr.size;
   mai.memoryTypeIndex = find_memory(pd, mr.memoryTypeBits);
   VkDeviceMemory bmem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &bmem));
   CHECK(vkBindBufferMemory(dev, buf, bmem, 0));
   uint8_t *map;
   CHECK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
   float *verts = (float *)map;
   for (int i = 0; i < 64; i++) {
      verts[i * 4 + 0] = (i % 8) / 8.0f;
      verts[i * 4 + 1] = (i / 8) / 8.0f;
      verts[i * 4 + 2] = 0.0f;
      verts[i * 4 + 3] = 1.0f;
   }
   uint16_t *idx = (uint16_t *)(map + 4096);
   for (int i = 0; i < 32; i++)
      idx[i] = (i % 7 == 6) ? 0xffff : i; /* restart every 7th */
   VkDrawIndirectCommand *ind = (VkDrawIndirectCommand *)(map + 8192);
   *ind = (VkDrawIndirectCommand){12, 2, 0, 0};
   VkDrawIndexedIndirectCommand *indi =
      (VkDrawIndexedIndirectCommand *)(map + 8192 + 64);
   *indi = (VkDrawIndexedIndirectCommand){12, 2, 0, 0, 0};

   VkQueryPoolCreateInfo qpci = {
      .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
      .queryType = VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT,
      .queryCount = 2,
   };
   VkQueryPool xfb_queries;
   CHECK(vkCreateQueryPool(dev, &qpci, NULL, &xfb_queries));

   VkPipelineLayoutCreateInfo plci = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
   };
   VkPipelineLayout layout;
   CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

   const VkPrimitiveTopology TRI = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
   const VkProvokingVertexModeEXT FIRST =
      VK_PROVOKING_VERTEX_MODE_FIRST_VERTEX_EXT;
   const VkProvokingVertexModeEXT LAST =
      pv_feat.provokingVertexLast ? VK_PROVOKING_VERTEX_MODE_LAST_VERTEX_EXT
                                  : FIRST;
   const VkPolygonMode FILL = VK_POLYGON_MODE_FILL;
   struct pipe_desc descs[] = {
      {"no-gs", "pass.vert", NULL, NULL, NULL, "color.frag", TRI, false, FIRST, FILL},
      {"gs-passthrough", "pass.vert", NULL, NULL, "passthrough.geom", "color.frag", TRI, false, FIRST, FILL},
      {"gs-dynamic-count", "pass.vert", NULL, NULL, "dynamic.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_POINT_LIST, false, FIRST, FILL},
      {"gs-lines-out", "pass.vert", NULL, NULL, "lines.geom", "color.frag", TRI, false, FIRST, FILL},
      {"gs-points-out", "pass.vert", NULL, NULL, "points.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_LINE_STRIP, false, LAST, FILL},
      {"gs-instanced", "pass.vert", NULL, NULL, "instanced.geom", "color.frag", TRI, false, FIRST, FILL},
      {"gs-adjacency", "pass.vert", NULL, NULL, "adjacency.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST_WITH_ADJACENCY, false, FIRST, FILL},
      {"gs-strip-restart", "pass.vert", NULL, NULL, "passthrough.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, LAST, FILL},
      {"gs-primid-clip", "pass.vert", NULL, NULL, "primid.geom", "primid.frag", TRI, false, FIRST, FILL},
      {"gs-no-fs", "pass.vert", NULL, NULL, "passthrough.geom", NULL, TRI, false, FIRST, FILL},
      {"gs-dynamic-points", "pass.vert", NULL, NULL, "dynpoints.geom", "color.frag", TRI, false, FIRST, FILL},
      {"tess-gs", "pass.vert", "tri.tesc", "tri.tese", "passthrough.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_PATCH_LIST, false, FIRST, FILL},
      {"line-fill", "pass.vert", NULL, NULL, NULL, "color.frag", TRI, false, FIRST, VK_POLYGON_MODE_LINE},
      {"point-fill", "pass.vert", NULL, NULL, NULL, "color.frag", TRI, false, FIRST, VK_POLYGON_MODE_POINT, VK_CULL_MODE_BACK_BIT},
      {"point-fill-strip-primid", "pass.vert", NULL, NULL, NULL, "primid.frag", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, true, LAST, VK_POLYGON_MODE_POINT, VK_CULL_MODE_FRONT_BIT},
      {"tess-point-fill", "pass.vert", "tri.tesc", "tri.tese", NULL, "color.frag", VK_PRIMITIVE_TOPOLOGY_PATCH_LIST, false, FIRST, VK_POLYGON_MODE_POINT, VK_CULL_MODE_BACK_BIT},
      {"xfb-vs", "xfb.vert", NULL, NULL, NULL, "color.frag", TRI, false, FIRST, FILL, 0, true},
      {"xfb-vs-discard-lines", "xfb.vert", NULL, NULL, NULL, NULL, VK_PRIMITIVE_TOPOLOGY_LINE_STRIP, false, LAST, FILL, 0, true, true},
      {"xfb-vs-points", "xfb.vert", NULL, NULL, NULL, "color.frag", VK_PRIMITIVE_TOPOLOGY_POINT_LIST, false, FIRST, FILL, 0, true},
      {"xfb-gs-dynamic", "pass.vert", NULL, NULL, "xfb.geom", "color.frag", TRI, false, FIRST, FILL, 0, true},
      {"xfb-gs-streams", "pass.vert", NULL, NULL, "streams.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_POINT_LIST, false, FIRST, FILL, 0, true},
      {"xfb-gs-streams-rast1", "pass.vert", NULL, NULL, "streams.geom", "color.frag", VK_PRIMITIVE_TOPOLOGY_POINT_LIST, false, FIRST, FILL, 1, true},
      {"xfb-tess", "pass.vert", "tri.tesc", "xfb.tese", NULL, "color.frag", VK_PRIMITIVE_TOPOLOGY_PATCH_LIST, false, FIRST, FILL, 0, true},
      {"gs-line-fill", "pass.vert", NULL, NULL, "passthrough.geom", "color.frag", TRI, false, FIRST, VK_POLYGON_MODE_LINE},
   };
   unsigned ndescs = sizeof(descs) / sizeof(descs[0]);
   /* The fill mode pipelines are last. */
   if (!f2.features.fillModeNonSolid) {
      fprintf(stderr, "fillModeNonSolid not exposed\n");
      return 1;
   }

   VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
   };
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

   for (unsigned i = 0; i < ndescs; i++) {
      int msl_before = msl_count();
      VkPipeline p = make_pipeline(&descs[i], layout);
      /* No new library: the device's pipeline cache (mesa 0015) gave this
       * pipeline the shaders of an earlier one whose keys match, checked
       * there. */
      if (descs[i].xfb && msl_before >= 0 && msl_count() != msl_before &&
          !msl_vertex_stores(msl_before, msl_count())) {
         fprintf(stderr, "pipeline %s: no vertex function writes transform "
                         "feedback\n", descs[i].name);
         return 1;
      }
      bool tess = descs[i].tcs != NULL;

      VkCommandBufferAllocateInfo cbai = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = pool,
         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
         .commandBufferCount = 1,
      };
      VkCommandBuffer cmd;
      CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
      VkCommandBufferBeginInfo bi = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      };
      CHECK(vkBeginCommandBuffer(cmd, &bi));
      if (descs[i].xfb)
         vkCmdResetQueryPool(cmd, xfb_queries, 0, 2);
      VkRenderingAttachmentInfo ca = {
         .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
         .imageView = view,
         .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
         .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
         .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      };
      VkRenderingInfo ri = {
         .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
         .renderArea = {{0, 0}, {64, 64}},
         .layerCount = 1,
         .colorAttachmentCount = 1,
         .pColorAttachments = &ca,
      };
      vkCmdBeginRendering(cmd, &ri);
      vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
      VkViewport vpt = {0, 0, 64, 64, 0, 1};
      VkRect2D sc = {{0, 0}, {64, 64}};
      vkCmdSetViewport(cmd, 0, 1, &vpt);
      vkCmdSetScissor(cmd, 0, 1, &sc);
      VkDeviceSize off = 0;
      vkCmdBindVertexBuffers(cmd, 0, 1, &buf, &off);
      vkCmdBindIndexBuffer(cmd, buf, 4096, VK_INDEX_TYPE_UINT16);

      /* Transform feedback into two ranges of the buffer, byte counters
       * after the indirect commands, one stream query per stream. */
      VkBuffer xfb_bufs[2] = {buf, buf};
      VkDeviceSize xfb_offs[2] = {16384, 32768};
      VkDeviceSize xfb_sizes[2] = {8192, VK_WHOLE_SIZE};
      VkBuffer counters[2] = {buf, buf};
      VkDeviceSize counter_offs[2] = {12288, 12292};
      if (descs[i].xfb) {
         vkCmdBindTransformFeedbackBuffersEXT(cmd, 0, 2, xfb_bufs, xfb_offs,
                                              xfb_sizes);
         vkCmdBeginQueryIndexedEXT(cmd, xfb_queries, 0, 0, 0);
         vkCmdBeginQueryIndexedEXT(cmd, xfb_queries, 1, 0, 1);
         vkCmdBeginTransformFeedbackEXT(cmd, 0, 0, NULL, NULL);
      }

      uint32_t verts_per = tess ? 3 : 12;
      vkCmdDraw(cmd, verts_per, 1, 0, 0);
      vkCmdDraw(cmd, verts_per * 2, 3, 3, 1);
      vkCmdDrawIndexed(cmd, verts_per, 2, 0, 1, 0);
      if (descs[i].restart)
         vkCmdDrawIndexed(cmd, 30, 1, 0, 0, 0);
      vkCmdDrawIndirect(cmd, buf, 8192, 1, 0);
      vkCmdDrawIndexedIndirect(cmd, buf, 8192 + 64, 1, 0);
      if (descs[i].xfb) {
         /* Pause into the counters, resume from them, and draw what was
          * captured. */
         vkCmdEndTransformFeedbackEXT(cmd, 0, 2, counters, counter_offs);
         vkCmdBeginTransformFeedbackEXT(cmd, 0, 2, counters, counter_offs);
         vkCmdDraw(cmd, verts_per, 1, 0, 0);
         vkCmdEndTransformFeedbackEXT(cmd, 0, 2, counters, counter_offs);
         vkCmdEndQueryIndexedEXT(cmd, xfb_queries, 0, 0);
         vkCmdEndQueryIndexedEXT(cmd, xfb_queries, 1, 1);
         if (!tess)
            vkCmdDrawIndirectByteCountEXT(cmd, 1, 0, buf, 12288, 0, 32);
      }
      vkCmdEndRendering(cmd);
      CHECK(vkEndCommandBuffer(cmd));

      VkSubmitInfo si = {
         .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
         .commandBufferCount = 1,
         .pCommandBuffers = &cmd,
      };
      CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(queue));
      if (descs[i].xfb) {
         /* The mock runs no GPU work, so the queries never become
          * available: this only exercises the result path. */
         uint64_t results[2][3];
         VkResult r = vkGetQueryPoolResults(
            dev, xfb_queries, 0, 2, sizeof(results), results,
            sizeof(results[0]),
            VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
         if (r != VK_SUCCESS && r != VK_NOT_READY) {
            fprintf(stderr, "vkGetQueryPoolResults = %d\n", r);
            return 1;
         }
      }
      printf("ok %s (MSL libraries up to %d)\n", descs[i].name, msl_count());
   }

   printf("all %u pipelines built and drawn\n", ndescs);

   /* Texel buffers whose views start at a texel that is not 16-byte aligned
    * (storage/uniformTexelBufferOffsetSingleTexelAlignment, which
    * vkd3d-proton requires). The mock aborts if the driver creates a Metal
    * texture at an unaligned offset. */
   {
      IPROC(vkGetPhysicalDeviceProperties2);
      VkPhysicalDeviceTexelBufferAlignmentProperties tba = {
         .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TEXEL_BUFFER_ALIGNMENT_PROPERTIES,
      };
      VkPhysicalDeviceProperties2 p2 = {
         .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
         .pNext = &tba,
      };
      vkGetPhysicalDeviceProperties2(pd, &p2);
      if (!tba.storageTexelBufferOffsetSingleTexelAlignment ||
          !tba.uniformTexelBufferOffsetSingleTexelAlignment) {
         fprintf(stderr, "texel buffers need aligned offsets\n");
         return 1;
      }

      DPROC(vkCreateBufferView);
      DPROC(vkCreateDescriptorSetLayout);
      DPROC(vkCreateDescriptorPool);
      DPROC(vkAllocateDescriptorSets);
      DPROC(vkUpdateDescriptorSets);
      DPROC(vkCreateComputePipelines);
      DPROC(vkCmdBindDescriptorSets);
      DPROC(vkCmdDispatch);

      struct {
         VkFormat format;
         VkDeviceSize offset;
      } views[] = {
         {VK_FORMAT_R32_UINT, 49152 + 4},    /* one texel past alignment */
         {VK_FORMAT_R32_UINT, 49152 + 1024 + 12},
         {VK_FORMAT_R8G8B8A8_UNORM, 49152 + 2048 + 8},
      };
      VkBufferView bv[3];
      for (unsigned i = 0; i < 3; ++i) {
         VkBufferViewCreateInfo ci = {
            .sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO,
            .buffer = buf,
            .format = views[i].format,
            .offset = views[i].offset,
            .range = 256,
         };
         CHECK(vkCreateBufferView(dev, &ci, NULL, &bv[i]));
      }

      VkDescriptorSetLayoutBinding bindings[3] = {
         {0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT},
         {1, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT},
         {2, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT},
      };
      VkDescriptorSetLayoutCreateInfo dslci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 3,
         .pBindings = bindings,
      };
      VkDescriptorSetLayout dsl;
      CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
      VkDescriptorPoolSize sizes[2] = {
         {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1},
         {VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 2},
      };
      VkDescriptorPoolCreateInfo dpci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
         .maxSets = 1,
         .poolSizeCount = 2,
         .pPoolSizes = sizes,
      };
      VkDescriptorPool dp;
      CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
      VkDescriptorSetAllocateInfo dsai = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
         .descriptorPool = dp,
         .descriptorSetCount = 1,
         .pSetLayouts = &dsl,
      };
      VkDescriptorSet ds;
      CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));
      VkWriteDescriptorSet writes[3];
      for (unsigned i = 0; i < 3; ++i) {
         writes[i] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = ds,
            .dstBinding = i,
            .descriptorCount = 1,
            .descriptorType = bindings[i].descriptorType,
            .pTexelBufferView = &bv[i],
         };
      }
      vkUpdateDescriptorSets(dev, 3, writes, 0, NULL);

      VkPipelineLayoutCreateInfo cplci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &dsl,
      };
      VkPipelineLayout cpl;
      CHECK(vkCreatePipelineLayout(dev, &cplci, NULL, &cpl));
      int msl_before = msl_count();
      VkComputePipelineCreateInfo cpci = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = load_module("texel.comp"),
            .pName = "main",
         },
         .layout = cpl,
      };
      VkPipeline cp;
      CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &cp));
      /* The texel index must be offset, and a size query answered from the
       * descriptor instead of the Metal texture. */
      if (msl_before >= 0) {
         const char *dir = getenv("KK_MOCK_MSL_DIR");
         char path[4096];
         snprintf(path, sizeof(path), "%s/%04d.metal", dir, msl_count() - 1);
         FILE *f = fopen(path, "r");
         static char text[1 << 20];
         size_t n = f ? fread(text, 1, sizeof(text) - 1, f) : 0;
         if (f)
            fclose(f);
         text[n] = 0;
         if (strstr(text, "get_width")) {
            fprintf(stderr, "texel buffer size taken from the Metal texture\n");
            return 1;
         }
      }

      VkCommandBufferAllocateInfo cbai = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = pool,
         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
         .commandBufferCount = 1,
      };
      VkCommandBuffer cmd;
      CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
      VkCommandBufferBeginInfo bi = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      };
      CHECK(vkBeginCommandBuffer(cmd, &bi));
      vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, cp);
      vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, cpl, 0, 1,
                              &ds, 0, NULL);
      vkCmdDispatch(cmd, 1, 1, 1);
      CHECK(vkEndCommandBuffer(cmd));
      VkSubmitInfo si = {
         .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
         .commandBufferCount = 1,
         .pCommandBuffers = &cmd,
      };
      CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(queue));
      printf("ok texel-buffers-unaligned\n");
   }
   return 0;
}
