/* SPDX-License-Identifier: GPL-3.0-or-later
 * patches/mesa 0154, 0156, 0157 (PLA-880): a failed commit, on the real driver and mock
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
#include "kk_image.h"
#include "kk_queue.h"
#include "vk_common_entrypoints.h"
#include "poly/geometry.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void kk_mock_counter_heap_set(void *heap, uint32_t index, uint64_t value);

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
static VkImage mip_image, array_image;
static VkCommandBuffer recording; /* defined with cbs below */

/* A 64x64 RGBA8 image with 4 levels and the given layers, as a game's mip
 * chain or its array of shadow cascades */
static VkImage
create_image(uint32_t layers)
{
   const VkImageCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {64, 64, 1},
      .mipLevels = 4,
      .arrayLayers = layers,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
               VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
   };
   VkImage image;
   CHECK(kk_CreateImage(device, &ici, NULL, &image));
   VkMemoryRequirements req;
   vk_common_GetImageMemoryRequirements(device, image, &req);
   const VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = req.size,
   };
   VkDeviceMemory mem;
   CHECK(kk_AllocateMemory(device, &mai, NULL, &mem));
   const VkBindImageMemoryInfo bind = {
      .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
      .image = image, .memory = mem,
   };
   CHECK(kk_BindImageMemory2(device, 1, &bind));
   return image;
}

/* Levels src_level into dst_level of every one of the image's layers */
static void
blit(VkCommandBuffer handle, VkImage image, uint32_t layers,
     uint32_t src_level, uint32_t dst_level)
{
   const int32_t src = 64 >> src_level, dst = 64 >> dst_level;
   const VkImageBlit2 region = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_BLIT_2,
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, src_level, 0, layers},
      .srcOffsets = {{0, 0, 0}, {src, src, 1}},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, dst_level, 0, layers},
      .dstOffsets = {{0, 0, 0}, {dst, dst, 1}},
   };
   const VkBlitImageInfo2 info = {
      .sType = VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2,
      .srcImage = image,
      .srcImageLayout = VK_IMAGE_LAYOUT_GENERAL,
      .dstImage = image,
      .dstImageLayout = VK_IMAGE_LAYOUT_GENERAL,
      .regionCount = 1,
      .pRegions = &region,
      .filter = VK_FILTER_LINEAR,
   };
   kk_CmdBlitImage2(handle, &info);
}

/* A mip chain made by blits, as DXVK's GenerateMips (levels 0 to 1, 1 to 2),
 * then a blit of level 2 onto itself (a read of the level its pass renders),
 * then a buffer copy */
static void
record_blits(void *unused)
{
   const VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   CHECK(kk_BeginCommandBuffer(recording, &begin));
   blit(recording, mip_image, 1, 0, 1);
   blit(recording, mip_image, 1, 1, 2);
   blit(recording, mip_image, 1, 2, 2);
   const VkBufferCopy2 region = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_COPY_2, .size = 256,
   };
   const VkCopyBufferInfo2 info = {
      .sType = VK_STRUCTURE_TYPE_COPY_BUFFER_INFO_2,
      .srcBuffer = buffers[0], .dstBuffer = buffers[1],
      .regionCount = 1, .pRegions = &region,
   };
   kk_CmdCopyBuffer2(recording, &info);
   CHECK(kk_EndCommandBuffer(recording));
   submitted = kk_cmd_buffer_from_handle(recording);
}

/* Level 0 into level 1 of a 5-layer image: vk_meta draws one rectangle per
 * layer, its vertex shader writing the layer (instance) */
static void
record_layered(void *unused)
{
   const VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   CHECK(kk_BeginCommandBuffer(recording, &begin));
   blit(recording, array_image, 5, 0, 1);
   CHECK(kk_EndCommandBuffer(recording));
   submitted = kk_cmd_buffer_from_handle(recording);
}

static void
submit(void *arg)
{
   struct vk_command_buffer *vk_cmd = &submitted->vk;
   struct vk_queue_submit s = {.command_buffer_count = 1,
                               .command_buffers = &vk_cmd};
   CHECK(q->vk.driver_submit(&q->vk, &s));
}

