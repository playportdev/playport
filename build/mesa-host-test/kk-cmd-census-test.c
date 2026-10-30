/* SPDX-License-Identifier: GPL-3.0-or-later
 * patches/mesa 0131: with MESA_KK_DEBUG=memory, the [kk-cmd-census] and
 * [kk-upload] lines, on the real driver and mock Metal. A reusable primary
 * submitted twice (once direct, once replayed through a queue re-record)
 * still holds its upload BOs and what it added to its allocator; a ONE_TIME
 * primary submitted once and a never-submitted secondary are released; a
 * caller's large request counts asked, rounded and live bytes. No GPU runs.
 */
#include "kk_bo.h"
#include "kk_cmd_buffer.h"
#include "kk_cmd_pool.h"
#include "kk_debug.h"
#include "kk_device.h"
#include "kk_entrypoints.h"
#include "kk_queue.h"
#include "vk_common_entrypoints.h"
#include "kosmickrisp/bridge/mtl_bridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(call) assert((call) == VK_SUCCESS)

void kk_mock_set_size(void *handle, uint64_t size);

static void
expect(const char *log, const char *line)
{
   if (!strstr(log, line)) {
      fprintf(stderr, "kk-cmd-census-test: no \"%s\" in:\n%s", line, log);
      abort();
   }
}

