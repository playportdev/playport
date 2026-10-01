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
prints "Unknown intrinsic") is reported on stderr and counted; the process
exits 3 at exit if there was any.

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
#include <unistd.h>

/* Every handle is one of these, so release/retain and labels are harmless. */
struct kk_mock_obj {
   uint32_t magic;
   void *mem;            /* heaps and buffers: host memory */
   uint64_t size;
   uint64_t value;       /* events */
   int kind;
};
#define KK_MOCK_MAGIC 0x6b6b6d6bu

void *kk_mock_new(int kind, uint64_t size);
void kk_mock_record_msl(const char *src);
'''

DEFS = {}
def body(name, text):
    DEFS[name] = text

# mtl_bridge.c: the shared helpers live here
EXTRA = {"mtl_device.c": '#include "kk_image_layout.h"\n',
         "mtl_buffer.c": '#include "kk_image_layout.h"\n', "mtl_bridge.c": r'''
static int kk_mock_bad_msl;
static unsigned kk_mock_msl_count;

/* A destructor rather than atexit: the Vulkan loader unloads the driver
 * before the process exits, and an atexit handler would then point into
 * unmapped code. */
__attribute__((destructor)) static void
kk_mock_exit(void)
{
   if (kk_mock_bad_msl) {
      fprintf(stderr, "kk-mock: %d MSL libraries had untranslated intrinsics\n",
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

void
kk_mock_record_msl(const char *src)
{
   unsigned n = kk_mock_msl_count++;
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
   if (strstr(src, "Unknown intrinsic")) {
      kk_mock_bad_msl++;
      fprintf(stderr, "kk-mock: MSL library %04u has an untranslated intrinsic:\n", n);
      for (const char *l = src; (l = strstr(l, "Unknown intrinsic")); l++) {
         const char *e = strchr(l, '\n');
         fprintf(stderr, "  %.*s\n", (int)(e ? e - l : 80), l);
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
body("mtl_device_supports_sample_count", "return sample_count == 1 || sample_count == 2 || sample_count == 4;")
body("mtl_device_max_threads_per_threadgroup", "return (struct mtl_size){1024, 1024, 1024};")
body("mtl_device_max_threadgroup_memory_length", "return 32768u;")
body("mtl_device_max_buffer_length", "return 1ull << 32;")
body("mtl_device_recommended_max_working_set_size", "return 5ull << 30;")
body("mtl_device_max_argument_buffer_sampler_count", "return 1024u;")
body("mtl_device_timestamp_frequency", "return 1000000000u;")
body("mtl_heap_buffer_size_and_align_with_length", "if (align_B) *align_B = 256;")
body("mtl_minimum_linear_texture_alignment_for_pixel_format", "return 16u;")
body("mtl_heap_texture_size_and_align_with_descriptor", r'''
   uint64_t px = (uint64_t)layout->width_px * layout->height_px *
                 layout->depth_px * layout->layers * layout->sample_count_sa;
   if (size_B) *size_B = (px * 16u * 2u + 16383u) & ~16383ull;
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
body("mtl_new_texture_with_descriptor_linear", r'''
   if (offset % 16u) {
      fprintf(stderr, "kk-mock: linear texture at buffer offset %llu, not "
                      "16-byte aligned\n", (unsigned long long)offset);
      abort();
   }
   return kk_mock_new(8, 0);''')
body("mtl_texture_get_gpu_resource_id", "return (uint64_t)(uintptr_t)texture;")
body("mtl_new_library", "kk_mock_record_msl(src);\n   return kk_mock_new(4, 0);")
body("mtl_new_event", "return kk_mock_new(5, 0);")
body("mtl_new_shared_event", "return kk_mock_new(5, 0);")
body("mtl_shared_event_get_signaled_value", "return ((struct kk_mock_obj *)event_handle)->value;")
body("mtl_shared_event_set_signaled_value", "((struct kk_mock_obj *)event_handle)->value = value;")
body("mtl_shared_event_wait_until_signaled_value", "return ((struct kk_mock_obj *)event_handle)->value >= value;")
body("mtl_signal_event", "((struct kk_mock_obj *)event)->value = value;")
# Commit options remember one feedback handler; commit calls it at once.
body("mtl_new_commit_options", "return kk_mock_new(6, 0);")
body("mtl_commit_options_add_feedback_handler", r'''
   struct kk_mock_obj *o = options;
   o->mem = (void *)callback;
   o->value = (uint64_t)(uintptr_t)data;''')
body("mtl_command_queue_commit", r'''
   struct kk_mock_obj *o = options;
   if (o && o->mem) {
      struct mtl_feedback_data fb = {
         .user_data = (void *)(uintptr_t)o->value,
         .error = MTL_COMMAND_QUEUE_ERROR_NONE,
      };
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
