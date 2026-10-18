/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Drive KosmicKrisp, built for Linux on the mock Metal bridge
 * (make-mock-bridge.py), through the Vulkan API: create a device, build
 * graphics pipelines and record and submit draws with them. Nothing is
 * rendered; the mock completes every commit at once. What this checks is the
 * driver's CPU side: that every pipeline compiles (NIR validation runs in a
 * debug build), that every MSL library is fully translated (the mock exits 3
 * otherwise) and that recording the draws does not crash or assert. First,
 * which instances get a discrete device type, and that PLAYPORT_VK_BUDGET_MB
 * caps the heap's budget and not its size.
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
#include <sys/wait.h>
#include <unistd.h>
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

/* Whether any MSL library among [first, last) of the mock contains text. */
static bool
msl_contains(int first, int last, const char *text)
{
   const char *dir = getenv("KK_MOCK_MSL_DIR");
   for (int i = first; dir && i < last; ++i) {
      char path[4096];
      snprintf(path, sizeof(path), "%s/%04d.metal", dir, i);
      FILE *f = fopen(path, "r");
      if (!f)
         continue;
      static char src[1 << 20];
      size_t n = fread(src, 1, sizeof(src) - 1, f);
      fclose(f);
      src[n] = 0;
      if (strstr(src, text))
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
   /* 0 is VK_SAMPLE_COUNT_1_BIT */
   VkSampleCountFlagBits samples;
   bool no_attachments;
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
      .rasterizationSamples = d->samples ? d->samples : VK_SAMPLE_COUNT_1_BIT,
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
      .colorAttachmentCount = d->no_attachments ? 0 : 1,
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
      .pColorBlendState = d->no_attachments ? NULL : &cb,
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

/* Heap 0's size and VK_EXT_memory_budget budget in MiB, from a fresh
 * instance (the driver reads PLAYPORT_VK_BUDGET_MB when it enumerates). */
static void
heap_and_budget(const VkInstanceCreateInfo *ici, uint64_t *size_MB,
                uint64_t *budget_MB)
{
   VkInstance i;
   CHECK(((PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance"))(ici, NULL, &i));
   uint32_t count = 1;
   VkPhysicalDevice pd;
   CHECK(((PFN_vkEnumeratePhysicalDevices)gipa(i, "vkEnumeratePhysicalDevices"))(
      i, &count, &pd));
   VkPhysicalDeviceMemoryBudgetPropertiesEXT budget = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
   };
   VkPhysicalDeviceMemoryProperties2 mp = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
      .pNext = &budget,
   };
   ((PFN_vkGetPhysicalDeviceMemoryProperties2)gipa(
      i, "vkGetPhysicalDeviceMemoryProperties2"))(pd, &mp);
   *size_MB = mp.memoryProperties.memoryHeaps[0].size >> 20;
   *budget_MB = budget.heapBudget[0] >> 20;
   ((PFN_vkDestroyInstance)gipa(i, "vkDestroyInstance"))(i, NULL);
}

/* patches/mesa 0036: PLAYPORT_VK_BUDGET_MB caps heap 0's budget and leaves
 * its size; unset, or under 256, it changes nothing. */
static int
check_budget_cap(const VkInstanceCreateInfo *ici)
{
   uint64_t size, budget, cap_size, cap_budget, low_size, low_budget;
   unsetenv("PLAYPORT_VK_BUDGET_MB");
   heap_and_budget(ici, &size, &budget);
   setenv("PLAYPORT_VK_BUDGET_MB", "1536", 1);
   heap_and_budget(ici, &cap_size, &cap_budget);
   setenv("PLAYPORT_VK_BUDGET_MB", "100", 1);
   heap_and_budget(ici, &low_size, &low_budget);
   unsetenv("PLAYPORT_VK_BUDGET_MB");
   printf("memory: heap 0 %llu MiB, budget %llu MiB; capped at 1536: heap "
          "%llu MiB, budget %llu MiB; 100 (ignored): budget %llu MiB\n",
          (unsigned long long)size, (unsigned long long)budget,
          (unsigned long long)cap_size, (unsigned long long)cap_budget,
          (unsigned long long)low_budget);
   if (size != 5120 || cap_size != size || low_size != size) {
      fprintf(stderr, "the budget cap changed heap 0's size\n");
      return 1;
   }
   /* The uncapped budget follows the host's free memory, which moves
    * between instances: compare only well clear of the cap. */
   if (budget < 2048 || low_budget < 2048) {
      fprintf(stderr, "this host's budget (%llu MiB) is too close to the cap "
              "to check it\n", (unsigned long long)budget);
      return 1;
   }
   if (cap_budget != 1536) {
      fprintf(stderr, "PLAYPORT_VK_BUDGET_MB=1536 gave a %llu MiB budget\n",
              (unsigned long long)cap_budget);
      return 1;
   }
   return 0;
}

/* The device type a fresh instance with these application and engine names
 * sees. */
static VkPhysicalDeviceType
device_type_for(const char *app_name, const char *engine_name)
{
   VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                            .pApplicationName = app_name,
                            .pEngineName = engine_name,
                            .apiVersion = VK_API_VERSION_1_1};
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                               .pApplicationInfo = &app};
   VkInstance i;
   CHECK(((PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance"))(&ici, NULL, &i));
   uint32_t count = 1;
   VkPhysicalDevice pd;
   CHECK(((PFN_vkEnumeratePhysicalDevices)gipa(i, "vkEnumeratePhysicalDevices"))(
      i, &count, &pd));
   VkPhysicalDeviceProperties props;
   ((PFN_vkGetPhysicalDeviceProperties)gipa(i, "vkGetPhysicalDeviceProperties"))(
      pd, &props);
   ((PFN_vkDestroyInstance)gipa(i, "vkDestroyInstance"))(i, NULL);
   return props.deviceType;
}

/* patches/mesa 0043: Red Dead Redemption 2's renderer (application "Red Dead
 * Redemption 2", engine "SGA") gets a discrete device type; any other
 * instance, the DXVK and vkd3d-proton ones in its process included, keeps the
 * integrated one, and so does the renderer under
 * MESA_KK_DEBUG=integrated_device. The driver reads MESA_KK_DEBUG once per
 * process, so that case runs in a child, before this process makes an
 * instance. */
static int
check_device_type(void)
{
   pid_t child = fork();
   if (child == 0) {
      setenv("MESA_KK_DEBUG", "integrated_device", 1);
      _exit(device_type_for("Red Dead Redemption 2", "SGA") ==
                  VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
               ? 0
               : 1);
   }
   int status = 0;
   if (child < 0 || waitpid(child, &status, 0) != child ||
       !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      fprintf(stderr, "MESA_KK_DEBUG=integrated_device: the renderer did not "
              "get the integrated device type\n");
      return 1;
   }

   static const struct {
      const char *app, *engine;
      VkPhysicalDeviceType type;
   } cases[] = {
      {"Red Dead Redemption 2", "SGA", VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU},
      {"RDR2.exe", "DXVK", VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU},
      {"RDR2.exe", "vkd3d", VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU},
      {"Red Dead Redemption 2", NULL, VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU},
      {"Red Dead Redemption", "SGA", VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU},
      {NULL, NULL, VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU},
   };
   for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
      VkPhysicalDeviceType type = device_type_for(cases[i].app, cases[i].engine);
      if (type != cases[i].type) {
         fprintf(stderr, "application %s, engine %s: device type %d, not %d\n",
                 cases[i].app ? cases[i].app : "(none)",
                 cases[i].engine ? cases[i].engine : "(none)", type,
                 cases[i].type);
         return 1;
      }
   }
   printf("ok device-type\n");
   return 0;
}

/* Linear images of the shapes Red Dead Redemption 2's Vulkan renderer
 * creates on an integrated GPU without asking for their format properties:
 * 2D ones KosmicKrisp supports, 2D colour attachments, 2D arrays, 3D storage
 * images (2D array compatible) and a mipmapped one; KosmicKrisp reports
 * none but the first (no linear attachments, 3D, layers or levels). They are
 * bound at their alignment in one allocation, viewed, copied from and to a
 * buffer, and the attachments cleared in a render pass. The mock aborts on
 * a linear Metal texture MTLBuffer cannot make (patches/mesa 0041 gives
 * those a texture of Metal's own layout). Each one's subresource layout has
 * to fit the memory it asked for, and the 2D ones' to stay as it was. */
static int
check_linear_images(VkPhysicalDevice pd, VkQueue queue, VkCommandPool pool)
{
   DPROC(vkCreateImage);
   DPROC(vkGetImageMemoryRequirements);
   DPROC(vkGetImageSubresourceLayout);
   DPROC(vkAllocateMemory);
   DPROC(vkBindImageMemory);
   DPROC(vkCreateImageView);
   DPROC(vkCreateBuffer);
   DPROC(vkGetBufferMemoryRequirements);
   DPROC(vkBindBufferMemory);
   DPROC(vkAllocateCommandBuffers);
   DPROC(vkBeginCommandBuffer);
   DPROC(vkEndCommandBuffer);
   DPROC(vkCmdCopyBufferToImage);
   DPROC(vkCmdCopyImageToBuffer);
   DPROC(vkCmdBeginRendering);
   DPROC(vkCmdEndRendering);
   DPROC(vkQueueSubmit);
   DPROC(vkQueueWaitIdle);

   const VkImageUsageFlags xfer_sampled = VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                          VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                          VK_IMAGE_USAGE_SAMPLED_BIT;
   const struct {
      const char *name;
      VkImageType type;
      VkFormat format;
      uint32_t texel_B;
      VkExtent3D extent;
      uint32_t levels, layers;
      VkImageUsageFlags usage;
      VkImageCreateFlags flags;
   } shapes[] = {
      {"2d", VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_SFLOAT, 8, {32, 4, 1},
       1, 1, xfer_sampled, 0},
      {"2d-colour-attachment", VK_IMAGE_TYPE_2D, VK_FORMAT_R32_SFLOAT, 4,
       {1, 1, 1}, 1, 1, xfer_sampled | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, 0},
      {"2d-colour-attachment-storage", VK_IMAGE_TYPE_2D, VK_FORMAT_R8_UINT, 1,
       {4096, 64, 1}, 1, 1,
       xfer_sampled | VK_IMAGE_USAGE_STORAGE_BIT |
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
       0},
      {"2d-array", VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_SFLOAT, 8,
       {16, 28, 1}, 1, 8, xfer_sampled, 0},
      {"3d-storage", VK_IMAGE_TYPE_3D, VK_FORMAT_R16G16B16A16_SFLOAT, 8,
       {64, 64, 16}, 1, 1, xfer_sampled | VK_IMAGE_USAGE_STORAGE_BIT,
       VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT},
      {"3d-storage-r32ui", VK_IMAGE_TYPE_3D, VK_FORMAT_R32_UINT, 4,
       {32, 32, 16}, 1, 1, xfer_sampled | VK_IMAGE_USAGE_STORAGE_BIT,
       VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT},
      {"2d-mips", VK_IMAGE_TYPE_2D, VK_FORMAT_R32_SFLOAT, 4, {128, 72, 1}, 7,
       1, xfer_sampled, 0},
   };
   enum { N = sizeof(shapes) / sizeof(shapes[0]) };
   VkImage images[N];
   VkDeviceSize offsets[N], total = 0, staging = 0;
   uint32_t bits = ~0u;
   for (unsigned i = 0; i < N; i++) {
      VkImageCreateInfo ci = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
         .flags = shapes[i].flags,
         .imageType = shapes[i].type,
         .format = shapes[i].format,
         .extent = shapes[i].extent,
         .mipLevels = shapes[i].levels,
         .arrayLayers = shapes[i].layers,
         .samples = VK_SAMPLE_COUNT_1_BIT,
         .tiling = VK_IMAGE_TILING_LINEAR,
         .usage = shapes[i].usage,
      };
      CHECK(vkCreateImage(dev, &ci, NULL, &images[i]));
      VkMemoryRequirements mr;
      vkGetImageMemoryRequirements(dev, images[i], &mr);
      bits &= mr.memoryTypeBits;
      /* As the game does: one allocation, each image at its alignment. */
      offsets[i] = (total + mr.alignment - 1) / mr.alignment * mr.alignment;
      total = offsets[i] + mr.size;

      /* Every subresource's layout inside the image's memory, none
       * overlapping another. */
      VkDeviceSize texels = 0, start[64], end[64];
      unsigned nsub = 0;
      for (uint32_t level = 0; level < shapes[i].levels; level++) {
         uint32_t w = shapes[i].extent.width >> level;
         uint32_t h = shapes[i].extent.height >> level;
         uint32_t d = shapes[i].extent.depth >> level;
         w = w ? w : 1;
         h = h ? h : 1;
         d = d ? d : 1;
         texels += (VkDeviceSize)w * h * d * shapes[i].layers;
         for (uint32_t layer = 0; layer < shapes[i].layers; layer++) {
            VkImageSubresource sr = {VK_IMAGE_ASPECT_COLOR_BIT, level, layer};
            VkSubresourceLayout sl;
            vkGetImageSubresourceLayout(dev, images[i], &sr, &sl);
            VkDeviceSize row_B = (VkDeviceSize)w * shapes[i].texel_B;
            if (sl.rowPitch < row_B ||
                (d > 1 && sl.depthPitch < sl.rowPitch * h) ||
                sl.size < sl.rowPitch * (h - 1) + row_B +
                             (d > 1 ? sl.depthPitch * (d - 1) : 0) ||
                sl.offset + sl.size > mr.size) {
               fprintf(stderr, "linear %s level %u layer %u: offset %llu "
                       "size %llu rowPitch %llu depthPitch %llu in %llu "
                       "bytes\n", shapes[i].name, level, layer,
                       (unsigned long long)sl.offset,
                       (unsigned long long)sl.size,
                       (unsigned long long)sl.rowPitch,
                       (unsigned long long)sl.depthPitch,
                       (unsigned long long)mr.size);
               return 1;
            }
            for (unsigned k = 0; k < nsub; k++) {
               if (sl.offset < end[k] && start[k] < sl.offset + sl.size) {
                  fprintf(stderr, "linear %s level %u layer %u overlaps "
                          "another subresource\n", shapes[i].name, level,
                          layer);
                  return 1;
               }
            }
            start[nsub] = sl.offset;
            end[nsub++] = sl.offset + sl.size;
            /* The 2D images Metal can make from a buffer keep their
             * layout: rows at the linear alignment, from the start. */
            if (shapes[i].type == VK_IMAGE_TYPE_2D && shapes[i].levels == 1 &&
                shapes[i].layers == 1 &&
                (sl.offset != 0 || sl.rowPitch != (row_B + 15) / 16 * 16 ||
                 sl.size != sl.rowPitch * h)) {
               fprintf(stderr, "linear %s: layout changed (rowPitch %llu, "
                       "size %llu)\n", shapes[i].name,
                       (unsigned long long)sl.rowPitch,
                       (unsigned long long)sl.size);
               return 1;
            }
         }
      }
      if (texels * shapes[i].texel_B > staging)
         staging = texels * shapes[i].texel_B;
      printf("linear %s: %llu bytes, alignment %llu\n", shapes[i].name,
             (unsigned long long)mr.size, (unsigned long long)mr.alignment);
   }

   VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                               .allocationSize = total,
                               .memoryTypeIndex = find_memory(pd, bits)};
   VkDeviceMemory mem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   VkImageView views[N];
   for (unsigned i = 0; i < N; i++) {
      CHECK(vkBindImageMemory(dev, images[i], mem, offsets[i]));
      VkImageViewCreateInfo vci = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
         .image = images[i],
         .viewType = shapes[i].type == VK_IMAGE_TYPE_3D ? VK_IMAGE_VIEW_TYPE_3D
                     : shapes[i].layers > 1             ? VK_IMAGE_VIEW_TYPE_2D_ARRAY
                                                        : VK_IMAGE_VIEW_TYPE_2D,
         .format = shapes[i].format,
         .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, shapes[i].levels,
                              0, shapes[i].layers},
      };
      CHECK(vkCreateImageView(dev, &vci, NULL, &views[i]));
   }

   VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = staging,
      .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
   };
   VkBuffer sbuf;
   CHECK(vkCreateBuffer(dev, &bci, NULL, &sbuf));
   VkMemoryRequirements bmr;
   vkGetBufferMemoryRequirements(dev, sbuf, &bmr);
   mai.allocationSize = bmr.size;
   mai.memoryTypeIndex = find_memory(pd, bmr.memoryTypeBits);
   VkDeviceMemory smem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &smem));
   CHECK(vkBindBufferMemory(dev, sbuf, smem, 0));

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
   for (unsigned i = 0; i < N; i++) {
      for (uint32_t level = 0; level < shapes[i].levels; level++) {
         uint32_t w = shapes[i].extent.width >> level;
         uint32_t h = shapes[i].extent.height >> level;
         uint32_t d = shapes[i].extent.depth >> level;
         VkBufferImageCopy region = {
            .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, level, 0,
                                 shapes[i].layers},
            .imageExtent = {w ? w : 1, h ? h : 1, d ? d : 1},
         };
         vkCmdCopyBufferToImage(cmd, sbuf, images[i],
                                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
         vkCmdCopyImageToBuffer(cmd, images[i],
                                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, sbuf, 1,
                                &region);
      }
      if (!(shapes[i].usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT))
         continue;
      VkRenderingAttachmentInfo ca = {
         .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
         .imageView = views[i],
         .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
         .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
         .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
      };
      VkRenderingInfo ri = {
         .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
         .renderArea = {{0, 0},
                        {shapes[i].extent.width, shapes[i].extent.height}},
         .layerCount = 1,
         .colorAttachmentCount = 1,
         .pColorAttachments = &ca,
      };
      vkCmdBeginRendering(cmd, &ri);
      vkCmdEndRendering(cmd);
   }
   CHECK(vkEndCommandBuffer(cmd));
   VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
   CHECK(vkQueueWaitIdle(queue));
   printf("ok linear-images\n");
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
   if (check_device_type())
      return 1;
   if (check_budget_cap(&ici))
      return 1;
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
   VkPhysicalDeviceVulkan12Features v12 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
      .hostQueryReset = VK_TRUE,
   };
   VkPhysicalDeviceVulkan13Features v13 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
      .pNext = &v12,
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
               VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_COUNTER_BUFFER_BIT_EXT |
               VK_BUFFER_USAGE_TRANSFER_DST_BIT,
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

      /* An fcanonicalize kept by an FP32 flush-to-zero execution mode
       * (shaders/texel-ftz.comp.spvasm), in the same layout: the pipeline
       * builds and the MSL has no untranslated ALU op. */
      {
         int ftz_before = msl_count();
         VkComputePipelineCreateInfo fci = cpci;
         fci.stage.module = load_module("texel-ftz.comp");
         VkPipeline fp;
         CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &fci, NULL, &fp));
         if (ftz_before >= 0 && msl_contains(ftz_before, msl_count(), "ALU ")) {
            fprintf(stderr, "texel-ftz: an untranslated ALU op in the MSL\n");
            return 1;
         }
         printf("ok texel-ftz\n");
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

   /* A defined sampler with an undefined image (shaders/undef-image.frag.spvasm):
    * the pipeline builds, and descriptor lowering does not abort. */
   {
      DPROC(vkCreateDescriptorSetLayout);
      VkDescriptorSetLayoutBinding binding = {
         0, VK_DESCRIPTOR_TYPE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
      VkDescriptorSetLayoutCreateInfo dslci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 1,
         .pBindings = &binding,
      };
      VkDescriptorSetLayout dsl;
      CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
      VkPipelineLayoutCreateInfo uplci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &dsl,
      };
      VkPipelineLayout upl;
      CHECK(vkCreatePipelineLayout(dev, &uplci, NULL, &upl));
      struct pipe_desc d = {"undef-image", "pass.vert", NULL, NULL, NULL,
                            "undef-image.frag", TRI, false, FIRST, FILL};
      make_pipeline(&d, upl);
      printf("ok undef-image\n");
   }

   /* Undefined storage images (shaders/undef-storage-image.frag.spvasm and
    * .comp.spvasm): a read, a write, a size query and an atomic, in a
    * fragment and a compute shader. Both pipelines build, and their MSL
    * touches no texture. */
   {
      DPROC(vkCreateComputePipelines);
      int msl_before = msl_count();
      struct pipe_desc d = {"undef-storage-image", "pass.vert", NULL, NULL,
                            NULL, "undef-storage-image.frag", TRI, false,
                            FIRST, FILL};
      make_pipeline(&d, layout);
      VkComputePipelineCreateInfo cpci = {
         .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
         .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = load_module("undef-storage-image.comp"),
            .pName = "main",
         },
         .layout = layout,
      };
      VkPipeline cp;
      CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &cp));
      if (msl_before >= 0 && msl_contains(msl_before, msl_count(), "texture2d")) {
         fprintf(stderr, "undef-storage-image: a texture in the MSL\n");
         return 1;
      }
      printf("ok undef-storage-image\n");
   }

   /* A pipeline-statistics pool without pipelineStatisticsQuery, as Red Dead
    * Redemption 2 makes (8 queries, all 11 counters): it is created, reset,
    * begun and ended around a draw and copied, and its results are 11 zeros
    * per query. The mock runs no GPU work, so the end's availability and the
    * copy are only recorded; the host results are those of the reset. */
   {
      if (f2.features.pipelineStatisticsQuery) {
         fprintf(stderr, "pipelineStatisticsQuery is reported\n");
         return 1;
      }
      DPROC(vkResetQueryPool);
      DPROC(vkCmdBeginQuery);
      DPROC(vkCmdEndQuery);
      DPROC(vkCmdCopyQueryPoolResults);
      VkQueryPoolCreateInfo ci = {
         .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
         .queryType = VK_QUERY_TYPE_PIPELINE_STATISTICS,
         .queryCount = 8,
         .pipelineStatistics = 0x7ff,
      };
      VkQueryPool stats;
      CHECK(vkCreateQueryPool(dev, &ci, NULL, &stats));
      vkResetQueryPool(dev, stats, 0, 8);

      /* 11 counters and the availability, then a guard word the driver
       * must leave alone. */
      const uint64_t guard = 0xa5a5a5a5a5a5a5a5ull;
      uint64_t r64[8][13];
      memset(r64, 0xa5, sizeof(r64));
      VkResult r = vkGetQueryPoolResults(
         dev, stats, 0, 8, sizeof(r64), r64, sizeof(r64[0]),
         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT |
            VK_QUERY_RESULT_PARTIAL_BIT);
      /* Partial results of unavailable queries: KosmicKrisp, like NVK,
       * returns VK_SUCCESS when it wrote every value. */
      if (r != VK_SUCCESS && r != VK_NOT_READY) {
         fprintf(stderr, "statistics after a reset: %d\n", r);
         return 1;
      }
      for (unsigned q = 0; q < 8; q++) {
         for (unsigned j = 0; j < 12; j++) {
            if (r64[q][j] != 0) {
               fprintf(stderr, "statistics query %u value %u is %llx\n", q, j,
                       (unsigned long long)r64[q][j]);
               return 1;
            }
         }
         if (r64[q][12] != guard) {
            fprintf(stderr, "statistics query %u wrote past 11 counters\n", q);
            return 1;
         }
      }
      /* 32-bit, no partial results: only the availability is written. */
      uint32_t r32[2][13];
      memset(r32, 0xa5, sizeof(r32));
      r = vkGetQueryPoolResults(dev, stats, 3, 2, sizeof(r32), r32,
                                sizeof(r32[0]),
                                VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
      if (r != VK_NOT_READY || r32[0][0] != (uint32_t)guard ||
          r32[0][11] != 0 || r32[1][11] != 0 || r32[1][12] != (uint32_t)guard) {
         fprintf(stderr, "32-bit statistics results wrong (%d)\n", r);
         return 1;
      }

      VkPipeline p = make_pipeline(&descs[0], layout);
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
      vkCmdResetQueryPool(cmd, stats, 0, 8);
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
      vkCmdBeginQuery(cmd, stats, 0, 0);
      vkCmdDraw(cmd, 12, 1, 0, 0);
      vkCmdEndQuery(cmd, stats, 0);
      vkCmdBeginQuery(cmd, stats, 1, 0);
      vkCmdDraw(cmd, 3, 1, 0, 0);
      vkCmdEndQuery(cmd, stats, 1);
      vkCmdEndRendering(cmd);
      vkCmdCopyQueryPoolResults(
         cmd, stats, 0, 2, buf, 65536, 12 * sizeof(uint64_t),
         VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT |
            VK_QUERY_RESULT_WAIT_BIT);
      vkCmdCopyQueryPoolResults(cmd, stats, 0, 8, buf, 65536 + 256,
                                11 * sizeof(uint32_t),
                                VK_QUERY_RESULT_PARTIAL_BIT);
      CHECK(vkEndCommandBuffer(cmd));
      VkSubmitInfo si = {
         .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
         .commandBufferCount = 1,
         .pCommandBuffers = &cmd,
      };
      CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(queue));
      printf("ok pipeline-statistics-without-feature\n");
   }

   /* Pipelines with rasterizationSamples 8 on a device whose sample counts
    * are 1, 2 and 4, as Red Dead Redemption 2 builds 96 (its images are
    * clamped to 4): drawn into a 4-sample image, and without attachments.
    * The mock aborts on a raster sample count the device does not
    * support. */
   {
      if (props.limits.framebufferColorSampleCounts & VK_SAMPLE_COUNT_8_BIT) {
         fprintf(stderr, "the device reports 8 samples\n");
         return 1;
      }
      VkImageCreateInfo msci = imci;
      msci.samples = VK_SAMPLE_COUNT_4_BIT;
      VkImage ms_image;
      CHECK(vkCreateImage(dev, &msci, NULL, &ms_image));
      vkGetImageMemoryRequirements(dev, ms_image, &mr);
      mai.allocationSize = mr.size;
      mai.memoryTypeIndex = find_memory(pd, mr.memoryTypeBits);
      VkDeviceMemory ms_mem;
      CHECK(vkAllocateMemory(dev, &mai, NULL, &ms_mem));
      CHECK(vkBindImageMemory(dev, ms_image, ms_mem, 0));
      VkImageViewCreateInfo msvci = ivci;
      msvci.image = ms_image;
      VkImageView ms_view;
      CHECK(vkCreateImageView(dev, &msvci, NULL, &ms_view));

      struct pipe_desc d8 = {"samples-8", "pass.vert", NULL, NULL, NULL,
                             "color.frag", TRI, false, FIRST, FILL};
      d8.samples = VK_SAMPLE_COUNT_8_BIT;
      VkPipeline p8 = make_pipeline(&d8, layout);
      d8.no_attachments = true;
      VkPipeline p8_none = make_pipeline(&d8, layout);

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
      VkRenderingAttachmentInfo ca = {
         .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
         .imageView = ms_view,
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
      VkViewport vpt = {0, 0, 64, 64, 0, 1};
      VkRect2D sc = {{0, 0}, {64, 64}};
      VkDeviceSize off = 0;
      VkPipeline pipes[2] = {p8, p8_none};
      for (unsigned i = 0; i < 2; i++) {
         ri.colorAttachmentCount = i == 0 ? 1 : 0;
         vkCmdBeginRendering(cmd, &ri);
         vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipes[i]);
         vkCmdSetViewport(cmd, 0, 1, &vpt);
         vkCmdSetScissor(cmd, 0, 1, &sc);
         vkCmdBindVertexBuffers(cmd, 0, 1, &buf, &off);
         vkCmdDraw(cmd, 12, 1, 0, 0);
         vkCmdEndRendering(cmd);
      }
      CHECK(vkEndCommandBuffer(cmd));
      VkSubmitInfo si = {
         .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
         .commandBufferCount = 1,
         .pCommandBuffers = &cmd,
      };
      CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(queue));
      printf("ok samples-8-on-a-4-sample-device\n");
   }

   /* Texel fetches from a sampled 4-sample, 2-layer image through a 2D array
    * view, in a module that declares ImageMSArray
    * (shaders/ms-array.frag.spvasm) while shaderStorageImageMultisample is
    * not reported, as 73 of Red Dead Redemption 2's modules do. */
   {
      if (f2.features.shaderStorageImageMultisample) {
         fprintf(stderr, "shaderStorageImageMultisample is reported\n");
         return 1;
      }
      DPROC(vkCreateDescriptorSetLayout);
      DPROC(vkCreateDescriptorPool);
      DPROC(vkAllocateDescriptorSets);
      DPROC(vkUpdateDescriptorSets);
      DPROC(vkCmdBindDescriptorSets);

      VkImageCreateInfo msci = imci;
      msci.samples = VK_SAMPLE_COUNT_4_BIT;
      msci.arrayLayers = 2;
      msci.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
      VkImage ms_image;
      CHECK(vkCreateImage(dev, &msci, NULL, &ms_image));
      vkGetImageMemoryRequirements(dev, ms_image, &mr);
      mai.allocationSize = mr.size;
      mai.memoryTypeIndex = find_memory(pd, mr.memoryTypeBits);
      VkDeviceMemory ms_mem;
      CHECK(vkAllocateMemory(dev, &mai, NULL, &ms_mem));
      CHECK(vkBindImageMemory(dev, ms_image, ms_mem, 0));
      VkImageViewCreateInfo msvci = ivci;
      msvci.image = ms_image;
      msvci.viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY;
      msvci.subresourceRange.layerCount = 2;
      VkImageView ms_view;
      CHECK(vkCreateImageView(dev, &msvci, NULL, &ms_view));

      VkDescriptorSetLayoutBinding binding = {
         0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_FRAGMENT_BIT};
      VkDescriptorSetLayoutCreateInfo dslci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
         .bindingCount = 1,
         .pBindings = &binding,
      };
      VkDescriptorSetLayout dsl;
      CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
      VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1};
      VkDescriptorPoolCreateInfo dpci = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
         .maxSets = 1,
         .poolSizeCount = 1,
         .pPoolSizes = &size,
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
      VkDescriptorImageInfo dii = {
         .imageView = ms_view,
         .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
      };
      VkWriteDescriptorSet write = {
         .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
         .dstSet = ds,
         .dstBinding = 0,
         .descriptorCount = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
         .pImageInfo = &dii,
      };
      vkUpdateDescriptorSets(dev, 1, &write, 0, NULL);
      VkPipelineLayoutCreateInfo mplci = {
         .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
         .setLayoutCount = 1,
         .pSetLayouts = &dsl,
      };
      VkPipelineLayout mpl;
      CHECK(vkCreatePipelineLayout(dev, &mplci, NULL, &mpl));

      int msl_before = msl_count();
      struct pipe_desc d = {"ms-array", "pass.vert", NULL, NULL, NULL,
                            "ms-array.frag", TRI, false, FIRST, FILL};
      VkPipeline p = make_pipeline(&d, mpl);
      if (msl_before >= 0 &&
          !msl_contains(msl_before, msl_count(), "texture2d_ms_array<float>")) {
         fprintf(stderr, "ms-array: no texture2d_ms_array in the MSL\n");
         return 1;
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
      vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, mpl, 0, 1,
                              &ds, 0, NULL);
      VkViewport vpt = {0, 0, 64, 64, 0, 1};
      VkRect2D sc = {{0, 0}, {64, 64}};
      vkCmdSetViewport(cmd, 0, 1, &vpt);
      vkCmdSetScissor(cmd, 0, 1, &sc);
      VkDeviceSize off = 0;
      vkCmdBindVertexBuffers(cmd, 0, 1, &buf, &off);
      vkCmdDraw(cmd, 12, 1, 0, 0);
      vkCmdEndRendering(cmd);
      CHECK(vkEndCommandBuffer(cmd));
      VkSubmitInfo si = {
         .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
         .commandBufferCount = 1,
         .pCommandBuffers = &cmd,
      };
      CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
      CHECK(vkQueueWaitIdle(queue));
      printf("ok ms-array\n");
   }

   if (check_linear_images(pd, queue, pool))
      return 1;
   return 0;
}