static VkCommandBuffer cbs[4], recording;

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
   /* Entries MESA_KK_FAULT_SKIP takes and ignores; the skips themselves are
    * set on the device below */
   setenv("MESA_KK_FAULT_SKIP", "0123456789abcdef0,zz,ABCD", 1);
   char *log = capture(create_device, NULL);
   unsetenv("MESA_KK_FAULT_SKIP");
   /* The phone's limit is 4096 timestamps a heap (the mock's too) */
   expect(log, "[kk-fault] on: encoder labels, command buffer trails, geometry "
               "heap ring, encoder timestamps; Metal encoder status: unavailable");
   expect(log, "; skipping draws: 0123456789abcdef0(ignored),zz(ignored),ABCD; "
               "vertex layer clamp off\n");
   d = kk_device_from_handle(device);
   assert(d->fault.skip_count == 1 && d->fault.skip[0].prefix == 0xabcd &&
          d->fault.skip[0].digits == 4 && !d->fault.skip_writes);
   d->fault.skip_count = 0;
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
      .commandBufferCount = 4,
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
            "[kk-fault] cb #%u enc 0 compute dispatches=0 copies=2 heap gpu=", failed);
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

   /* A command buffer of blits fails with its second blit's pass begun and
    * not ended (its end timestamp left unwritten, as by a GPU that stopped
    * in it): each encoder's attachments, pipelines, timestamps and the pass
    * that reads the level it renders are logged, and the submit */
   mip_image = create_image(1);
   recording = cbs[3];
   log = capture(record_blits, NULL);
   const uint32_t blits = submitted->fault.serial;
   const struct kk_fault_encoder *trail = util_dynarray_begin(&submitted->fault.trail);
   const uint32_t encoders =
      util_dynarray_num_elements(&submitted->fault.trail, struct kk_fault_encoder);
   assert(encoders >= 4);
   uint32_t render_encoders = 0;
   for (uint32_t i = 0; i < encoders; i++)
      render_encoders += trail[i].render;
   assert(render_encoders == 3);
   snprintf(want, sizeof(want), "label kk#%u.", blits);
   expect(log, want);
   expect(log, " render draws=1 meta:vkCmdBlitImage2");
   expect(log, "writes [layer]: drawn in a pass of 1 layer(s) 32x32, x1 "
               "instance(s)");
   /* The second render pass: find its encoder, leave its end unwritten */
   uint32_t second = ~0u;
   for (uint32_t i = 0, r = 0; i < encoders && second == ~0u; i++)
      if (trail[i].render && r++ == 1)
         second = i;
   assert(!trail[second].feedback.count);
   kk_mock_counter_heap_set(d->fault.timestamps, trail[second].ts + 1u, 0);
   setenv("KK_MOCK_COMMIT_ERROR", "1", 1);
   log = capture(submit, NULL);
   unsetenv("KK_MOCK_COMMIT_ERROR");
   snprintf(want, sizeof(want), "[kk-fault] cb #%u enc %u render draws=1 "
            "meta:vkCmdBlitImage2 gpu=+", blits, second);
   expect(log, want);
   expect(log, " ms UNFINISHED area=16x16 layers=1");
   snprintf(want, sizeof(want), "[kk-fault] cb #%u enc %u   c0 image=%p format=%u "
            "level=2 layer=0+1 16x16 samples=1", blits, second,
            (void *)kk_image_from_handle(mip_image), VK_FORMAT_R8G8B8A8_UNORM);
   expect(log, want);
   snprintf(want, sizeof(want), "[kk-fault] cb #%u enc %u   pipelines msl=", blits,
            second);
   expect(log, want);
   expect(log, "x1[layer]\n");
   /* The first two blits read another level than they render; the third
    * reads level 2 into level 2 */
   snprintf(want, sizeof(want), "FEEDBACK 1 draw(s), first draw 0: set 0 "
            "binding 1[0] (descriptor type %u) views levels 2+1 layers 0+1 of "
            "c0's image\n", VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
   expect(log, want);
   assert(!strstr(log, "levels 0+1 layers 0+1 of c0's image") &&
          !strstr(log, "levels 1+1 layers 0+1 of c0's image"));
   snprintf(want, sizeof(want), " (the failed cb's): cbs #%u\n", blits);
   expect(log, want);
   snprintf(want, sizeof(want), "[kk-fault] cb #%u stopped in enc %u: it started "
            "and did not end\n", blits, second);
   expect(log, want);
   puts("ok fault: a failed command buffer of blits names the unfinished "
        "encoder, its attachments and pipelines, the pass reading the level it "
        "renders, and its submit");

   /* The same, stopped before the second blit's pass began: the encoder
    * after the last that ended is named */
   log = capture(record_blits, NULL);
   const uint32_t blits2 = submitted->fault.serial;
   trail = util_dynarray_begin(&submitted->fault.trail);
   for (uint32_t i = second; i < encoders; i++) {
      kk_mock_counter_heap_set(d->fault.timestamps, trail[i].ts, 0);
      kk_mock_counter_heap_set(d->fault.timestamps, trail[i].ts + 1u, 0);
   }
   setenv("KK_MOCK_COMMIT_ERROR", "1", 1);
   log = capture(submit, NULL);
   unsetenv("KK_MOCK_COMMIT_ERROR");
   snprintf(want, sizeof(want), "[kk-fault] cb #%u stopped after enc %u, the "
            "last that ended: enc %u did not start\n", blits2, second - 1u, second);
   expect(log, want);
   puts("ok fault: a command buffer stopped between encoders names the one "
        "that did not start");

   /* A vertex stage that writes the layer (vk_meta's rectangles, one an
    * instance) is logged once per pipeline and pass layer count, and
    * MESA_KK_FAULT_SKIP leaves its draws out by what it writes or by its MSL
    * hash */
   array_image = create_image(5);
   recording = cbs[0];
   log = capture(record_layered, NULL);
   expect(log, "writes [layer]: drawn in a pass of 5 layer(s) 32x32, x5 "
               "instance(s)");
   expect(log, " render draws=1 meta:vkCmdBlitImage2");
   const struct kk_fault_encoder *layered = NULL;
   trail = util_dynarray_begin(&submitted->fault.trail);
   for (uint32_t i = 0; i < util_dynarray_num_elements(&submitted->fault.trail,
                                                     struct kk_fault_encoder);
        i++)
      if (trail[i].render)
         layered = &trail[i];
   assert(layered && layered->pipeline_count == 1 &&
          layered->pipelines[0].writes == KK_FAULT_WRITES_LAYER &&
          !layered->skipped);
   const uint64_t layered_msl = layered->pipelines[0].msl;
   d->fault.skip_writes = KK_FAULT_WRITES_LAYER;
   log = capture(record_layered, NULL);
   expect(log, " render draws=1 skipped=1 meta:vkCmdBlitImage2");
   assert(!strstr(log, "drawn in a pass of"));
   d->fault.skip_writes = 0;
   d->fault.skip[0].prefix = layered_msl >> 52;
   d->fault.skip[0].digits = 3;
   d->fault.skip_count = 1;
   log = capture(record_layered, NULL);
   expect(log, " render draws=1 skipped=1 meta:vkCmdBlitImage2");
   d->fault.skip[0].prefix ^= 1u;
   log = capture(record_layered, NULL);
   assert(!strstr(log, "skipped="));
   d->fault.skip_count = 0;
   puts("ok fault: a vertex stage writing the layer is logged with its pass's "
        "layers, and MESA_KK_FAULT_SKIP leaves its draws out");

   /* MESA_KK_EXPERIMENTAL=layer_clamp: each render pass gives its vertex
    * stages its layers, 5 for the array's blit, 1 for the mip chain's */
   kk_mesa_experimental_flags |= KK_EXPERIMENTAL_LAYER_CLAMP;
   capture(record_layered, NULL);
   assert(submitted->state.gfx.descriptors.root.draw.render_target_layers == 5u);
   recording = cbs[3];
   capture(record_blits, NULL);
   assert(submitted->state.gfx.descriptors.root.draw.render_target_layers == 1u);
   kk_mesa_experimental_flags &= ~KK_EXPERIMENTAL_LAYER_CLAMP;
   puts("ok fault: with layer_clamp a render pass gives its vertex stages its "
        "layers");

   /* Without the flag nothing is labelled or traced */
   kk_mesa_debug_flags &= ~KK_DEBUG_FAULT;
   recording = cbs[2];
   log = capture(record_one, NULL);
   assert(!strstr(log, "label kk#"));
   assert(kk_cmd_buffer_from_handle(cbs[2])->fault.serial == 0u);
   puts("ok fault: without MESA_KK_DEBUG=fault no command buffer is traced");
   return 0;
}
