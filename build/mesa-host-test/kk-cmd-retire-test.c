/* SPDX-License-Identifier: GPL-3.0-or-later
 * patches/mesa 0132-0135: MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes
 * on the real driver and mock Metal, with completions deferred to the next
 * queue signal (KK_MOCK_DEFER_FEEDBACK). A ONE_TIME primary's upload BOs and
 * allocator hold go back to its pool when its commit completes, not at its
 * late reset; an idle allocator is reset at the next Begin, a tainted or
 * sealed one destroyed; seal at 8 MiB and sharing past four unsealed; finer
 * large-BO classes; a reusable primary keeps its holds; a recording that
 * encodes nothing begins no Metal command buffer and taints nothing; a pool
 * keeps four idle allocators and makes at most eight; an RDR2-like load
 * keeps the pool within the cap; [kk-mem] logs early while allocators grow;
 * a pool destroy waits for a retirement still in flight. The mock keeps an
 * allocator's size across a reset, as Metal keeps its heaps, and aborts a
 * reset of an allocator a command buffer was begun on and not committed. No
 * GPU runs.
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
unsigned kk_mock_command_buffer_begins(void);

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
begin_cb(VkCommandBuffer cb, VkCommandBufferUsageFlags flags)
{
   const VkCommandBufferBeginInfo info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = flags,
   };
   CHECK(kk_BeginCommandBuffer(cb, &info));
}

static void
begin(unsigned i, VkCommandBufferUsageFlags flags)
{
   begin_cb(c[i], flags);
}

/* Opens an encoder, which begins the Metal command buffer */
static void
encode_cb(VkCommandBuffer cb)
{
   assert(cs_get_compute(kk_cmd_buffer_from_handle(cb)));
}

static void
encode(unsigned i)
{
   encode_cb(c[i]);
}

static void
begin_once(unsigned i)
{
   begin(i, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
}

static void
submit_cb(VkCommandBuffer cb)
{
   struct vk_command_buffer *vk_cmd = &kk_cmd_buffer_from_handle(cb)->vk;
   struct vk_queue_submit s = {.command_buffer_count = 1,
                               .command_buffers = &vk_cmd};
   CHECK(q->vk.driver_submit(&q->vk, &s));
}

static void
submit(unsigned i)
{
   submit_cb(c[i]);
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

/* kk_memory_log's stderr */
static void
capture_memory_log(struct kk_device *d, char *log, size_t size)
{
   int pipe_fds[2];
   assert(pipe(pipe_fds) == 0);
   fflush(stderr);
   const int saved = dup(2);
   dup2(pipe_fds[1], 2);
   kk_memory_log(d);
   fflush(stderr);
   dup2(saved, 2);
   close(saved);
   close(pipe_fds[1]);
   size_t got = 0;
   ssize_t n;
   while ((n = read(pipe_fds[0], log + got, size - 1 - got)) > 0)
      got += n;
   log[got] = '\0';
   close(pipe_fds[0]);
}

static void
new_pool(VkCommandPool *out, VkCommandBuffer *cbs, uint32_t count)
{
   const VkCommandPoolCreateInfo pci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
   };
   CHECK(kk_CreateCommandPool(device, &pci, NULL, out));
   const VkCommandBufferAllocateInfo ai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = *out, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = count,
   };
   CHECK(vk_common_AllocateCommandBuffers(device, &ai, cbs));
}

/* kk_cmd_pool.c's KK_CMD_POOL_ALLOCATOR_CAP */
#define POOL_CAP 8u
#define MIB (1024u * 1024u)

/* The RDR2-like load's allocator heaps: Metal's grow to the most a recording
 * in them since their reset used, and a reset keeps them */
struct heap {
   const void *handle;
   uint64_t used;
};
static struct heap heaps[512];
static unsigned heap_count;

static struct heap *
heap_of(const void *handle)
{
   for (unsigned k = 0; k < heap_count; k++)
      if (heaps[k].handle == handle)
         return &heaps[k];
   assert(heap_count < 512u);
   heaps[heap_count] = (struct heap){handle, 0u};
   return &heaps[heap_count++];
}

