#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write a mock Metal bridge for KosmicKrisp from the tree's own stubs.

    make-mock-bridge.py MESA_TREE OUT_DIR

KosmicKrisp builds on Linux with src/kosmickrisp/bridge/stubs/*.c, which
return NULL and zero, so no device is ever found. This writes a copy of those
files in which the driver gets a device (an Apple GPU family 10 with iOS 27
limits), heaps and buffers backed by host memory (GPU address == CPU address),
and dummy handles for everything else. The command stream is not executed:
commits complete at once. Every MSL library the driver compiles is written to
$KK_MOCK_MSL_DIR (if set), and one the MSL backend could not translate (it
prints "Unknown intrinsic NAME", or "ALU OP" for an ALU op, "Unknown ALU OP"
from mesa 0042 on) is reported on stderr and counted; the process exits 3 at
exit if there was any. With KK_MOCK_INTERRUPT_BUILDS=N the first N library
builds that take an error report (the pipelines', not the driver's own
shaders') fail as if Metal's compiler service had been interrupted (mesa
0053's compile_retry builds them again). With KK_MOCK_LIBRARY_GATE=PATH a
library build on the driver's library queue thread (kk-gpl-library, PLA-437)
waits while PATH exists, before it is written or counted.

The stubs are the template, so a new bridge function upstream still links:
it gets the stub's body, with a dummy handle for a pointer return.
"""
import os
import re
import sys

tree, out = sys.argv[1], sys.argv[2]
stubs = os.path.join(tree, "src/kosmickrisp/bridge/stubs")
os.makedirs(out, exist_ok=True)

COMMON = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/prctl.h>
#include <unistd.h>

/* Every handle is one of these, so release/retain and labels are harmless. */
struct kk_mock_obj {
   uint32_t magic;
   void *mem;            /* heaps and buffers: host memory */
   uint64_t size;
   uint64_t value;       /* events */
   int kind;
   /* Libraries, their function descriptors and render pipeline descriptors
    * (the vertex function's): what the MSL writes, KK_MOCK_MSL_* */
   uint32_t msl_writes;
   /* Render pipeline descriptors: the input primitive topology class */
   int topology_class;
};
#define KK_MOCK_MAGIC 0x6b6b6d6bu
#define KK_MOCK_MSL_POINT_SIZE 0x1u
#define KK_MOCK_MSL_LAYER 0x2u

void *kk_mock_new(int kind, uint64_t size);
void kk_mock_record_msl(const char *src);
int kk_mock_interrupt_build(void);
void kk_mock_library_gate(void);

/* The sample counts of an A19 (supportsTextureSampleCount:). */
#define KK_MOCK_SAMPLE_COUNT_OK(n) ((n) == 1 || (n) == 2 || (n) == 4)
'''

DEFS = {}
def body(name, text):
    DEFS[name] = text

# mtl_bridge.c: the shared helpers live here
EXTRA = {"mtl_device.c": '#include "kk_image_layout.h"\n',
         "mtl_buffer.c": '#include "kk_image_layout.h"\n#include "mtl_format.h"\n',
         "mtl_bridge.c": r'''
static int kk_mock_bad_msl;
static unsigned kk_mock_msl_count;

/* A destructor rather than atexit: the Vulkan loader unloads the driver
 * before the process exits, and an atexit handler would then point into
 * unmapped code. */
__attribute__((destructor)) static void
kk_mock_exit(void)
{
   if (kk_mock_bad_msl) {
      fprintf(stderr, "kk-mock: %d MSL libraries had untranslated intrinsics or ALU ops\n",
              kk_mock_bad_msl);
      fflush(stderr);
      _exit(3);
   }
}

void *
kk_mock_new(int kind, uint64_t size)
{
   struct kk_mock_obj *o = calloc(1, sizeof(*o));
   o->magic = KK_MOCK_MAGIC;
   o->kind = kind;
   o->size = size;
   if (size) {
      if (posix_memalign(&o->mem, 16384, size))
         abort();
      memset(o->mem, 0, size);
   }
   return o;
}