int
main(void)
{
   setenv("MESA_KK_DEBUG", "memory", 1);
   setenv("KK_MOCK_DEFER_FEEDBACK", "1", 1);
   VkInstance instance;
   const VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
   CHECK(kk_CreateInstance(&ici, NULL, &instance));
   uint32_t count = 1;
   VkPhysicalDevice physical;
   CHECK(vk_common_EnumeratePhysicalDevices(instance, &count, &physical));
   const float priority = 1;
   const VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1, .pQueuePriorities = &priority,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
   };
   VkDevice device;
   CHECK(kk_CreateDevice(physical, &dci, NULL, &device));
   struct kk_device *d = kk_device_from_handle(device);
   struct kk_queue *q = &d->queue;
   mtl_event *event = mtl_new_event(d->mtl_handle);

   const VkCommandPoolCreateInfo pci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
   };
   VkCommandPool pool;
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &pool));
   VkCommandBuffer primaries[2], secondary;
   VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 2,
   };
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, primaries));
   ai.level = VK_COMMAND_BUFFER_LEVEL_SECONDARY;
   ai.commandBufferCount = 1;
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, &secondary));
   struct kk_cmd_buffer *reusable = kk_cmd_buffer_from_handle(primaries[0]);
   struct kk_cmd_buffer *once = kk_cmd_buffer_from_handle(primaries[1]);
   struct kk_cmd_buffer *second = kk_cmd_buffer_from_handle(secondary);
   assert(reusable->census.listed && once->census.listed && second->census.listed);

   /* The reusable primary: 3 MiB into its allocator, one large request
    * (200 KiB, rounded to 256 KiB) and one small upload (a 128 KiB BO) */
   static struct kk_upload_site big = {"census-big", 1};
   static struct kk_upload_site small = {"census-small", 2};
   const VkCommandBufferBeginInfo reuse_begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
   };
   CHECK(kk_BeginCommandBuffer(primaries[0], &reuse_begin));
   assert(reusable->census.begin_ns != 0 && reusable->census.flags == 0u);
   kk_mock_set_size(reusable->metal.allocator, 3u << 20);
   assert(kk_pool_alloc_at(reusable, 200 * 1024, 8, &big).cpu);
   const uint32_t word = 7u;
   assert(kk_pool_upload_at(reusable, &word, sizeof(word), 4, &small).cpu);
   CHECK(kk_EndCommandBuffer(primaries[0]));
   assert(reusable->census.alloc_added_B == (3u << 20));
   assert(reusable->census.upload_B == 256 * 1024 + KK_CMD_BO_SIZE);
   assert(big.calls == 1 && big.bytes == 200 * 1024 && big.large_calls == 1 &&
          big.large_bytes == 200 * 1024 && big.large_rounded_B == 256 * 1024 &&
          big.large_live_B == 256 * 1024);
   assert(small.calls == 1 && small.bytes == 4 && small.large_calls == 0);

   /* A submit with MESA_KK_DEBUG=memory logs the census; this test logs it
    * once, at the end. What a submit counts needs only the listing. */
   kk_mesa_debug_flags &= ~KK_DEBUG_MEMORY;

   /* Submitted twice: its own encoding, then a re-record of the queue's */
   struct vk_command_buffer *vk_cmd = &reusable->vk;
   struct vk_queue_submit submit = {.command_buffer_count = 1,
                                    .command_buffers = &vk_cmd};
   CHECK(q->vk.driver_submit(&q->vk, &submit));
   assert(reusable->census.submits == 1u && reusable->census.first_submit_ns != 0);
   mtl_signal_event(q->mtl_handle, event, 0);
   CHECK(q->vk.driver_submit(&q->vk, &submit));
   assert(reusable->census.submits == 2u);
   mtl_signal_event(q->mtl_handle, event, 0);
   assert(q->commits_in_flight == 0u);
   /* The queue's re-record, made while the flag was off and so not listed */
   assert(util_dynarray_num_elements(&q->free_cmd_buffers,
                                     struct vk_command_buffer *) == 1u);
   struct kk_cmd_buffer *rerecord = container_of(
      *util_dynarray_element(&q->free_cmd_buffers, struct vk_command_buffer *, 0),
      struct kk_cmd_buffer, vk);
   assert(rerecord->census.queue_owned && !rerecord->census.listed);

   /* A ONE_TIME primary submitted once and released, and a secondary
    * released without a submit */
   const VkCommandBufferBeginInfo once_begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   CHECK(kk_BeginCommandBuffer(primaries[1], &once_begin));
   CHECK(kk_EndCommandBuffer(primaries[1]));
   vk_cmd = &once->vk;
   CHECK(q->vk.driver_submit(&q->vk, &submit));
   mtl_signal_event(q->mtl_handle, event, 0);
   CHECK(vk_common_ResetCommandBuffer(primaries[1], 0));
   assert(once->census.begin_ns == 0);
   const VkCommandBufferInheritanceInfo inherit = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO,
   };
   const VkCommandBufferBeginInfo second_begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .pInheritanceInfo = &inherit,
   };
   kk_mesa_debug_flags |= KK_DEBUG_MEMORY;
   CHECK(kk_BeginCommandBuffer(secondary, &second_begin));
   CHECK(kk_EndCommandBuffer(secondary));
   CHECK(vk_common_ResetCommandBuffer(secondary, 0));

   /* The first kk_memory_log prints the census */
   int pipe_fds[2];
   assert(pipe(pipe_fds) == 0);
   fflush(stderr);
   const int saved = dup(2);
   dup2(pipe_fds[1], 2);
   kk_memory_log(d);
   fflush(stderr);
   dup2(saved, 2);
   close(pipe_fds[1]);
   static char log[65536];
   size_t got = 0;
   ssize_t n;
   while ((n = read(pipe_fds[0], log + got, sizeof(log) - 1 - got)) > 0)
      got += n;
   log[got] = '\0';
   close(pipe_fds[0]);
   fputs(log, stdout);

   /* The two primaries and the secondary */
   expect(log, "[kk-cmd-census] s=0.0 buffers=3 idle=2 held upload=0.4 alloc-added=3.0 MiB");
   expect(log, "reusable-primary submits direct=1 replayed=1");
   expect(log, "released by hold <1s/1-10s/10-60s/>60s=1/0/0/0 (0.0/0.0/0.0/0.0 MiB) unsubmitted=1 (0.0 MiB)");
   expect(log, "[kk-cmd-census] app primary reusable pool=-+reset submitted-2+ n=1 upload=0.4 alloc-added=3.0 MiB age <1s/1-10s/10-60s/>60s=1/0/0/0");
   expect(log, "[kk-upload] census-big:1 calls=1 MiB=0.2 (+0.2) large=1 asked=0.2 rounded=0.2 live=0.2 MiB");
   expect(log, "[kk-upload] census-small:2 calls=1 MiB=0.0 (+0.0) large=0");

   /* Releasing the reusable primary ends its large BO's live bytes */
   CHECK(vk_common_ResetCommandBuffer(primaries[0], 0));
   assert(big.large_live_B == 0 && reusable->census.begin_ns == 0);
   kk_DestroyCommandPool(device, pool, NULL);
   mtl_release(event);
   kk_DestroyDevice(device, NULL);
   kk_DestroyInstance(instance, NULL);
   puts("ok command census: held recording by bucket, direct and replayed submits, releases by hold, upload sites");
   return 0;
}