static void
begin_load(VkCommandBuffer cb)
{
   const struct kk_cmd_retire_stats *stats = &kk_cmd_retire_stats;
   const int64_t resets = stats->allocator_resets;
   begin_cb(cb, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
   struct heap *h = heap_of(kk_cmd_buffer_from_handle(cb)->metal.allocator);
   if (stats->allocator_resets != resets)
      h->used = 0u;
}

/* A recording encodes `size` into its allocator */
static void
encode_load(VkCommandBuffer cb, uint64_t size)
{
   struct kk_cmd_buffer *k = kk_cmd_buffer_from_handle(cb);
   encode_cb(cb);
   struct heap *h = heap_of(k->metal.allocator);
   h->used += size;
   if (h->used > mtl_command_allocator_allocated_size(k->metal.allocator))
      kk_mock_set_size(k->metal.allocator, h->used);
}

/* The pool's allocators not recording now, and their sizes */
static uint64_t
pool_free_bytes(struct kk_cmd_pool *pool, uint64_t *largest)
{
   uint64_t total = 0u;
   *largest = 0u;
   util_dynarray_foreach(&pool->metal.free_allocators,
                         struct kk_cmd_allocator *, a) {
      const uint64_t size = mtl_command_allocator_allocated_size((*a)->handle);
      total += size;
      if (size > *largest)
         *largest = size;
   }
   return total;
}

/* 9-13: the allocator rules on pools of their own */
static void
pool_rules(struct kk_device *d)
{
   const struct kk_cmd_retire_stats *stats = &kk_cmd_retire_stats;
   (void)d;

   /* 9. Hollow Knight's frame: DXVK begins a spare ONE_TIME buffer after a
    * submission and submits it only if used, then resets the pool. The spare
    * encodes nothing, so no Metal command buffer begins, and it taints no
    * allocator: none is destroyed and remade a frame. */
   {
      VkCommandPool hk;
      VkCommandBuffer cb[2];
      new_pool(&hk, cb, 2);
      struct kk_cmd_pool *hp = kk_cmd_pool_from_handle(hk);
      const int64_t taints = stats->allocator_taints;
      const int64_t destroys = stats->allocator_destroys;
      const int64_t unbegun = stats->unbegun;
      const unsigned begins = kk_mock_command_buffer_begins();
      for (unsigned f = 0; f < 50; f++) {
         begin_cb(cb[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
         encode_cb(cb[0]);
         CHECK(kk_EndCommandBuffer(cb[0]));
         begin_cb(cb[1], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
         assert(!kk_cmd_buffer_from_handle(cb[1])->metal.begun);
         CHECK(kk_EndCommandBuffer(cb[1]));
         submit_cb(cb[0]);
         complete();
         CHECK(kk_ResetCommandPool(device, hk, 0));
         assert(hp->metal.allocator_count <= 2u);
      }
      assert(stats->allocator_taints == taints &&
             stats->allocator_destroys == destroys &&
             stats->unbegun == unbegun + 50 &&
             kk_mock_command_buffer_begins() == begins + 50u);
      /* An empty ONE_TIME buffer submitted: nothing to commit or retire */
      const int64_t retired = stats->retired;
      begin_cb(cb[1], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      CHECK(kk_EndCommandBuffer(cb[1]));
      submit_cb(cb[1]);
      complete();
      assert(stats->retired == retired && hp->retire.in_flight == 0u);
      kk_DestroyCommandPool(device, hk, NULL);
      puts("ok command retire: a recording that encodes nothing begins no Metal command buffer and taints nothing");
   }

   /* 10. Nine recording at once: eight allocators, the cap, then one past it
    * (an allocator serves one recording at a time). Once idle, a Begin keeps
    * four and destroys the rest. */
   {
      VkCommandPool cp;
      VkCommandBuffer cb[10];
      new_pool(&cp, cb, 10);
      struct kk_cmd_pool *pp = kk_cmd_pool_from_handle(cp);
      const int64_t over = stats->allocator_over_cap;
      for (unsigned k = 0; k < 9; k++) {
         begin_cb(cb[k], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
         encode_cb(cb[k]);
      }
      assert(pp->metal.allocator_count == POOL_CAP + 1u &&
             stats->allocator_over_cap == over + 1);
      for (unsigned k = 0; k < 9; k++) {
         CHECK(kk_EndCommandBuffer(cb[k]));
         submit_cb(cb[k]);
      }
      complete();
      const int64_t trims = stats->allocator_trims;
      begin_cb(cb[9], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      assert(pp->metal.allocator_count == KK_CMD_POOL_UNSEALED_MAX &&
             stats->allocator_trims == trims + 5);
      CHECK(kk_EndCommandBuffer(cb[9]));
      kk_DestroyCommandPool(device, cp, NULL);
      puts("ok command retire: eight allocators a pool, one past it only when all record; four kept idle");
   }

   /* 11. At the cap with every allocator sealed and in flight, a Begin shares
    * the least-filled sealed one; once idle all are destroyed */
   {
      VkCommandPool cp;
      VkCommandBuffer cb[9];
      new_pool(&cp, cb, 9);
      struct kk_cmd_pool *pp = kk_cmd_pool_from_handle(cp);
      struct kk_cmd_allocator *least = NULL;
      for (unsigned k = 0; k < POOL_CAP; k++) {
         begin_cb(cb[k], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
         encode_cb(cb[k]);
         struct kk_cmd_buffer *kc = kk_cmd_buffer_from_handle(cb[k]);
         kk_mock_set_size(kc->metal.allocator, (uint64_t)(9u + k) * MIB);
         if (k == 0)
            least = kc->metal.encoded_in;
      }
      for (unsigned k = 0; k < POOL_CAP; k++) {
         CHECK(kk_EndCommandBuffer(cb[k]));
         submit_cb(cb[k]);
      }
      assert(pp->metal.sealed_count == POOL_CAP);
      const int64_t capped = stats->allocator_capped_shares;
      begin_cb(cb[8], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      assert(kk_cmd_buffer_from_handle(cb[8])->metal.encoded_in == least &&
             stats->allocator_capped_shares == capped + 1 &&
             p_atomic_read(&least->users) == 2u &&
             pp->metal.allocator_count == POOL_CAP);
      encode_cb(cb[8]);
      CHECK(kk_EndCommandBuffer(cb[8]));
      submit_cb(cb[8]);
      complete();
      const int64_t releases = stats->allocator_releases;
      begin_cb(cb[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      assert(stats->allocator_releases == releases + POOL_CAP &&
             pp->metal.allocator_count == 1u && pp->metal.sealed_count == 0u);
      CHECK(kk_EndCommandBuffer(cb[0]));
      kk_DestroyCommandPool(device, cp, NULL);
      puts("ok command retire: at the cap a sealed allocator is shared, and destroyed once idle");
   }

   /* 12. An RDR2-like load step: 40 frames of 12 ONE_TIME recordings of
    * 3 MiB, two recording at a time, each re-begun two frames later, a frame
    * in flight. Under 0132's rules every allocator that passed 8 MiB kept its
    * heaps and was sealed again after each reset, and the pool made another;
    * here the pool stays at the cap, sealed ones go when idle, and after the
    * drain four are kept, each at most 8 MiB. */
   {
      VkCommandPool cp;
      VkCommandBuffer cb[24];
      new_pool(&cp, cb, 24);
      struct kk_cmd_pool *pp = kk_cmd_pool_from_handle(cp);
      const int64_t over = stats->allocator_over_cap;
      const int64_t releases = stats->allocator_releases;
      uint32_t most = 0u;
      for (unsigned f = 0; f < 40; f++) {
         VkCommandBuffer *set = &cb[(f % 2u) * 12u];
         for (unsigned k = 0; k < 12; k += 2) {
            begin_load(set[k]);
            begin_load(set[k + 1]);
            encode_load(set[k], 3u * MIB);
            encode_load(set[k + 1], 3u * MIB);
            CHECK(kk_EndCommandBuffer(set[k]));
            CHECK(kk_EndCommandBuffer(set[k + 1]));
            submit_cb(set[k]);
            submit_cb(set[k + 1]);
            if (pp->metal.allocator_count > most)
               most = pp->metal.allocator_count;
            assert(pp->metal.allocator_count <= POOL_CAP);
         }
         complete();
      }
      assert(stats->allocator_over_cap == over &&
             stats->allocator_releases > releases);
      begin_cb(cb[0], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      uint64_t largest;
      const uint64_t idle_B = pool_free_bytes(pp, &largest);
      assert(pp->metal.allocator_count <= KK_CMD_POOL_UNSEALED_MAX &&
             largest <= KK_CMD_ALLOCATOR_SEAL_B &&
             idle_B <= (KK_CMD_POOL_UNSEALED_MAX - 1u) * KK_CMD_ALLOCATOR_SEAL_B);
      CHECK(kk_EndCommandBuffer(cb[0]));
      printf("ok command retire: RDR2-like load, at most %u allocators in the pool, "
             "%u after the drain (%.1f MiB idle), %" PRId64 " sealed ones destroyed\n",
             most, pp->metal.allocator_count, idle_B / (double)MIB,
             stats->allocator_releases - releases);
      kk_DestroyCommandPool(device, cp, NULL);
   }

   /* 13. Secondaries take an allocator but encode nothing in Metal: none is
    * tainted */
   {
      VkCommandPool cp;
      VkCommandBuffer sec;
      const VkCommandPoolCreateInfo pci = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
         .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
      };
      CHECK(kk_CreateCommandPool(device, &pci, NULL, &cp));
      const VkCommandBufferAllocateInfo ai = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
         .commandPool = cp, .level = VK_COMMAND_BUFFER_LEVEL_SECONDARY,
         .commandBufferCount = 1,
      };
      CHECK(vk_common_AllocateCommandBuffers(device, &ai, &sec));
      const int64_t taints = stats->allocator_taints;
      const VkCommandBufferInheritanceInfo inherit = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO,
      };
      const VkCommandBufferBeginInfo info = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
         .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
         .pInheritanceInfo = &inherit,
      };
      for (unsigned k = 0; k < 3; k++) {
         CHECK(kk_BeginCommandBuffer(sec, &info));
         CHECK(kk_EndCommandBuffer(sec));
         CHECK(vk_common_ResetCommandBuffer(sec, 0));
      }
      assert(stats->allocator_taints == taints &&
             kk_cmd_pool_from_handle(cp)->metal.allocator_count == 1u);
      kk_DestroyCommandPool(device, cp, NULL);
      puts("ok command retire: a secondary taints no allocator");
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
   encode(0);
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

   /* 2. The idle allocator is reset at the next Begin, keeping its heaps as
    * Metal does, and the BO reused */
   const int64_t resets = stats->allocator_resets;
   begin_once(1);
   assert(cmd(1)->metal.encoded_in == a && stats->allocator_resets == resets + 1);
   assert(mtl_command_allocator_allocated_size(a->handle) == 1u << 20);
   assert(allocate(1, 600 * KIB, 640 * KIB).buffer == first.buffer);
   encode(1);
   CHECK(kk_EndCommandBuffer(c[1]));
   submit(1);
   complete();
   puts("ok command retire: the next Begin resets the allocator without users");

   /* 3. Begun in Metal and released without a commit: tainted, then
    * destroyed, never reset (the mock aborts such a reset) */
   begin_once(2);
   assert(cmd(2)->metal.encoded_in == a);
   encode(2);
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
   encode(3);
   CHECK(kk_EndCommandBuffer(c[3]));
   submit(3);
   complete();
   puts("ok command retire: an allocator released uncommitted is destroyed, not reset");

   /* 4. Sealed past 8 MiB: in flight it takes no recording; four unsealed
    * ones, then the least-filled is shared */
   begin_once(4);
   struct kk_cmd_allocator *sealed = cmd(4)->metal.encoded_in;
   kk_mock_set_size(cmd(4)->metal.allocator, 9u << 20);
   encode(4);
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
      encode(unsealed[k]);
      CHECK(kk_EndCommandBuffer(c[unsealed[k]]));
      submit(unsealed[k]);
   }
   assert(p->metal.allocator_count == 5u);
   begin_once(1);
   assert(cmd(1)->metal.encoded_in == least && stats->allocator_shares == 1 &&
          p_atomic_read(&least->users) == 2u && p->metal.allocator_count == 5u);
   encode(1);
   CHECK(kk_EndCommandBuffer(c[1]));
   submit(1);
   complete();
   assert(p->retire.in_flight == 0u && p_atomic_read(&least->users) == 0u);
   /* After the drain the sealed one is destroyed, not reset (a reset would
    * keep its 9 MiB), and one of the four clean ones is reset */
   const int64_t resets_after_drain = stats->allocator_resets;
   const int64_t releases = stats->allocator_releases;
   begin_once(2);
   assert(stats->allocator_resets == resets_after_drain + 1 &&
          stats->allocator_releases == releases + 1 &&
          p->metal.allocator_count == 4u && p->metal.sealed_count == 0u &&
          cmd(2)->metal.encoded_in != sealed);
   encode(2);
   CHECK(kk_EndCommandBuffer(c[2]));
   submit(2);
   complete();
   puts("ok command retire: seal at 8 MiB, four unsealed, then the least-filled is shared; idle sealed destroyed");

   /* 5. Quarter-octave classes, and no reuse of a cached BO over twice the
    * ask's class. The cached 640 KiB heap takes the first ask. */
   begin_once(3);
   assert(allocate(3, 553 * KIB, 640 * KIB).buffer == first.buffer);
   const struct kk_ptr b320 = allocate(3, 300 * KIB, 320 * KIB);
   const struct kk_ptr b1280 = allocate(3, 1100 * KIB, 1280 * KIB);
   allocate(3, (2u << 20) + 1, 4u << 20);
   encode(3);
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
   encode(4);
   CHECK(kk_EndCommandBuffer(c[4]));
   submit(4);
   complete();
   puts("ok command BO classes: 320 KiB, 640 KiB, 1280 KiB; reuse up to twice the class");

   /* 6. A reusable primary keeps its holds until its reset. From here a
    * 200 KiB ask (class 256 KiB) takes a cached 320 KiB heap. */
   begin(5, 0);
   allocate(5, 200 * KIB, 320 * KIB);
   encode(5);
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
   encode(6);
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
   assert(!cmd(6)->metal.committed && !cmd(6)->metal.begun && !again->tainted);
   encode(6);
   assert(cmd(6)->metal.begun);
   CHECK(kk_EndCommandBuffer(c[6]));
   CHECK(vk_common_ResetCommandBuffer(c[6], 0));
   assert(again->tainted && stats->allocator_taints == taints + 1);
   puts("ok command retire: a recording after a committed one taints if released uncommitted");

   pool_rules(d);

   /* 14. A pool destroy waits for a retirement still in flight */
   begin_once(7);
   allocate(7, 200 * KIB, 320 * KIB);
   encode(7);
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

   /* 15. The census's retire line */
   kk_mesa_debug_flags |= KK_DEBUG_MEMORY;
   static char log[65536];
   capture_memory_log(d, log, sizeof(log));
   fputs(log, stdout);
   expect(log, "[kk-cmd-retire] in-flight=0 (0.0 MiB) retired=");
   char counts[192];
   snprintf(counts, sizeof(counts),
            "tainted=2 destroyed=%" PRId64 " shared=%" PRId64
            " released=%" PRId64 " trimmed=%" PRId64 " capped=1 over-cap=1"
            " pool-max=9 | unbegun=%" PRId64 "\n",
            stats->allocator_destroys, stats->allocator_shares,
            stats->allocator_releases, stats->allocator_trims,
            stats->unbegun);
   expect(log, counts);
   puts("ok command retire: [kk-cmd-retire] census line");

   /* 16. Within 10 s [kk-mem] stays quiet, unless 8 allocators more came:
    * then it logs after 1 s, marked growing */
   capture_memory_log(d, log, sizeof(log));
   assert(log[0] == '\0');
   usleep(1100000);
   capture_memory_log(d, log, sizeof(log));
   assert(log[0] == '\0');
   VkCommandPool grow_pool;
   VkCommandBuffer grow[8];
   new_pool(&grow_pool, grow, 8);
   for (unsigned k = 0; k < 8; k++)
      begin_cb(grow[k], VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
   capture_memory_log(d, log, sizeof(log));
   fputs(log, stdout);
   expect(log, "| growing allocators+8 command+0 MiB\n");
   for (unsigned k = 0; k < 8; k++)
      CHECK(kk_EndCommandBuffer(grow[k]));
   kk_DestroyCommandPool(device, grow_pool, NULL);
   puts("ok memory log: [kk-mem] within a second while allocators grow");

   mtl_release(event);
   kk_DestroyDevice(device, NULL);
   kk_DestroyInstance(instance, NULL);
   return 0;
}
