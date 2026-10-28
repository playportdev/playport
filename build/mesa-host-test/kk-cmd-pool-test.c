/* SPDX-License-Identifier: GPL-3.0-or-later
 * Exercise real kk_pool_alloc and Vulkan command-buffer/pool lifetimes on
 * mock Metal, and the staging size of a depth/stencil-to-colour image copy. Link the driver's archives to observe private state. No copy
 * of the pooling algorithm, and no GPU execution is claimed.
 */
#include "kk_cmd_buffer.h"
#include "kk_cmd_pool.h"
#include "kk_device.h"
#include "kk_entrypoints.h"
#include "vk_common_entrypoints.h"
#include "util/u_atomic.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(call) assert((call) == VK_SUCCESS)

static VkDevice device;
static VkCommandPool pool;
static VkCommandBuffer commands[2];
static struct kk_cmd_pool *p;
static struct kk_device *d;

static void
begin(unsigned i)
{
   const VkCommandBufferBeginInfo info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
   };
   CHECK(kk_BeginCommandBuffer(commands[i], &info));
}

static struct kk_cmd_bo *
last_bo(unsigned i)
{
   struct kk_cmd_buffer *cmd = kk_cmd_buffer_from_handle(commands[i]);
   return list_last_entry(&cmd->large_bos, struct kk_cmd_bo, link);
}

static struct kk_ptr
allocate(unsigned i, uint32_t size, uint32_t expected_size)
{
   struct kk_ptr ptr = kk_pool_alloc(kk_cmd_buffer_from_handle(commands[i]), size, 8);
   assert(ptr.cpu && ptr.gpu && ptr.buffer && ptr.offset == 0);
   if (last_bo(i)->bo->size_B != expected_size) {
      fprintf(stderr, "command %u request %u: heap %" PRIu64 ", expected %u\n",
              i, size, last_bo(i)->bo->size_B, expected_size);
      abort();
   }
   assert(last_bo(i)->bo->kind == KK_BO_KIND_COMMAND);
   /* Upload clients must still receive writable, distinct storage. */
   memset(ptr.cpu, 0x5a + i, size);
   return ptr;
}

static void
reset(unsigned i)
{
   CHECK(vk_common_ResetCommandBuffer(commands[i], 0));
   assert(p->large_free_bytes <= KK_CMD_LARGE_BO_CACHE_MAX);
   assert(list_is_empty(&kk_cmd_buffer_from_handle(commands[i])->large_bos));
}

static void
trim(void)
{
   kk_TrimCommandPool(device, pool, 0);
   assert(p->large_free_bytes == 0);
   assert(list_is_empty(&p->large_lru));
   assert(p->num_free_bos == 0);
   for (unsigned i = 0; i < KK_CMD_LARGE_BO_CLASSES; i++)
      assert(list_is_empty(&p->large_free_bos[i]));
}

static void
expect_pooled(uint64_t bytes, unsigned count)
{
   assert(p->large_free_bytes == bytes);
   assert(p_atomic_read(&kk_memory_stats.bo_bytes[KK_BO_KIND_COMMAND_POOL]) == bytes);
   assert(p_atomic_read(&kk_memory_stats.bo_count[KK_BO_KIND_COMMAND_POOL]) == count);
}

static VkImage
image(VkFormat format, VkImageUsageFlags usage, VkDeviceMemory *memory)
{
   const VkImageCreateInfo ci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D, .format = format,
      .extent = {1300, 600, 1}, .mipLevels = 1, .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = usage | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
   };
   VkImage handle;
   CHECK(kk_CreateImage(device, &ci, NULL, &handle));
   const VkImageMemoryRequirementsInfo2 ri = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
      .image = handle,
   };
   VkMemoryRequirements2 mr = {.sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2};
   kk_GetImageMemoryRequirements2(device, &ri, &mr);
   const VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mr.memoryRequirements.size,
      .memoryTypeIndex = __builtin_ctz(mr.memoryRequirements.memoryTypeBits),
   };
   CHECK(kk_AllocateMemory(device, &mai, NULL, memory));
   const VkBindImageMemoryInfo bi = {
      .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
      .image = handle, .memory = *memory,
   };
   CHECK(kk_BindImageMemory2(device, 1, &bi));
   return handle;
}