/* The next marker of untranslated NIR in src at or after p: "Unknown
 * intrinsic NAME", or an "ALU OP" token (nir_to_msl.c's alu_to_msl default;
 * "Unknown ALU OP" from mesa 0042 on). Neither is valid MSL. */
static const char *
kk_mock_untranslated(const char *src, const char *p)
{
   for (; *p; ++p) {
      if (!strncmp(p, "Unknown intrinsic", 17) || !strncmp(p, "Unknown ALU ", 12))
         return p;
      if (!strncmp(p, "ALU ", 4) &&
          (p == src || !(p[-1] == '_' || (p[-1] >= '0' && p[-1] <= '9') ||
                         ((p[-1] | 0x20) >= 'a' && (p[-1] | 0x20) <= 'z'))))
         return p;
   }
   return NULL;
}

/* Whether this library build fails as interrupted: the first
 * KK_MOCK_INTERRUPT_BUILDS do. Builds may run on two threads at once. */
int
kk_mock_interrupt_build(void)
{
   static int left = INT32_MIN; /* INT32_MIN: not read yet */
   if (__atomic_load_n(&left, __ATOMIC_SEQ_CST) == INT32_MIN) {
      const char *v = getenv("KK_MOCK_INTERRUPT_BUILDS");
      int expected = INT32_MIN;
      __atomic_compare_exchange_n(&left, &expected, v ? atoi(v) : 0, 0,
                                  __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
   }
   return __atomic_sub_fetch(&left, 1, __ATOMIC_SEQ_CST) >= 0;
}

/* KK_MOCK_LIBRARY_GATE: the library queue thread's builds wait while the
 * file exists */
void
kk_mock_library_gate(void)
{
   const char *gate = getenv("KK_MOCK_LIBRARY_GATE");
   char name[16] = {0};
   if (gate == NULL || prctl(PR_GET_NAME, name) != 0 ||
       strcmp(name, "kk-gpl-library") != 0)
      return;
   while (access(gate, F_OK) == 0)
      usleep(1000);
}

void
kk_mock_record_msl(const char *src)
{
   unsigned n = __atomic_fetch_add(&kk_mock_msl_count, 1, __ATOMIC_SEQ_CST);
   const char *dir = getenv("KK_MOCK_MSL_DIR");
   if (dir) {
      char path[4096];
      snprintf(path, sizeof(path), "%s/%04u.metal", dir, n);
      FILE *f = fopen(path, "w");
      if (f) {
         fputs(src, f);
         fclose(f);
      }
   }
   const char *m = kk_mock_untranslated(src, src);
   if (m) {
      kk_mock_bad_msl++;
      fprintf(stderr, "kk-mock: MSL library %04u has untranslated NIR:\n", n);
      while (m) {
         const char *e = strchr(m, '\n');
         fprintf(stderr, "  %.*s\n", (int)(e ? e - m : 80), m);
         m = e ? kk_mock_untranslated(src, e) : NULL;
      }
   }
}
'''}

body("mtl_retain", "return handle;")
body("mtl_release", "(void)handle;")
body("mtl_device_create", "return kk_mock_new(1, 0);")
body("mtl_device_get_name", 'snprintf(buffer, 256, "Mock Apple A19 Pro GPU");')
body("mtl_device_get_architecture_name", 'snprintf(buffer, 256, "applegpu_g18p");')
body("mtl_device_get_gpu_apple_family", "return 10u;")
body("mtl_device_get_registry_id", "return 1u;")
body("mtl_device_supports_sample_count", "return KK_MOCK_SAMPLE_COUNT_OK(sample_count);")
# A pipeline's raster sample count must match its attachments', and a render
# pass without attachments takes its default: one the device does not support
# is a driver bug the phone would hit (what Metal then does is not checked).
for f, what in (("mtl_render_pipeline_descriptor_set_raster_sample_count", "render pipeline"),
                ("mtl_render_pass_descriptor_set_default_raster_sample_count", "render pass")):
    body(f, r'''
   if (!KK_MOCK_SAMPLE_COUNT_OK(sample_count)) {
      fprintf(stderr, "kk-mock: ''' + what + r''' raster sample count %u, which "
                      "the device does not support\n", sample_count);
      abort();
   }''')
body("mtl_device_max_threads_per_threadgroup", "return (struct mtl_size){1024, 1024, 1024};")
body("mtl_device_max_threadgroup_memory_length", "return 32768u;")
body("mtl_device_max_buffer_length", "return 1ull << 32;")
body("mtl_device_recommended_max_working_set_size", "return 5ull << 30;")
body("mtl_device_max_argument_buffer_sampler_count", "return 1024u;")
body("mtl_device_timestamp_frequency", "return 1000000000u;")
body("mtl_heap_buffer_size_and_align_with_length", "if (align_B) *align_B = 256;")
body("mtl_minimum_linear_texture_alignment_for_pixel_format", "return 16u;")
# Each layer is padded to 16 KiB, so a layer's size times the layer count is
# the texture's, as kk_image_layout_calc_tiled asserts for a texture whose
# contents Metal may not optimize.
body("mtl_heap_texture_size_and_align_with_descriptor", r'''
   uint64_t px = (uint64_t)layout->width_px * layout->height_px *
                 layout->depth_px * layout->sample_count_sa;
   if (size_B) *size_B = layout->layers * ((px * 16u * 2u + 16383u) & ~16383ull);
   if (align_B) *align_B = 16384u;''')
body("mtl_sparse_tile_size_in_bytes", "return 16384u;")
body("mtl_new_heap", "return kk_mock_new(2, size);")
body("mtl_heap_get_size", "return ((struct kk_mock_obj *)heap)->size;")
body("mtl_new_buffer_with_length", r'''
   struct kk_mock_obj *h = heap;
   struct kk_mock_obj *b = kk_mock_new(3, 0);
   b->mem = (char *)h->mem + offset_B;
   b->size = size_B;
   return b;''')
body("mtl_new_buffer_with_bytes_no_copy", r'''
   struct kk_mock_obj *b = kk_mock_new(3, 0);
   b->mem = ptr;
   b->size = size_B;
   return b;''')
body("mtl_buffer_get_length", "return ((struct kk_mock_obj *)buffer)->size;")
body("mtl_buffer_get_gpu_address", "return (uint64_t)(uintptr_t)((struct kk_mock_obj *)buffer)->mem;")
body("mtl_get_contents", "return ((struct kk_mock_obj *)buffer)->mem;")
# Metal requires a texture made from a buffer to start at an aligned offset
# (minimumLinearTextureAlignmentForPixelFormat; KosmicKrisp assumes 16 bytes
# covers every format). Anything else is a driver bug the phone would hit.
# A linear texture (any type but a texture buffer) has more rules, from
# MTLBuffer newTextureWithDescriptor:offset:bytesPerRow: in Apple's Metal
# documentation: one 2D level and layer, one sample, an ordinary or packed
# colour format other than GBGR422 and BGRG422 (so not depth, stencil or
# compressed: minimumLinearTextureAlignmentForPixelFormat throws for those),
# and bytesPerRow aligned and at least one row of pixels. What Metal does
# otherwise (nil, or a validation error) is not modelled.
body("mtl_new_texture_with_descriptor_linear", r'''
   if (offset % 16u) {
      fprintf(stderr, "kk-mock: linear texture at buffer offset %llu, not "
                      "16-byte aligned\n", (unsigned long long)offset);
      abort();
   }
   if (layout->type != MTL_TEXTURE_TYPE_TEXTURE_BUFFER) {
      const char *bad = NULL;
      if (layout->type != MTL_TEXTURE_TYPE_2D)
         bad = "a texture type other than 2D";
      else if (layout->depth_px != 1u || layout->layers != 1u)
         bad = "depth or array length over 1";
      else if (layout->levels != 1u)
         bad = "more than one mipmap level";
      else if (layout->sample_count_sa != 1u)
         bad = "more than one sample";
      else if (util_format_is_depth_or_stencil(layout->format.pipe) ||
               util_format_is_compressed(layout->format.pipe) ||
               layout->format.mtl == MTL_PIXEL_FORMAT_GBGR422 ||
               layout->format.mtl == MTL_PIXEL_FORMAT_BGRG422)
         bad = "a pixel format that is not ordinary or packed colour";
      else if (layout->linear_stride_B % 16u ||
               layout->linear_stride_B <
                  (uint64_t)layout->width_px *
                     util_format_get_blocksize(layout->format.pipe))
         bad = "bytesPerRow unaligned or shorter than a row";
      if (bad) {
         fprintf(stderr, "kk-mock: linear texture %ux%ux%u, %u layers, %u "
                         "levels, type %u, %s: %s\n", layout->width_px,
                 layout->height_px, layout->depth_px, layout->layers,
                 layout->levels, layout->type,
                 util_format_short_name(layout->format.pipe), bad);
         abort();
      }
   }
   return kk_mock_new(8, 0);''')
body("mtl_texture_get_gpu_resource_id", "return (uint64_t)(uintptr_t)texture;")
# Metal's capture layer refuses a device with a counter heap; with
# KK_MOCK_REFUSE_COUNTER_HEAP set, making one aborts (patches/mesa 0044).
body("mtl_new_timestamp_counter_heap", r'''
   if (getenv("KK_MOCK_REFUSE_COUNTER_HEAP")) {
      fprintf(stderr, "kk-mock: a timestamp counter heap of %u entries\n",
              count);
      abort();
   }
   return kk_mock_new(9, 0);''')
body("mtl_new_library", r'''
   kk_mock_library_gate();
   kk_mock_record_msl(src);
   if (error && kk_mock_interrupt_build()) {
      memset(error, 0, sizeof(*error));
      error->code = 2;
      snprintf(error->domain, sizeof(error->domain), "kk-mock");
      error->compiler_interrupted = true;
      return NULL;
   }
   struct kk_mock_obj *l = kk_mock_new(4, 0);
   if (strstr(src, "[[point_size]]"))
      l->msl_writes |= KK_MOCK_MSL_POINT_SIZE;
   if (strstr(src, "[[render_target_array_index]]"))
      l->msl_writes |= KK_MOCK_MSL_LAYER;
   return l;''')
# Metal refuses a render pipeline whose vertex function writes a point size
# with the line or triangle topology class ("Vertex shader writes point size
# but inputPrimitiveTopology is MTLPrimitiveTopologyClassTriangle", seen on
# the phone, PLA-424), and layered rendering needs the class: either one
# fails the build as Metal does (nil and an error).
body("mtl_new_library_function_descriptor", r'''
   struct kk_mock_obj *f = kk_mock_new(10, 0);
   if (library)
      f->msl_writes = ((struct kk_mock_obj *)library)->msl_writes;
   return f;''')
body("mtl_render_pipeline_descriptor_set_vertex_shader", r'''
   ((struct kk_mock_obj *)descriptor)->msl_writes =
      shader ? ((struct kk_mock_obj *)shader)->msl_writes : 0;''')
body("mtl_render_pipeline_descriptor_set_input_primitive_topology",
     "((struct kk_mock_obj *)descriptor)->topology_class = topology_class;")
body("mtl_new_render_pipeline", r'''
   struct kk_mock_obj *d = (struct kk_mock_obj *)descriptor;
   const char *bad = NULL;
   if ((d->msl_writes & KK_MOCK_MSL_POINT_SIZE) &&
       (d->topology_class == MTL_PRIMITIVE_TOPOLOGY_CLASS_LINE ||
        d->topology_class == MTL_PRIMITIVE_TOPOLOGY_CLASS_TRIANGLE))
      bad = "Vertex shader writes point size but inputPrimitiveTopology is "
            "a line or triangle class";
   else if ((d->msl_writes & KK_MOCK_MSL_LAYER) &&
            d->topology_class == MTL_PRIMITIVE_TOPOLOGY_CLASS_UNSPECIFIED)
      bad = "Vertex shader writes a layer but inputPrimitiveTopology is "
            "unspecified";
   if (bad) {
      fprintf(stderr, "kk-mock: Failed to create MTLRenderPipelineState: %s\n",
              bad);
      if (error) {
         memset(error, 0, sizeof(*error));
         error->code = 1;
         snprintf(error->domain, sizeof(error->domain), "kk-mock");
      }
      return NULL;
   }
   return kk_mock_new(11, 0);''')
body("mtl_new_event", "return kk_mock_new(5, 0);")
body("mtl_new_shared_event", "return kk_mock_new(5, 0);")
body("mtl_shared_event_get_signaled_value", "return ((struct kk_mock_obj *)event_handle)->value;")
body("mtl_shared_event_set_signaled_value", "((struct kk_mock_obj *)event_handle)->value = value;")
body("mtl_shared_event_wait_until_signaled_value", "return ((struct kk_mock_obj *)event_handle)->value >= value;")
body("mtl_signal_event", "((struct kk_mock_obj *)event)->value = value;")
# Commit options remember one feedback handler; commit calls it at once, with
# a GPU time of 2 ms for each command buffer, back to back.
body("mtl_new_commit_options", "return kk_mock_new(6, 0);")
body("mtl_commit_options_add_feedback_handler", r'''
   struct kk_mock_obj *o = options;
   o->mem = (void *)callback;
   o->value = (uint64_t)(uintptr_t)data;''')
body("mtl_command_queue_commit", r'''
   struct kk_mock_obj *o = options;
   static double gpu_clock = 100.0;
   if (o && o->mem) {
      struct mtl_feedback_data fb = {
         .user_data = (void *)(uintptr_t)o->value,
         .gpu_start = gpu_clock,
         .gpu_end = gpu_clock + 0.002 * count,
         .error = MTL_COMMAND_QUEUE_ERROR_NONE,
      };
      gpu_clock += 0.002 * count;
      ((mtl_feedback_handler_callback)o->mem)(&fb);
   }''')
body("ns_is_os_version_at_least", "return major < 27 || (major == 27 && minor == 0 && patch == 0);")
body("mtl_drawable_get_texture", "return kk_mock_new(7, 0);")

FUNC = re.compile(r'^(?P<ret>[A-Za-z_][\w \*]*?)\n(?P<name>\w+)\((?P<args>[^)]*)\)\n\{\n(?P<body>.*?)^\}', re.S | re.M)

for fname in sorted(os.listdir(stubs)):
    if not fname.endswith(".c"):
        continue
    src = open(os.path.join(stubs, fname)).read()
    used = set()

    def repl(m):
        name, ret = m.group("name"), m.group("ret").strip()
        used.add(name)
        if name in DEFS:
            b = DEFS[name]
            b = b if b.startswith("\n") else "   " + b
            return f"{m.group('ret')}\n{name}({m.group('args')})\n{{\n{b}\n}}"
        if ret.endswith("*") and "return NULL;" in m.group("body"):
            return (f"{m.group('ret')}\n{name}({m.group('args')})\n{{\n"
                    f"   return kk_mock_new(0, 0);\n}}")
        return m.group(0)

    new = FUNC.sub(repl, src)
    # Insert the shared declarations after the stub's own includes.
    last_inc = [m.end() for m in re.finditer(r'^#include .*$', new, re.M)]
    at = last_inc[-1] if last_inc else 0
    new = new[:at] + "\n" + COMMON + EXTRA.get(fname, "") + new[at:]
    open(os.path.join(out, fname), "w").write(
        "/* Generated by make-mock-bridge.py from the stub of the same name. */\n" + new)

missing = set(DEFS) - {n for f in os.listdir(out) for n in re.findall(r'^(\w+)\(', open(os.path.join(out, f)).read(), re.M)}
if missing:
    sys.exit(f"make-mock-bridge.py: no stub for {sorted(missing)}")
print(f"mock bridge: {len(os.listdir(out))} files in {out}")
