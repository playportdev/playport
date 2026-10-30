/* SPDX-License-Identifier: GPL-3.0-or-later
 * patches/mesa 0132 and 0133: MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes
 * on the real driver and mock Metal, with completions deferred to the next
 * queue signal (KK_MOCK_DEFER_FEEDBACK). A ONE_TIME primary's upload BOs and
 * allocator hold go back to its pool when its commit completes, not at its
 * late reset; an idle allocator is reset at the next Begin, a tainted one
 * destroyed; seal at 8 MiB and sharing past four unsealed; finer large-BO
 * classes; a reusable primary keeps its holds; a pool destroy waits for a
 * retirement still in flight. No GPU runs.
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
#include "util/u_atomic.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK(call) assert((call) == VK_SUCCESS)
#define KIB 1024u

void kk_mock_set_size(void *handle, uint64_t size);

static VkDevice device;
static VkCommandPool pool;
static struct kk_cmd_pool *p;
static struct kk_queue *q;
static mtl_event *event;
static VkCommandBuffer c[8];

static struct kk_cmd_buffer *
cmd(unsigned i)
{
   return kk_cmd_buffer_from_handle(c[i]);
}

static void
begin(unsigned i, VkCommandBufferUsageFlags flags)
{
   const VkCommandBufferBeginInfo info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = flags,
   };
   CHECK(kk_BeginCommandBuffer(c[i], &info));
}

static void
begin_once(unsigned i)
{
   begin(i, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
}

static void
submit(unsigned i)
{
   struct vk_command_buffer *vk_cmd = &cmd(i)->vk;
   struct vk_queue_submit s = {.command_buffer_count = 1,
                               .command_buffers = &vk_cmd};
   CHECK(q->vk.driver_submit(&q->vk, &s));
}

/* The mock runs every deferred completion before a queue signal */
static void
complete(void)
{
   mtl_signal_event(q->mtl_handle, event, 0);
}

/* A large request and the heap it got */
static struct kk_ptr
allocate(unsigned i, uint32_t size, uint32_t expected_B)
{
   struct kk_ptr ptr = kk_pool_alloc(cmd(i), size, 8);
   assert(ptr.cpu);
   struct kk_cmd_bo *bo =
      list_last_entry(&cmd(i)->large_bos, struct kk_cmd_bo, link);
   if (bo->bo->size_B != expected_B) {
      fprintf(stderr, "request %u: heap %" PRIu64 ", expected %u\n", size,
              bo->bo->size_B, expected_B);
      abort();
   }
   return ptr;
}

static void *
destroy_pool(void *done)
{
   kk_DestroyCommandPool(device, pool, NULL);
   p_atomic_set((int *)done, 1);
   return NULL;
}

static void
expect(const char *log, const char *line)
{
   if (!strstr(log, line)) {
      fprintf(stderr, "kk-cmd-retire-test: no \"%s\" in:\n%s", line, log);
      abort();
   }
}