/* The Witcher 3 copies the depth of its 1300x600 D32_SFLOAT_S8_UINT target
 * into an R32_SFLOAT image every frame. Metal has no colour view of a depth
 * texture, so it goes through a buffer, which holds the depth alone (4 bytes
 * a texel, 3,120,000 B): a 4 MiB command BO, not the 8 MiB the 8-byte
 * depth/stencil format would size. A stencil aspect is 1 byte a texel. */
static void
check_depth_to_colour_copy(void)
{
   VkDeviceMemory memory[3];
   VkImage ds = image(VK_FORMAT_D32_SFLOAT_S8_UINT,
                      VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, &memory[0]);
   VkImage r32 = image(VK_FORMAT_R32_SFLOAT, VK_IMAGE_USAGE_SAMPLED_BIT, &memory[1]);
   VkImage r8 = image(VK_FORMAT_R8_UINT, VK_IMAGE_USAGE_SAMPLED_BIT, &memory[2]);
   const struct {
      VkImage dst;
      VkImageAspectFlags aspect;
      uint64_t bo_size;
   } cases[] = {
      {r32, VK_IMAGE_ASPECT_DEPTH_BIT, 4u << 20},
      {r8, VK_IMAGE_ASPECT_STENCIL_BIT, 1u << 20},
   };
   for (unsigned i = 0; i < 2; i++) {
      const VkImageCopy2 region = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_COPY_2,
         .srcSubresource = {cases[i].aspect, 0, 0, 1},
         .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
         .extent = {1300, 600, 1},
      };
      const VkCopyImageInfo2 info = {
         .sType = VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2,
         .srcImage = ds, .srcImageLayout = VK_IMAGE_LAYOUT_GENERAL,
         .dstImage = cases[i].dst, .dstImageLayout = VK_IMAGE_LAYOUT_GENERAL,
         .regionCount = 1, .pRegions = &region,
      };
      begin(1);
      kk_CmdCopyImage2(commands[1], &info);
      struct kk_cmd_buffer *cmd = kk_cmd_buffer_from_handle(commands[1]);
      assert(!list_is_empty(&cmd->large_bos));
      if (last_bo(1)->bo->size_B != cases[i].bo_size) {
         fprintf(stderr, "copy aspect 0x%x: staging BO %" PRIu64 ", expected %" PRIu64 "\n",
                 cases[i].aspect, last_bo(1)->bo->size_B, cases[i].bo_size);
         abort();
      }
      CHECK(kk_EndCommandBuffer(commands[1]));
      reset(1);
      trim(); /* the next case must not reuse this BO */
   }
   kk_DestroyImage(device, ds, NULL);
   kk_DestroyImage(device, r32, NULL);
   kk_DestroyImage(device, r8, NULL);
   for (unsigned i = 0; i < 3; i++)
      kk_FreeMemory(device, memory[i], NULL);
   puts("ok copy image: a depth or stencil aspect into colour stages in its own format's size");
}

