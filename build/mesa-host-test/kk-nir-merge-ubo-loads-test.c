/* SPDX-License-Identifier: MIT
 * PLA-72: structural NIR/robust-granularity checks, not GPU execution proof.
 */
#include "kk_shader.h"
#include "compiler/nir/nir_builder.h"
#include <assert.h>
#include <stdio.h>

struct read_case {
   uint32_t offset, bound;
   unsigned base;
};

static void
check(const char *name, const struct read_case *reads, unsigned count,
      unsigned expected_loads)
{
   const nir_shader_compiler_options options = {0};
   nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_COMPUTE,
                                                 &options, "%s", name);
   /* Distinct runtime bases: neither constants nor CSE-equivalent. */
   nir_def *bases[] = {
      nir_load_push_constant(&b, 1, 64, nir_imm_int(&b, 0), .base = 0, .range = 16),
      nir_load_push_constant(&b, 1, 64, nir_imm_int(&b, 0), .base = 8, .range = 16),
   };
   nir_intrinsic_instr *stores[16];
   assert(count <= ARRAY_SIZE(stores));
   for (unsigned i = 0; i < count; i++) {
      nir_def *v = nir_load_global_constant_bounded(
         &b, 1, 32, bases[reads[i].base], nir_imm_int(&b, reads[i].offset),
         nir_imm_int(&b, reads[i].bound), .align_mul = 16,
         .align_offset = reads[i].offset % 16);
      stores[i] = nir_store_ssbo(&b, v, nir_imm_int(&b, 0),
                                nir_imm_int(&b, i * 4), .write_mask = 1,
                                .align_mul = 4);
   }
   nir_validate_shader(b.shader, "before kk_nir_merge_ubo_loads");
   kk_nir_merge_ubo_loads(b.shader);
   nir_validate_shader(b.shader, "after kk_nir_merge_ubo_loads");
   unsigned loads = 0;
   nir_foreach_block(block, b.impl) {
      nir_foreach_instr(instr, block) {
         if (instr->type == nir_instr_type_intrinsic &&
             nir_instr_as_intrinsic(instr)->intrinsic ==
                nir_intrinsic_load_global_constant_bounded)
            loads++;
      }
   }
   assert(loads == expected_loads);
   for (unsigned i = 0; i < count; i++) {
      nir_def *v = stores[i]->src[0].ssa;
      unsigned lane = 0;
      if (nir_def_instr(v)->type == nir_instr_type_alu) {
         nir_alu_instr *mov = nir_instr_as_alu(nir_def_instr(v));
         assert(mov->op == nir_op_mov);
         lane = mov->src[0].swizzle[0];
         v = mov->src[0].src.ssa;
      }
      nir_intrinsic_instr *load = nir_instr_as_intrinsic(nir_def_instr(v));
      assert(load->intrinsic == nir_intrinsic_load_global_constant_bounded);
      uint32_t lo = nir_src_as_uint(load->src[1]);
      uint32_t bound = nir_src_as_uint(load->src[2]);
      uint64_t end = (uint64_t)lo + 4 * load->def.num_components;
      assert(load->src[0].ssa == bases[reads[i].base]);
      assert(bound == reads[i].bound);
      assert(lane < load->def.num_components);
      assert((uint64_t)lo + 4 * lane == reads[i].offset);
      assert((lo & ~15u) == (reads[i].offset & ~15u));
      assert(end <= (uint64_t)(lo & ~15u) + 16);
      assert(nir_intrinsic_align_mul(load) == 16);
      assert(nir_intrinsic_align_offset(load) == lo % 16);
      /* The MSL predicate is lo < bound. Zero never reads; an interior
       * bound may admit extra lanes only within the reported 64-byte
       * robust UBO granularity. Use 64-bit math even at UINT32_MAX. */
      if (lo < bound)
         assert(end <= (((uint64_t)bound + 63) & ~UINT64_C(63)));
      if (!bound)
         assert(!(lo < bound));
   }
   ralloc_free(b.shader);
   printf("ok kk_nir_merge_ubo_loads: %s\n", name);
}

int main(void)
{
#define CASE(name, expected, ...) do { \
   const struct read_case reads[] = {__VA_ARGS__}; \
   check(name, reads, ARRAY_SIZE(reads), expected); \
} while (0)
   CASE("reversed lanes", 1, {12,64,0}, {8,64,0}, {4,64,0}, {0,64,0});
   CASE("sparse reversed lanes", 1, {12,64,0}, {4,64,0});
   CASE("zero bound", 1, {12,0,0}, {0,0,0});
   CASE("bound inside first scalar", 1, {12,1,0}, {0,1,0});
   CASE("bound inside chunk", 1, {12,5,0}, {4,5,0});
   CASE("bound before selected lanes", 1, {12,4,0}, {8,4,0});
   CASE("adjacent chunks", 2, {12,64,0}, {16,64,0}, {8,64,0}, {20,64,0});
   CASE("last chunk, max bound", 1,
        {0xfffffffc,0xffffffff,0}, {0xfffffff0,0xffffffff,0});
   CASE("last chunk, interior bound", 1,
        {0xfffffffc,0xfffffff5,0}, {0xfffffff4,0xfffffff5,0});
   CASE("different bases", 2, {12,64,0}, {0,64,1});
   CASE("different bounds", 2, {12,64,0}, {0,32,0});
   CASE("duplicate offset", 1, {4,64,0}, {4,64,0});
   return 0;
}