int
main(void)
{
   setenv("MESA_KK_EXPERIMENTAL", "cmd_retire,cmd_bo_classes", 1);
   setenv("MESA_KK_DEBUG", "memory", 1);
   setenv("KK_MOCK_DEFER_FEEDBACK", "1", 1);
   VkInstance instance;
   const VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
   CHECK(kk_CreateInstance(&ici, NULL, &instance));
   assert(KK_EXPERIMENTAL(CMD_RETIRE) && KK_EXPERIMENTAL(CMD_BO_CLASSES));
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
   struct kk_device *d = kk_device_from_handle(device);
   q = &d->queue;
   event = mtl_new_event(d->mtl_handle);
   const VkCommandPoolCreateInfo pci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
   };
   CHECK(kk_CreateCommandPool(device, &pci, NULL, &pool));
   p = kk_cmd_pool_from_handle(pool);
   const VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 8,
   };
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, c));
   /* Listed in the census; a submit logs nothing until the end */
   kk_mesa_debug_flags &= ~KK_DEBUG_MEMORY;
   const struct kk_cmd_retire_stats *stats = &kk_cmd_retire_stats;

   /* 1. RDR2's mean tessellation ask (0.54 MiB) gets 640 KiB, not 1 MiB.
    * At submit the buffer gives up its BOs and allocator hold; at completion
    * the pool has them, before the buffer's late reset. */
   begin_once(0);
   struct kk_cmd_allocator *a = cmd(0)->metal.encoded_in;
   kk_mock_set_size(cmd(0)->metal.allocator, 1u << 20);
   struct kk_ptr first = allocate(0, 553 * KIB, 640 * KIB);
   assert(kk_pool_alloc(cmd(0), 16, 8).cpu); /* one 128 KiB BO */
   CHECK(kk_EndCommandBuffer(c[0]));
   assert(p_atomic_read(&a->users) == 1u && !a->sealed && !a->tainted);
   submit(0);
   assert(list_is_empty(&cmd(0)->large_bos) &&
          list_is_empty(&cmd(0)->uploader.bos) &&
          cmd(0)->metal.encoded_in == NULL && cmd(0)->census.upload_B == 0u);
   assert(p->retire.in_flight == 1u && p_atomic_read(&a->users) == 1u);
   assert(p->large_free_bytes == 0u && p->num_free_bos == 0u);
   assert(stats->in_flight == 1 && stats->in_flight_B == (640 + 128) * KIB);
   complete();
   assert(p->retire.in_flight == 0u && p_atomic_read(&a->users) == 0u);
   assert(p->large_free_bytes == 640 * KIB && p->num_free_bos == 1u);
   assert(stats->in_flight == 0 && stats->retired == 1);
   CHECK(vk_common_ResetCommandBuffer(c[0], 0)); /* late, holds nothing */
   assert(!a->tainted && p->large_free_bytes == 640 * KIB);
   puts("ok command retire: a ONE_TIME recording's BOs and allocator hold return at completion");

   /* 2. The idle allocator is reset at the next Begin and the BO reused */
   const int64_t resets = stats->allocator_resets;
   begin_once(1);
   assert(cmd(1)->metal.encoded_in == a && stats->allocator_resets == resets + 1);
   assert(mtl_command_allocator_allocated_size(a->handle) == 0u);
   assert(allocate(1, 600 * KIB, 640 * KIB).buffer == first.buffer);
   CHECK(kk_EndCommandBuffer(c[1]));
   submit(1);
   complete();
   puts("ok command retire: the next Begin resets the allocator without users");

   /* 3. Released without a commit: tainted, then destroyed, never reset */
   begin_once(2);
   assert(cmd(2)->metal.encoded_in == a);
   CHECK(kk_EndCommandBuffer(c[2]));
   CHECK(vk_common_ResetCommandBuffer(c[2], 0));
   assert(a->tainted && p_atomic_read(&a->users) == 0u &&
          stats->allocator_taints == 1);
   const void *tainted_handle = a->handle;
   const int64_t resets_before_destroy = stats->allocator_resets;
   begin_once(3);
   assert(stats->allocator_destroys == 1 &&
          stats->allocator_resets == resets_before_destroy);
   assert(cmd(3)->metal.encoded_in->handle != tainted_handle &&
          p->metal.allocator_count == 1u);
   CHECK(kk_EndCommandBuffer(c[3]));
   submit(3);
   complete();
   puts("ok command retire: an allocator released uncommitted is destroyed, not reset");

   /* 4. Sealed past 8 MiB: in flight it takes no recording; four unsealed
    * ones, then the least-filled is shared */
   begin_once(4);
   struct kk_cmd_allocator *sealed = cmd(4)->metal.encoded_in;
   kk_mock_set_size(cmd(4)->metal.allocator, 9u << 20);
   CHECK(kk_EndCommandBuffer(c[4]));
   assert(sealed->sealed && p->metal.sealed_count == 1u &&
          stats->allocator_seals == 1);
   submit(4);
   const unsigned unsealed[4] = {5, 6, 7, 0};
   struct kk_cmd_allocator *least = NULL;
   for (unsigned k = 0; k < 4; k++) {
      begin_once(unsealed[k]);
      struct kk_cmd_allocator *got = cmd(unsealed[k])->metal.encoded_in;
      assert(got != sealed && !got->sealed);
      kk_mock_set_size(got->handle, (uint64_t)(k + 1) << 20);
      if (k == 0)
         least = got;
      CHECK(kk_EndCommandBuffer(c[unsealed[k]]));
      submit(unsealed[k]);
   }
   assert(p->metal.allocator_count == 5u);
   begin_once(1);
   assert(cmd(1)->metal.encoded_in == least && stats->allocator_shares == 1 &&
          p_atomic_read(&least->users) == 2u && p->metal.allocator_count == 5u);
   CHECK(kk_EndCommandBuffer(c[1]));
   submit(1);
   complete();
   assert(p->retire.in_flight == 0u && p_atomic_read(&least->users) == 0u);
   const int64_t resets_after_drain = stats->allocator_resets;
   begin_once(2);
   assert(stats->allocator_resets == resets_after_drain + 1 &&
          p->metal.allocator_count == 5u);
   CHECK(kk_EndCommandBuffer(c[2]));
   submit(2);
   complete();
   puts("ok command retire: seal at 8 MiB, four unsealed, then the least-filled is shared");

   /* 5. Quarter-octave classes, and no reuse of a cached BO over twice the
    * ask's class. The cached 640 KiB heap takes the first ask. */
   begin_once(3);
   assert(allocate(3, 553 * KIB, 640 * KIB).buffer == first.buffer);
   const struct kk_ptr b320 = allocate(3, 300 * KIB, 320 * KIB);
   const struct kk_ptr b1280 = allocate(3, 1100 * KIB, 1280 * KIB);
   allocate(3, (2u << 20) + 1, 4u << 20);
   CHECK(kk_EndCommandBuffer(c[3]));
   submit(3);
   complete();
   assert(p->large_free_bytes == (640 + 320 + 1280 + 4096) * KIB);
   begin_once(4);
   assert(allocate(4, 1100 * KIB, 1280 * KIB).buffer == b1280.buffer);
   assert(allocate(4, 300 * KIB, 320 * KIB).buffer == b320.buffer);
   assert(allocate(4, 300 * KIB, 640 * KIB).buffer == first.buffer);
   const int64_t made = p_atomic_read(&kk_memory_stats.command_large_allocations);
   allocate(4, 300 * KIB, 320 * KIB); /* only 4 MiB is cached: a new heap */
   assert(p_atomic_read(&kk_memory_stats.command_large_allocations) == made + 1);
   CHECK(kk_EndCommandBuffer(c[4]));
   submit(4);
   complete();
   puts("ok command BO classes: 320 KiB, 640 KiB, 1280 KiB; reuse up to twice the class");

   /* 6. A reusable primary keeps its holds until its reset. From here a
    * 200 KiB ask (class 256 KiB) takes a cached 320 KiB heap. */
   begin(5, 0);
   allocate(5, 200 * KIB, 320 * KIB);
   CHECK(kk_EndCommandBuffer(c[5]));
   const uint32_t in_flight = p->retire.in_flight;
   submit(5);
   assert(p->retire.in_flight == in_flight);
   complete();
   assert(!list_is_empty(&cmd(5)->large_bos) && cmd(5)->metal.encoded_in);
   CHECK(vk_common_ResetCommandBuffer(c[5], 0));
   assert(list_is_empty(&cmd(5)->large_bos));
   puts("ok command retire: a reusable primary keeps its holds until reset");

   /* 7. A ONE_TIME buffer submitted twice (invalid): the second submit
    * re-records and retires nothing more */
   begin_once(6);
   allocate(6, 200 * KIB, 320 * KIB);
   CHECK(kk_EndCommandBuffer(c[6]));
   const int64_t retired = stats->retired;
   submit(6);
   submit(6);
   assert(p->retire.in_flight == 1u);
   complete();
   assert(p->retire.in_flight == 0u && stats->retired == retired + 1 &&
          q->commits_in_flight == 0u);
   puts("ok command retire: a second submit of a ONE_TIME buffer retires once");

   /* 8. A recording begun again after a committed one starts uncommitted:
    * released without a commit, it taints its allocator */
   const int64_t taints = stats->allocator_taints;
   begin_once(6);
   struct kk_cmd_allocator *again = cmd(6)->metal.encoded_in;
   assert(!cmd(6)->metal.committed && !again->tainted);
   CHECK(kk_EndCommandBuffer(c[6]));
   CHECK(vk_common_ResetCommandBuffer(c[6], 0));
   assert(again->tainted && stats->allocator_taints == taints + 1);
   puts("ok command retire: a recording after a committed one taints if released uncommitted");

   /* 9. A pool destroy waits for a retirement still in flight */
   begin_once(7);
   allocate(7, 200 * KIB, 320 * KIB);
   CHECK(kk_EndCommandBuffer(c[7]));
   submit(7);
   int destroyed = 0;
   pthread_t thread;
   assert(pthread_create(&thread, NULL, destroy_pool, &destroyed) == 0);
   usleep(50000);
   assert(!p_atomic_read(&destroyed));
   complete();
   assert(pthread_join(thread, NULL) == 0 && p_atomic_read(&destroyed));
   puts("ok command retire: a pool destroy waits for the completion");

   /* 10. The census's retire line */
   kk_mesa_debug_flags |= KK_DEBUG_MEMORY;
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
   expect(log, "[kk-cmd-retire] in-flight=0 (0.0 MiB) retired=");
   char counts[128];
   snprintf(counts, sizeof(counts),
            "sealed=1 tainted=2 destroyed=%" PRId64 " shared=1",
            stats->allocator_destroys);
   expect(log, counts);

   mtl_release(event);
   kk_DestroyDevice(device, NULL);
   kk_DestroyInstance(instance, NULL);
   puts("ok command retire: [kk-cmd-retire] census line");
   return 0;
}