int
main(void)
{
   VkInstance instance;
   const VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .apiVersion = VK_API_VERSION_1_3,
   };
   const VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
   };
   CHECK(kk_CreateInstance(&ici, NULL, &instance));
   uint32_t count = 1;
   VkPhysicalDevice physical;
   CHECK(vk_common_EnumeratePhysicalDevices(instance, &count, &physical));
   const float priority = 1;
   const VkDeviceQueueCreateInfo queue = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1, .pQueuePriorities = &priority,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue,
   };
   CHECK(kk_CreateDevice(physical, &dci, NULL, &device));
   const VkCommandPoolCreateInfo pci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
   };
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &pool));
   const VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 2,
   };
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, commands));
   p = kk_cmd_pool_from_handle(pool);
   d = kk_device_from_handle(device);
   expect_pooled(0, 0);

   /* The exact regression: retain the heap at reset and reuse it, without
    * modifying residency. Never recycle at End or while another recording
    * still owns it. The mock never recycles addresses, so identities are
    * meaningful even for BOs evicted in later cases.
    */
   begin(0);
   struct kk_ptr first = allocate(0, 208 * 1024, 256 * 1024);
   CHECK(kk_EndCommandBuffer(commands[0]));
   expect_pooled(0, 0);
   begin(1);
   struct kk_ptr concurrent = allocate(1, 208 * 1024, 256 * 1024);
   assert(first.buffer != concurrent.buffer);
   d->residency_set.dirty = false;
   reset(0);
   expect_pooled(256 * 1024, 1);
   assert(!d->residency_set.dirty);
   const int64_t created = p_atomic_read(&kk_memory_stats.command_large_allocations);
   const int64_t reused = p_atomic_read(&kk_memory_stats.command_large_reuses);
   for (unsigned i = 0; i < 100; i++) {
      begin(0);
      struct kk_ptr again = allocate(0, 208 * 1024, 256 * 1024);
      assert(first.buffer == again.buffer);
      CHECK(kk_EndCommandBuffer(commands[0]));
      reset(0);
      assert(!d->residency_set.dirty);
   }
   assert(p_atomic_read(&kk_memory_stats.command_large_allocations) == created);
   assert(p_atomic_read(&kk_memory_stats.command_large_reuses) == reused + 100);
   trim(); /* must not free the other command buffer's live allocation */
   assert(*(unsigned char *)concurrent.cpu == 0x5b);
   assert(p_atomic_read(&kk_memory_stats.bo_count[KK_BO_KIND_COMMAND]) == 1);
   reset(1);
   trim();
   puts("ok command pool: 100 reset/reuses, no new heaps or residency deltas; live recordings isolated");

   /* Independent pools may not lend each other idle allocations. */
   VkCommandPool other_pool;
   VkCommandBuffer other_cmd;
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &other_pool));
   VkCommandBufferAllocateInfo other_ai = ai;
   other_ai.commandPool = other_pool;
   other_ai.commandBufferCount = 1;
   CHECK(vk_common_AllocateCommandBuffers(device, &other_ai, &other_cmd));
   const VkCommandBufferBeginInfo bi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
   };
   CHECK(kk_BeginCommandBuffer(other_cmd, &bi));
   struct kk_ptr other = kk_pool_alloc(kk_cmd_buffer_from_handle(other_cmd), 200 * 1024, 8);
   assert(other.cpu);
   CHECK(vk_common_ResetCommandBuffer(other_cmd, 0));
   assert(kk_cmd_pool_from_handle(other_pool)->large_free_bytes == 256 * 1024);
   assert(p->large_free_bytes == 0);
   begin(0);
   assert(allocate(0, 200 * 1024, 256 * 1024).buffer != other.buffer);
   kk_DestroyCommandPool(device, other_pool, NULL);
   reset(0);
   trim();

   /* Initialize/reinitialize the original small cache correctly, including
    * its exact count cap after trim, not 33 BOs or an uninitialized count. */
   for (unsigned round = 0; round < 2; round++) {
      begin(0);
      for (unsigned i = 0; i < KK_CMD_POOL_BO_MAX + 2; i++)
         assert(kk_pool_alloc(kk_cmd_buffer_from_handle(commands[0]), 128 * 1024, 8).cpu);
      reset(0);
      assert(p->num_free_bos == KK_CMD_POOL_BO_MAX);
      trim();
   }
   puts("ok command pool: independent pools, exact 32-small-BO cap before and after trim");

   /* An alignment larger than the request selects a sufficient size class
    * on both fresh and reused BOs, just as a fresh kk_alloc_bo would round. */
   begin(0);
   struct kk_ptr aligned = kk_pool_alloc(kk_cmd_buffer_from_handle(commands[0]), 200 * 1024, 512 * 1024);
   assert(aligned.cpu && last_bo(0)->bo->size_B == 512 * 1024);
   reset(0);
   begin(0);
   assert(kk_pool_alloc(kk_cmd_buffer_from_handle(commands[0]), 200 * 1024, 512 * 1024).buffer == aligned.buffer);
   reset(0);
   trim();

   /* Class boundaries, oversize bypass, and the original small uploader. */
   begin(0);
   struct kk_ptr small = kk_pool_alloc(kk_cmd_buffer_from_handle(commands[0]), 128 * 1024, 8);
   assert(small.cpu && list_is_empty(&kk_cmd_buffer_from_handle(commands[0])->large_bos));
   allocate(0, 128 * 1024 + 1, 256 * 1024);
   for (unsigned log = 18; log <= 24; log++) {
      allocate(0, 1u << log, 1u << log);
      if (log < 24)
         allocate(0, (1u << log) + 1, 1u << (log + 1));
   }
   allocate(0, (16u << 20) + 1, (16u << 20) + 256);
   reset(0);
   assert(p_atomic_read(&kk_memory_stats.bo_count[KK_BO_KIND_COMMAND]) == p->num_free_bos);
   assert(p->large_free_bytes <= KK_CMD_LARGE_BO_CACHE_MAX);
   trim();
   puts("ok command pool: 128 KiB boundary, all seven classes, >16 MiB bypass, small BO accounting after trim");

   /* LRU across classes: a returned small BO, then five 16 MiB BOs, must
    * retain the newest four large BOs. Touching one moves it to the newest
    * position; the next return evicts the other oldest BO, not the touched
    * one. Actual Metal heap sizes, not request bytes, count against the cap.
    */
   begin(0);
   allocate(0, 200 * 1024, 256 * 1024);
   reset(0);
   begin(0);
   struct kk_ptr large[5];
   for (unsigned i = 0; i < 5; i++)
      large[i] = allocate(0, 16u << 20, 16u << 20);
   reset(0);
   expect_pooled(64u << 20, 4);
   kk_memory_log(d);
   begin(0);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == large[1].buffer);
   reset(0);
   begin(0);
   for (unsigned i = 2; i < 5; i++)
      assert(allocate(0, 16u << 20, 16u << 20).buffer == large[i].buffer);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == large[1].buffer);
   struct kk_ptr newest = allocate(0, 16u << 20, 16u << 20);
   reset(0);
   expect_pooled(64u << 20, 4);
   begin(0);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == large[3].buffer);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == large[4].buffer);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == large[1].buffer);
   assert(allocate(0, 16u << 20, 16u << 20).buffer == newest.buffer);
   CHECK(kk_ResetCommandPool(device, pool, 0));
   expect_pooled(64u << 20, 4);
   CHECK(kk_ResetCommandPool(device, pool, VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT));
   expect_pooled(0, 0);
   puts("ok command pool: 64 MiB actual-byte cap, cross-class LRU, pool reset and release-resources reset");

   /* Best fit and reuse across command buffers: Begin's implicit reset and
    * FreeCommandBuffers return resources to the same owning pool. */
   begin(0);
   first = allocate(0, 600 * 1024, 1u << 20);
   CHECK(kk_EndCommandBuffer(commands[0]));
   begin(0);
   assert(allocate(0, 500 * 1024, 1u << 20).buffer == first.buffer);
   vk_common_FreeCommandBuffers(device, pool, 1, commands);
   begin(1);
   assert(allocate(1, 500 * 1024, 1u << 20).buffer == first.buffer);
   reset(1);
   trim();

   /* An allocation failure discards idle heaps and retries, and a failure
    * without idle heaps is still latched into vkEndCommandBuffer. */
   begin(1);
   allocate(1, 200 * 1024, 256 * 1024);
   reset(1);
   begin(1);
   setenv("KK_MOCK_FAIL_NEXT_HEAP", "1", 1);
   allocate(1, 1u << 20, 1u << 20);
   expect_pooled(0, 0);
   reset(1);
   trim();
   begin(1);
   setenv("KK_MOCK_FAIL_NEXT_HEAP", "1", 1);
   struct kk_ptr failed = kk_pool_alloc(kk_cmd_buffer_from_handle(commands[1]), 1u << 20, 8);
   assert(!failed.cpu && !failed.gpu);
   assert(kk_EndCommandBuffer(commands[1]) == VK_ERROR_OUT_OF_DEVICE_MEMORY);
   reset(1);
   puts("ok command pool: implicit Begin reset, free/reallocate, best fit, OOM cache eviction/retry and error latch");

   trim();
   check_depth_to_colour_copy();

   /* Destruction includes both active and already pooled allocations. */
   begin(1);
   allocate(1, 200 * 1024, 256 * 1024);
   CHECK(kk_EndCommandBuffer(commands[1]));
   begin(1);
   allocate(1, 1u << 20, 1u << 20);
   kk_DestroyCommandPool(device, pool, NULL);
   assert(p_atomic_read(&kk_memory_stats.bo_count[KK_BO_KIND_COMMAND]) == 0);
   assert(p_atomic_read(&kk_memory_stats.bo_count[KK_BO_KIND_COMMAND_POOL]) == 0);
   kk_DestroyDevice(device, NULL);
   for (unsigned i = 0; i < KK_BO_KIND_COUNT; i++) {
      assert(p_atomic_read(&kk_memory_stats.bo_count[i]) == 0);
      assert(p_atomic_read(&kk_memory_stats.bo_bytes[i]) == 0);
   }
   kk_DestroyInstance(instance, NULL);
   puts("ok command pool: destruction drains active and cached BOs; every BO census back to zero");
   return 0;
}
