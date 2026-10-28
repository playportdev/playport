/* SPDX-License-Identifier: GPL-3.0-or-later
 * PLA-465: when the real driver commits the device residency set, on mock
 * Metal. Linked to the driver's archives (run-cmd-pool-test.py) to read the
 * set's private state and the [kk-mem] counters. The mock's residency set
 * does nothing, so this checks KosmicKrisp's scheduling of commits, not what
 * Metal does with them (docs/evidence/2026-10-29-kk-residency-commits.md has
 * the Metal behaviour this relies on, measured on a Mac).
 */
#include "kk_bo.h"
#include "kk_debug.h"
#include "kk_device.h"
#include "kk_entrypoints.h"
#include "vk_common_entrypoints.h"
#include "util/os_time.h"
#include "util/u_atomic.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(call) assert((call) == VK_SUCCESS)

static VkDevice device;
static struct kk_device *d;

static VkDeviceMemory
allocate(uint64_t size)
{
   const VkMemoryAllocateInfo info = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = size,
      .memoryTypeIndex = 0,
   };
   VkDeviceMemory mem;
   CHECK(kk_AllocateMemory(device, &info, NULL, &mem));
   return mem;
}

static int64_t
counter(const int64_t *c)
{
   return p_atomic_read(c);
}

#define COMMITS counter(&kk_memory_stats.residency_commits)
#define REMOVAL_COMMITS counter(&kk_memory_stats.residency_removal_commits)

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
   assert(!kk_residency_at_submit);
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
   d = kk_device_from_handle(device);
   struct kk_residency_set *set = &d->residency_set;

   /* Every addition is committed before the allocation is returned, so a
    * submit has none left to commit. */
   int64_t commits = COMMITS;
   const int64_t adds = counter(&kk_memory_stats.residency_adds);
   VkDeviceMemory a = allocate(1u << 20);
   assert(COMMITS == commits + 1);
   assert(counter(&kk_memory_stats.residency_adds) == adds + 1);
   assert(!set->dirty && set->removed_count == 0);
   kk_device_make_resources_resident(d);
   assert(COMMITS == commits + 1);
   puts("ok residency: an addition is committed at allocation; a submit commits nothing");

   /* A removal waits: a submit under both limits does not commit it. */
   int64_t removal_commits = REMOVAL_COMMITS;
   kk_FreeMemory(device, a, NULL);
   assert(set->removed_count == 1 && set->removed_B == (1u << 20));
   for (unsigned i = 0; i < 100; i++)
      kk_device_make_resources_resident(d);
   assert(REMOVAL_COMMITS == removal_commits && set->removed_count == 1);
   puts("ok residency: a removal waits through 100 submits under the limits");

   /* The next addition's commit takes the waiting removals with it. */
   commits = COMMITS;
   VkDeviceMemory b = allocate(1u << 20);
   assert(COMMITS == commits + 1 && set->removed_count == 0 && set->removed_B == 0);
   kk_FreeMemory(device, b, NULL);
   puts("ok residency: an addition's commit takes the waiting removals");

   /* The age limit: a submit commits removals once the oldest is 1 s old. */
   set->removed_since_ns = os_time_get_nano() - KK_RESIDENCY_REMOVED_MAX_NS;
   kk_device_make_resources_resident(d);
   assert(REMOVAL_COMMITS == removal_commits + 1 && set->removed_count == 0);
   puts("ok residency: a submit commits removals 1 s old");

   /* The byte limit: 64 MiB of removals, at once. */
   VkDeviceMemory big[4];
   for (unsigned i = 0; i < 4; i++)
      big[i] = allocate(16u << 20);
   removal_commits = REMOVAL_COMMITS;
   for (unsigned i = 0; i < 3; i++)
      kk_FreeMemory(device, big[i], NULL);
   kk_device_make_resources_resident(d);
   assert(REMOVAL_COMMITS == removal_commits && set->removed_B == (48u << 20));
   kk_FreeMemory(device, big[3], NULL);
   kk_device_make_resources_resident(d);
   assert(REMOVAL_COMMITS == removal_commits + 1 && set->removed_B == 0);
   puts("ok residency: a submit commits 64 MiB of removals");

   /* No heap: commit the removals the set keeps alive and try once more. */
   kk_FreeMemory(device, allocate(1u << 20), NULL);
   assert(set->removed_count == 1);
   removal_commits = REMOVAL_COMMITS;
   setenv("KK_MOCK_FAIL_NEXT_HEAP", "1", 1);
   VkDeviceMemory c = allocate(1u << 20);
   assert(REMOVAL_COMMITS == removal_commits + 1 && set->removed_count == 0);
   kk_FreeMemory(device, c, NULL);
   kk_device_commit_residency_removals(d);
   setenv("KK_MOCK_FAIL_NEXT_HEAP", "1", 1);
   const VkMemoryAllocateInfo info = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = 1u << 20,
   };
   VkDeviceMemory none;
   assert(kk_AllocateMemory(device, &info, NULL, &none) ==
          VK_ERROR_OUT_OF_DEVICE_MEMORY);
   puts("ok residency: no heap commits waiting removals and retries once; none waiting fails");

   /* MESA_KK_RESIDENCY=submit: upstream's commit at every submit, and with
    * MESA_KK_BATCH2's residency item only after a change. */
   kk_residency_at_submit = true;
   commits = COMMITS;
   VkDeviceMemory e = allocate(1u << 20);
   assert(COMMITS == commits && set->dirty);
   kk_device_make_resources_resident(d);
   kk_device_make_resources_resident(d);
   assert(COMMITS == commits + 2 && !set->dirty);
   kk_batch2_flags |= KK_BATCH2_RESIDENCY;
   kk_device_make_resources_resident(d);
   assert(COMMITS == commits + 2);
   kk_FreeMemory(device, e, NULL);
   kk_device_make_resources_resident(d);
   assert(COMMITS == commits + 3 && set->removed_count == 0);
   kk_batch2_flags &= ~KK_BATCH2_RESIDENCY;
   kk_residency_at_submit = false;
   puts("ok residency: MESA_KK_RESIDENCY=submit commits at submits, with batch2 only after a change");

   kk_residency_log(d);
   kk_DestroyDevice(device, NULL);
   kk_DestroyInstance(instance, NULL);
   return 0;
}
