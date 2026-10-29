/* SPDX-License-Identifier: GPL-3.0-or-later */
/* PLA-466: real queue replay and profiler lifetime on mock Metal. All mock
 * timestamps are synthetic; this proves no GPU timing or pipeline occupancy. */
#include "kk_cmd_buffer.h"
#include "kk_device.h"
#include "kk_entrypoints.h"
#include "kk_physical_device.h"
#include "kosmickrisp/bridge/mtl_bridge.h"
#include "vk_common_entrypoints.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#define CHECK(call) assert((call) == VK_SUCCESS)

int main(int argc, char **argv)
{
   const char *mode = argc > 1 ? argv[1] : "on";
   bool on = strcmp(mode, "off") && strcmp(mode, "capture");
   setenv("KK_MOCK_DEFER_FEEDBACK", "1", 1);
   if (strcmp(mode, "off")) setenv("MESA_KK_PASS_PROF", "1", 1);
   if (!strcmp(mode, "capture")) {
      setenv("MESA_KK_GPU_CAPTURE_FRAME", "999999", 1);
      setenv("KK_MOCK_REFUSE_COUNTER_HEAP", "1", 1);
   }
   if (!strcmp(mode, "off")) setenv("KK_MOCK_REFUSE_COUNTER_HEAP", "1", 1);
   VkInstance instance;
   VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
   CHECK(kk_CreateInstance(&ici, NULL, &instance));
   uint32_t count = 1;
   VkPhysicalDevice physical;
   CHECK(vk_common_EnumeratePhysicalDevices(instance, &count, &physical));
   float priority = 1;
   VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1, .pQueuePriorities = &priority};
   VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
   VkDevice device;
   CHECK(kk_CreateDevice(physical, &dci, NULL, &device));
   struct kk_device *d = kk_device_from_handle(device);
   struct kk_queue *q = &d->queue;
   assert(q->pass_prof_enabled == on);
   mtl_event *event = mtl_new_event(d->mtl_handle);
   VkCommandPool pool;
   VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &pool));
   VkCommandBuffer cb;
   VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .commandBufferCount = 1, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY};
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, &cb));
   VkBuffer buffer;
   VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = 4096, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT};
   CHECK(kk_CreateBuffer(device, &bci, NULL, &buffer));
   VkDeviceMemory mem;
   VkMemoryAllocateInfo mi = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = 4096, .memoryTypeIndex = 0};
   CHECK(kk_AllocateMemory(device, &mi, NULL, &mem));
   VkBindBufferMemoryInfo bi = {.sType = VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO,
      .buffer = buffer, .memory = mem};
   CHECK(kk_BindBufferMemory2(device, 1, &bi));
   struct kk_cmd_buffer *cmd = kk_cmd_buffer_from_handle(cb);
   struct vk_command_buffer *vk_cmd = &cmd->vk;
   struct vk_queue_submit submit = {.command_buffer_count = 1, .command_buffers = &vk_cmd};
   for (unsigned once = 0; once < 2; once++) {
      VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
         .flags = once ? VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT : 0};
      CHECK(kk_BeginCommandBuffer(cb, &begin));
      VkBufferCopy2 region = {.sType = VK_STRUCTURE_TYPE_BUFFER_COPY_2, .dstOffset = 128, .size = 64};
      VkCopyBufferInfo2 copy = {.sType = VK_STRUCTURE_TYPE_COPY_BUFFER_INFO_2,
         .srcBuffer = buffer, .dstBuffer = buffer, .regionCount = 1, .pRegions = &region};
      d->exposed_dispatch_table.CmdCopyBuffer2(cb, &copy);
      CHECK(kk_EndCommandBuffer(cb));
      assert(!list_is_empty(&cmd->vk.cmd_queue.cmds) == (!once || on));
      /* Original recording finished ahead of the sample. It must be replayed
       * even on its first submission (including ONE_TIME_SUBMIT). */
      q->pass_prof_presents = 599;
      CHECK(q->vk.driver_submit(&q->vk, &submit));
      assert((q->pass_prof != NULL) == on);
      assert(q->commits_in_flight == (on ? 1 : 0));
      kk_pass_prof_present(q); /* close before deferred completion */
      assert(!q->pass_prof);
      mtl_signal_event(q->mtl_handle, event, 0); /* mock's signal drains feedback */
      assert(q->commits_in_flight == 0);
      /* The second frame of the pair uses the reusable replay path. */
      if (!once) {
         CHECK(q->vk.driver_submit(&q->vk, &submit));
         kk_pass_prof_present(q);
         mtl_signal_event(q->mtl_handle, event, 0);
      }
   }
   if (on) {
      /* Classify known dispatch, mixed native-copy + dispatch, and empty
       * encoders. No GPU executes on this mock; only the first gets a
       * synthetic timed interval. The other two must be explicitly NA. */
      for (unsigned mode = 0; mode < 3; mode++) {
         q->pass_prof_presents = 2999 + mode * 1200;
         kk_pass_prof_before_submit(q);
         assert(q->pass_prof);
         VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
         CHECK(kk_BeginCommandBuffer(cb, &begin));
         kk_pass_prof_attach(cmd, q->pass_prof);
         cs_get_compute(cmd);
         if (mode != 2)
            kk_pass_prof_pipeline(cmd, d->precompiled_cache.shaders[0].pipeline);
         if (mode == 1)
            kk_pass_prof_copy(cmd);
         cs_end(cmd);
         CHECK(kk_EndCommandBuffer(cb));
         cmd->pass_prof = NULL;
         kk_pass_prof_present(q);
      }
      q->pass_prof_presents = 598;
      kk_pass_prof_before_submit(q);
      assert(!q->pass_prof);
      kk_pass_prof_present(q);
      kk_pass_prof_before_submit(q);
      assert(q->pass_prof);
      /* Exercise overflow and an unfinished frame. Neither emits a summary. */
      VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
      CHECK(kk_BeginCommandBuffer(cb, &begin));
      kk_pass_prof_attach(cmd, q->pass_prof);
      for (unsigned i = 0; i < 2050; i++) {
         cs_get_compute(cmd);
         cs_end(cmd);
      }
      CHECK(kk_EndCommandBuffer(cb));
      cmd->pass_prof = NULL;
      kk_pass_prof_present(q);
      q->pass_prof_presents = 1799;
      kk_pass_prof_before_submit(q);
      assert(q->pass_prof);
      kk_pass_prof_queue_finish(q);
   }
   mtl_release(event);
   kk_DestroyCommandPool(device, pool, NULL);
   kk_DestroyBuffer(device, buffer, NULL);
   kk_FreeMemory(device, mem, NULL);
   kk_DestroyDevice(device, NULL);
   kk_DestroyInstance(instance, NULL);
   puts("ok pass profile: schedule, reusable and one-shot replay, deferred completion, overflow, tail, off/capture guard");
   return 0;
}
