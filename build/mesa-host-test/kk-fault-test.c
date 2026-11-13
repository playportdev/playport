/* SPDX-License-Identifier: GPL-3.0-or-later
 * patches/mesa 0154 (PLA-880): a failed commit, on the real driver and mock
 * Metal (make-mock-bridge.py's KK_MOCK_COMMIT_ERROR fails every commit with a
 * two-level error chain). Always: the error chain Metal gave and the commit's
 * timing. With MESA_KK_DEBUG=fault: each encoder is labelled with its command
 * buffer's serial, its index, its kind and what it encoded; the failed commit
 * logs the encoders of its command buffer and the state of the geometry heap
 * (the 128 MiB scratch of tessellation, geometry shaders and strip unrolls),
 * and a completed command buffer that used the heap logs a new high-water
 * mark. Linked to the driver's archives (run-cmd-pool-test.py). The mock runs
 * no GPU work: the heap's header and the ring of usage the driver reads are
 * written here, as the GPU would.
 */
#include "kk_bo.h"
#include "kk_buffer.h"
#include "kk_cmd_buffer.h"
#include "kk_debug.h"
#include "kk_device.h"
#include "kk_entrypoints.h"
#include "kk_fault.h"
#include "kk_queue.h"
#include "vk_common_entrypoints.h"
#include "poly/geometry.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(call) assert((call) == VK_SUCCESS)
#define MIB (1024u * 1024u)

static VkDevice device;
static struct kk_device *d;
static struct kk_queue *q;
static VkBuffer buffers[2];

/* stderr while fn(arg) runs */
static char *
capture(void (*fn)(void *), void *arg)
{
   static char log[1 << 16];
   int fds[2];
   assert(pipe(fds) == 0);
   fflush(stderr);
   const int saved = dup(2);
   dup2(fds[1], 2);
   fn(arg);
   fflush(stderr);
   dup2(saved, 2);
   close(saved);
   close(fds[1]);
   size_t got = 0;
   ssize_t n;
   while ((n = read(fds[0], log + got, sizeof(log) - 1 - got)) > 0)
      got += n;
   log[got] = '\0';
   close(fds[0]);
   return log;
}

static void
expect(const char *log, const char *what)
{
   if (!strstr(log, what)) {
      fprintf(stderr, "kk-fault-test: no \"%s\" in:\n%s\n", what, log);
      abort();
   }
}

static void
create_device(void *unused)
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
   const VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1, .pQueuePriorities = &priority,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
   };
   CHECK(kk_CreateDevice(physical, &dci, NULL, &device));
}

static void
create_buffers(void)
{
   for (unsigned i = 0; i < 2; i++) {
      const VkBufferCreateInfo bci = {
         .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
         .size = 4096,
         .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                  VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      };
      CHECK(kk_CreateBuffer(device, &bci, NULL, &buffers[i]));
      const VkMemoryAllocateInfo mai = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
         .allocationSize = 4096,
      };
      VkDeviceMemory mem;
      CHECK(kk_AllocateMemory(device, &mai, NULL, &mem));
      const VkBindBufferMemoryInfo bind = {
         .sType = VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO,
         .buffer = buffers[i], .memory = mem,
      };
      CHECK(kk_BindBufferMemory2(device, 1, &bind));
   }
}

/* Two buffer copies, one compute encoder; heap marks a geometry heap reset
 * in it, as kk_heap encodes one before a draw's first use of the heap. */
static struct kk_cmd_buffer *
record(VkCommandBuffer handle, bool heap)
{
   struct kk_cmd_buffer *cmd = kk_cmd_buffer_from_handle(handle);
   const VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   CHECK(kk_BeginCommandBuffer(handle, &begin));
   const VkBufferCopy2 region = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_COPY_2, .size = 256,
   };
   const VkCopyBufferInfo2 info = {
      .sType = VK_STRUCTURE_TYPE_COPY_BUFFER_INFO_2,
      .srcBuffer = buffers[0], .dstBuffer = buffers[1],
      .regionCount = 1, .pRegions = &region,
   };
   kk_CmdCopyBuffer2(handle, &info);
   kk_CmdCopyBuffer2(handle, &info);
   if (heap)
      kk_fault_heap_reset(cmd, cs_get_compute(cmd));
   CHECK(kk_EndCommandBuffer(handle));
   return cmd;
}

static struct kk_cmd_buffer *submitted;

static void
submit(void *arg)
{
   struct vk_command_buffer *vk_cmd = &submitted->vk;
   struct vk_queue_submit s = {.command_buffer_count = 1,
                               .command_buffers = &vk_cmd};
   CHECK(q->vk.driver_submit(&q->vk, &s));
}

static VkCommandBuffer cbs[3], recording;

/* Records `recording` (with a heap reset unless it is cbs[2]) */
static void
record_one(void *unused)
{
   submitted = record(recording, recording != cbs[2]);
}

/* The geometry heap as the GPU leaves it: a header with the bytes the last
 * user allocated, and in the usage ring the bytes each reset found. */
static void
set_heap(uint32_t bottom_B)
{
   struct poly_heap *h = d->heap->cpu;
   h->base = d->heap->gpu + sizeof(*h);
   h->size = d->heap->size_B - sizeof(*h);
   h->bottom = bottom_B;
}

static void
set_ring(uint32_t slot, uint32_t bottom_B)
{
   ((uint32_t *)d->fault.ring->cpu)[slot % KK_FAULT_RING] = bottom_B;
}

int
main(void)
{
   setenv("MESA_KK_DEBUG", "fault", 1);
   setenv("KK_MOCK_TRACE_ENCODERS", "1", 1);
   char *log = capture(create_device, NULL);
   expect(log, "[kk-fault] on: encoder labels, command buffer trails, geometry "
               "heap ring; Metal encoder status: unavailable");
   d = kk_device_from_handle(device);
   q = &d->queue;
   assert(d->fault.ring && d->fault.ring->cpu);
   create_buffers();

   const VkCommandPoolCreateInfo pci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
   };
   VkCommandPool pool;
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &pool));
   const VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 3,
   };
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, cbs));

   /* A geometry heap of 2 MiB (the driver's is 128 MiB) */
   CHECK(kk_alloc_bo(d, &d->vk.base, 2 * MIB + sizeof(struct poly_heap), 0,
                     &d->heap));

   /* Completed, with the heap: its encoders are labelled and nothing fails;
    * the reset's slot shows 1 MiB, a new high-water mark. */
   char want[256];
   recording = cbs[0];
   log = capture(record_one, NULL);
   const uint32_t first = submitted->fault.serial;
   assert(first != 0u);
   assert(util_dynarray_num_elements(&submitted->fault.trail,
                                     struct kk_fault_encoder) == 1u);
   snprintf(want, sizeof(want),
            "kk-mock-enc: label kk#%u.0 compute dispatches=0 copies=2 heap", first);
   expect(log, want);
   set_heap(512 * 1024);
   set_ring(d->fault.ring_next - 1u, 1 * MIB);
   log = capture(submit, NULL);
   snprintf(want, sizeof(want),
            "[kk-fault] geometry heap high-water 1.0 MiB of 2.0 MiB (cb #%u)", first);
   expect(log, want);
   assert(!strstr(log, "[kk-fault] cb #"));
   assert(!vk_device_is_lost_no_report(&d->vk));
   puts("ok fault: a completed command buffer's encoders are labelled; a heap "
        "high-water mark is logged");

   /* Failed: the error chain and timing, the command buffer's encoders, and
    * a heap that overflowed (3 MiB asked of 2) */
   recording = cbs[1];
   capture(record_one, NULL);
   const uint32_t failed = submitted->fault.serial;
   assert(failed > first);
   set_heap(3 * MIB);
   set_ring(d->fault.ring_next - 1u, 5 * MIB / 2);
   setenv("KK_MOCK_COMMIT_ERROR", "1", 1);
   log = capture(submit, NULL);
   unsetenv("KK_MOCK_COMMIT_ERROR");
   expect(log, "[kk-queue] commit done error=1 ");
   expect(log, "[kk-queue] error: domain=kk-mock code=1 desc=\"mock timeout\"\n");
   expect(log, "[kk-queue] error:   underlying: domain=kk-mock-gpu code=3 "
               "desc=\"mock page fault\"\n");
   expect(log, "[kk-queue] error timing: commit->gpu-start=1.0 ms gpu=2.0 ms "
               "gpu-end->feedback=0.5 ms commit->feedback=3.5 ms\n");
   snprintf(want, sizeof(want),
            "[kk-fault] cb #%u failed (error=1): encoders=1 render=0 compute=1 "
            "draws=0 dispatches=0 copies=2 flags=heap last-completed=#%u\n",
            failed, first);
   expect(log, want);
   snprintf(want, sizeof(want),
            "[kk-fault] cb #%u enc 0 compute dispatches=0 copies=2 heap\n", failed);
   expect(log, want);
   expect(log, "[kk-fault] geometry heap: last user's bottom=3.0 MiB of 2.0 MiB "
               "OVERFLOW\n");
   snprintf(want, sizeof(want),
            "[kk-fault] geometry heap resets: 2 recorded, largest 2.5 MiB found "
            "by the reset in cb #%u, 1 over the heap\n", failed);
   expect(log, want);
   assert(vk_device_is_lost_no_report(&d->vk));
   puts("ok fault: a failed commit logs its error chain, timing, encoders and "
        "the geometry heap");

   /* The geometry heap's overflow guard (poly/geometry.h): what fits, and a
    * tessellated draw's worst case. 1500 quad patches at tessellation factor
    * 64 (24576 indices each) want about 422 MiB of the 128; 1000 at factor 8
    * (384 indices each) about 4.4 MiB. No sum wraps. */
   const uint32_t heap_B = 128u * MIB;
   assert(poly_heap_fits(0u, heap_B, heap_B));
   assert(!poly_heap_fits(16u, heap_B, heap_B));
   assert(!poly_heap_fits(heap_B + 16u, heap_B, 0u));
   assert(!poly_heap_fits(0u, heap_B, 1ull << 40));
   assert(!poly_heap_fits(0u, heap_B, poly_tess_heap_bytes(1500u * 24576u, 1500u)));
   assert(poly_heap_fits(0u, heap_B, poly_tess_heap_bytes(1000u * 384u, 1000u)));
   assert(poly_tess_heap_bytes(UINT32_MAX, UINT32_MAX) > (uint64_t)UINT32_MAX * 12u);
   puts("ok fault: the geometry heap guard refuses what does not fit, without wrapping");

   /* Without the flag nothing is labelled or traced */
   kk_mesa_debug_flags &= ~KK_DEBUG_FAULT;
   recording = cbs[2];
   log = capture(record_one, NULL);
   assert(!strstr(log, "label kk#"));
   assert(kk_cmd_buffer_from_handle(cbs[2])->fault.serial == 0u);
   puts("ok fault: without MESA_KK_DEBUG=fault no command buffer is traced");
   return 0;
}
