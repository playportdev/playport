; SPDX-License-Identifier: GPL-3.0-or-later
; A port of DXMT code from before its LGPL relicensing: MIT, DXMT's LICENSE.OLD
; (collected by pp notices as DXMT-LICENSE.OLD.txt).
; air_tessellation.ll: hand-written LLVM 15 IR (AIR dialect) port of DXMT's
; src/airconv/shaders/air_tessellation.metal (willfaust/dxmt @ b4b89f0a,
; identical to 3Shain/dxmt v0.74). Assemble with LLVM 15.0.7 llvm-as;
; airconv_context.cpp linkTessellation() links it into converted hull and
; domain shaders.
;
; Structure. Each C++ template instantiation over `partitioning` becomes one
; internal function taking the partitioning as a leading i32 constant
; (0 integer, 1 pow2, 2 fractional_odd, 3 fractional_even); the exported
; dxmt.* entry points pass the constant. Function names otherwise follow the
; MSL source, and value names follow its variables.
;
; C conversions are spelled out: char and short are signed (sext), ushort and
; bool are unsigned (zext), and a narrowing store or parameter truncates.
;
; Floating point. The source is compiled by Metal with fast math on, and this
; file keeps every floating-point operation in the form Metal's front end
; emits for it: the same AIR intrinsic (air.fast_ceil, air.fast_clamp,
; air.convert.*, air.floor/ceil.f16) or LLVM instruction, on the same type,
; with the `fast` flags. The one place where that form is not the literal
; source is generate_triangle_for_edges: Metal computes half(i) / half(n) as
; half(i) * (1.0h / half(n)), which rounds differently in half precision, and
; this port does the same (see that function). isnan() is Metal's bit test,
; not an fcmp, so it survives fast math. See README.md, "Differential proof".
;
; Integer min()/max() calls use the AIR intrinsics Metal emits for them
; (air.min.u.i32 and friends). Plain icmp+select would be exact too, but
; airconv's InstCombine turns those into llvm.umin/smin/... on i8, i16 and
; vector types, which Apple-compiled helpers never contain and whose support
; in Metal's back end is not known.
source_filename = "air_tessellation.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx14.0.0"

; struct TessMeshWorkload (56 bytes, no implicit padding)
;  0 inner0  1 inner1  2 outer0  3 outer1       ushort2 (fxp16: 0x8000 == 1.0)
;  4 inner_factor  5 outer_factor               uint (fxp32: 16.16)
;  6 inner_factor_i  7 outer_factor_i           char
;  8 has_complement  9 padding                  bool
; 10 inner0_c 11 inner1_c 12 outer0_c 13 outer1_c
; 14 inner_factor_c 15 outer_factor_c
; 16 inner_factor_c_i 17 outer_factor_c_i
; 18 patch_index                                short
%struct.TessMeshWorkload = type { <2 x i16>, <2 x i16>, <2 x i16>, <2 x i16>, i32, i32, i8, i8, i8, i8, <2 x i16>, <2 x i16>, <2 x i16>, <2 x i16>, i32, i32, i8, i8, i16 }
; struct domain_location { float2 uv; bool active; bool iterate; }
%struct.domain_location = type { <2 x float>, i8, i8 }
%struct._mesh_t = type opaque

; ---------------------------------------------------------------------------
; Fixed-point helpers (integer only)

; uint fxp32_ceil(fxp32 f) { return (f >> 16) + ((f & 0xffff) > 0 ? 1 : 0); }
define internal i32 @fxp32_ceil(i32 %f) #0 {
entry:
  %int = lshr i32 %f, 16
  %frac = and i32 %f, 65535
  %has.frac = icmp ne i32 %frac, 0
  %up = zext i1 %has.frac to i32
  %r = add i32 %int, %up
  ret i32 %r
}

; fxp32 fxp32_invb(uint n, fxp32 v) { return (fxp32)(((ulong)n << 32) / v); }
define internal i32 @fxp32_invb(i32 %n, i32 %v) #0 {
entry:
  %n.64 = zext i32 %n to i64
  %num = shl i64 %n.64, 32
  %v.64 = zext i32 %v to i64
  %q = udiv i64 %num, %v.64
  %r = trunc i64 %q to i32
  ret i32 %r
}

; fxp16v2 mix(fxp16v2 a, fxp16v2 b, fxp32 factor)
define internal <2 x i16> @mix(<2 x i16> %a, <2 x i16> %b, i32 %factor) #0 {
entry:
  ; uint2 ai = uint2(a); uint2 bi = uint2(b);
  %ai = call <2 x i32> @air.convert.u.v2i32.u.v2i16(<2 x i16> %a) #20
  %bi = call <2 x i32> @air.convert.u.v2i32.u.v2i16(<2 x i16> %b) #20
  ; uint f = min(factor >> 1, (uint)fxp16_1);
  %half = lshr i32 %factor, 1
  %f = call i32 @air.min.u.i32(i32 %half, i32 32768) #20
  ; uint invf = fxp16_1 - f;
  %invf = sub i32 32768, %f
  %invf.ins = insertelement <2 x i32> poison, i32 %invf, i64 0
  %invf.v = shufflevector <2 x i32> %invf.ins, <2 x i32> poison, <2 x i32> zeroinitializer
  %f.ins = insertelement <2 x i32> poison, i32 %f, i64 0
  %f.v = shufflevector <2 x i32> %f.ins, <2 x i32> poison, <2 x i32> zeroinitializer
  ; uint2 ri = ((ai * invf + bi * f)) / fxp16_1;   (unsigned, so >> 15)
  %ta = mul <2 x i32> %ai, %invf.v
  %tb = mul <2 x i32> %bi, %f.v
  %sum = add <2 x i32> %ta, %tb
  %ri = lshr <2 x i32> %sum, <i32 15, i32 15>
  ; ri = min(ri, uint2(fxp16_1));
  %ri.min = call <2 x i32> @air.min.u.v2i32(<2 x i32> %ri, <2 x i32> <i32 32768, i32 32768>) #20
  ; return fxp16v2(ri);   (ri <= 0x8000, so the narrowing is exact)
  %r = call <2 x i16> @air.convert.u.v2i16.u.v2i32(<2 x i32> %ri.min) #20
  ret <2 x i16> %r
}

; float2 to_float(fxp16v2 unorm) { return (float2)unorm / float2(fxp16_1_f); }
; Division by 32768.0 is multiplication by 2^-15, exact for every ushort.
define internal <2 x float> @to_float(<2 x i16> %unorm) #0 {
entry:
  %f = call fast <2 x float> @air.convert.f.v2f32.u.v2i16(<2 x i16> %unorm) #20
  %r = fmul fast <2 x float> %f, <float 0x3F00000000000000, float 0x3F00000000000000>
  ret <2 x float> %r
}

; char get_int_factor<partition>(fxp32 factor)
;   integer, pow2:   ceil
;   fractional_odd:  c = ceil; c & 1 ? c : c + 1
;   fractional_even: c = ceil; c & 1 ? c + 1 : c
define internal i8 @get_int_factor(i32 %part, i32 %factor) #0 {
entry:
  %ceil = call i32 @fxp32_ceil(i32 %factor)
  %c = trunc i32 %ceil to i8
  %c.lsb = and i8 %c, 1
  %c.is.odd = icmp ne i8 %c.lsb, 0
  %c.plus1 = add i8 %c, 1
  %r.odd = select i1 %c.is.odd, i8 %c, i8 %c.plus1
  %r.even = select i1 %c.is.odd, i8 %c.plus1, i8 %c
  %is.odd = icmp eq i32 %part, 2
  %is.even = icmp eq i32 %part, 3
  %r.1 = select i1 %is.odd, i8 %r.odd, i8 %c
  %r = select i1 %is.even, i8 %r.even, i8 %r.1
  ret i8 %r
}

; fxp32 place_in_1d<partition>(short index, fxp32 factor)
define internal i32 @place_in_1d(i32 %part, i16 %index, i32 %factor) #0 {
entry:
  %n = sext i16 %index to i32
  switch i32 %part, label %default [
    i32 2, label %odd
    i32 3, label %even
  ]

default:
  ; return fxp32_invb(index, factor);
  %d = call i32 @fxp32_invb(i32 %n, i32 %factor)
  ret i32 %d

odd:
  ; if (factor < fxp32_1) return index ? fxp32_1 : fxp32_0;
  %odd.small = icmp ult i32 %factor, 65536
  br i1 %odd.small, label %odd.small.ret, label %odd.big

odd.small.ret:
  %idx.nz = icmp ne i16 %index, 0
  %odd.s = select i1 %idx.nz, i32 65536, i32 0
  ret i32 %odd.s

odd.big:
  ; fxp32 maxh = (fxp32_1 - fxp32_invb(1, factor)) >> 1;
  %inv1 = call i32 @fxp32_invb(i32 1, i32 %factor)
  %one.minus = sub i32 65536, %inv1
  %maxh = lshr i32 %one.minus, 1
  ; return min(fxp32_invb(index, factor), maxh);
  %odd.p = call i32 @fxp32_invb(i32 %n, i32 %factor)
  %odd.r = call i32 @air.min.u.i32(i32 %odd.p, i32 %maxh) #20
  ret i32 %odd.r

even:
  ; if (factor < fxp32_2) return index * fxp32_half;
  %even.small = icmp ult i32 %factor, 131072
  br i1 %even.small, label %even.small.ret, label %even.big

even.small.ret:
  %even.s = mul i32 %n, 32768
  ret i32 %even.s

even.big:
  ; return min(fxp32_invb(index, factor), fxp32_half);
  %even.p = call i32 @fxp32_invb(i32 %n, i32 %factor)
  %even.r = call i32 @air.min.u.i32(i32 %even.p, i32 32768) #20
  ret i32 %even.r
}

; fxp32 regularize_factor<partition>(float factor)
define internal i32 @regularize_factor(i32 %part, float %factor) #0 {
entry:
  switch i32 %part, label %integer [
    i32 1, label %pow2
    i32 2, label %odd
    i32 3, label %even
  ]

integer:
  ; ((uint)clamp(ceil(factor), 1.0f, 64.0f)) << 16
  %i.ceil = call fast float @air.fast_ceil.f32(float %factor) #20
  %i.clamp = call fast float @air.fast_clamp.f32(float %i.ceil, float 1.000000e+00, float 6.400000e+01) #20
  %i.u = call i32 @air.convert.u.i32.f.f32(float %i.clamp) #20
  %i.r = shl i32 %i.u, 16
  ret i32 %i.r

pow2:
  ; uint clamped = clamp(ceil(factor), 1.0f, 64.0f);
  %p.ceil = call fast float @air.fast_ceil.f32(float %factor) #20
  %p.clamp = call fast float @air.fast_clamp.f32(float %p.ceil, float 1.000000e+00, float 6.400000e+01) #20
  %clamped = call i32 @air.convert.u.i32.f.f32(float %p.clamp) #20
  ; return (clamped == 1 ? 1 : 1 << (32 - clz(clamped - 1))) << 16;
  %is.one = icmp eq i32 %clamped, 1
  br i1 %is.one, label %pow2.one, label %pow2.up

pow2.one:
  ret i32 65536

pow2.up:
  ; Metal masks shift counts to the operand width, hence the & 31.
  %cm1 = sub i32 %clamped, 1
  %lz = call i32 @air.clz.i32(i32 %cm1, i1 false) #20
  %sh = sub i32 32, %lz
  %sh.m = and i32 %sh, 31
  %pow = shl i32 1, %sh.m
  %p.r = shl i32 %pow, 16
  ret i32 %p.r

odd:
  ; clamp(factor, 1.0f, 63.0f) * 65536.0   (converted to fxp32)
  %o.clamp = call fast float @air.fast_clamp.f32(float %factor, float 1.000000e+00, float 6.300000e+01) #20
  %o.mul = fmul fast float %o.clamp, 6.553600e+04
  %o.r = call i32 @air.convert.u.i32.f.f32(float %o.mul) #20
  ret i32 %o.r

even:
  ; clamp(factor, 2.0f, 64.0f) * 65536.0
  %e.clamp = call fast float @air.fast_clamp.f32(float %factor, float 2.000000e+00, float 6.400000e+01) #20
  %e.mul = fmul fast float %e.clamp, 6.553600e+04
  %e.r = call i32 @air.convert.u.i32.f.f32(float %e.mul) #20
  ret i32 %e.r
}

; int get_next_index(threadgroup int *out_count)
;   __metal_atomic_fetch_add_explicit(out_count, 1, relaxed, threadgroup scope)
define internal i32 @get_next_index(i32 addrspace(3)* %out_count) #1 {
entry:
  %r = call i32 @air.atomic.local.add.s.i32(i32 addrspace(3)* %out_count, i32 1, i32 0, i32 1, i1 false) #21
  ret i32 %r
}

; fxp32 factor_offset(fxp32 base, short count)
;   result = base - ((count * fxp32_1) << 1); return result & 0x80000000 ? 0 : result;
define internal i32 @factor_offset(i32 %base, i16 %count) #0 {
entry:
  %c = sext i16 %count to i32
  %m = mul i32 %c, 65536
  %m2 = shl i32 %m, 1
  %result = sub i32 %base, %m2
  %neg = icmp slt i32 %result, 0
  %r = select i1 %neg, i32 0, i32 %result
  ret i32 %r
}

; void emit_tess_mesh_workload<partition>(workloads, out_count, in0, in1, out0,
;   out1, inner_factor, outer_factor, in0_c, in1_c, out0_c, out1_c,
;   inner_factor_c, outer_factor_c, patch_index, has_complement)
define internal void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %in0, <2 x i16> %in1, <2 x i16> %out0, <2 x i16> %out1, i32 %inner_factor, i32 %outer_factor, <2 x i16> %in0_c, <2 x i16> %in1_c, <2 x i16> %out0_c, <2 x i16> %out1_c, i32 %inner_factor_c, i32 %outer_factor_c, i16 %patch_index, i1 %has_complement) #1 {
entry:
  %inner_i = call i8 @get_int_factor(i32 %part, i32 %inner_factor)
  %outer_i = call i8 @get_int_factor(i32 %part, i32 %outer_factor)
  %inner_c_i.v = call i8 @get_int_factor(i32 %part, i32 %inner_factor_c)
  %outer_c_i.v = call i8 @get_int_factor(i32 %part, i32 %outer_factor_c)
  %inner_c_i = select i1 %has_complement, i8 %inner_c_i.v, i8 0
  %outer_c_i = select i1 %has_complement, i8 %outer_c_i.v, i8 0
  %hc = zext i1 %has_complement to i8
  %index = call i32 @get_next_index(i32 addrspace(3)* %out_count)
  %index.64 = sext i32 %index to i64
  %f0 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 0
  store <2 x i16> %in0, <2 x i16> addrspace(6)* %f0, align 4
  %f1 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 1
  store <2 x i16> %in1, <2 x i16> addrspace(6)* %f1, align 4
  %f2 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 2
  store <2 x i16> %out0, <2 x i16> addrspace(6)* %f2, align 4
  %f3 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 3
  store <2 x i16> %out1, <2 x i16> addrspace(6)* %f3, align 4
  %f4 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 4
  store i32 %inner_factor, i32 addrspace(6)* %f4, align 4
  %f5 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 5
  store i32 %outer_factor, i32 addrspace(6)* %f5, align 4
  %f6 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 6
  store i8 %inner_i, i8 addrspace(6)* %f6, align 4
  %f7 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 7
  store i8 %outer_i, i8 addrspace(6)* %f7, align 1
  %f8 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 8
  store i8 %hc, i8 addrspace(6)* %f8, align 2
  %f9 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 9
  store i8 0, i8 addrspace(6)* %f9, align 1
  %f10 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 10
  store <2 x i16> %in0_c, <2 x i16> addrspace(6)* %f10, align 4
  %f11 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 11
  store <2 x i16> %in1_c, <2 x i16> addrspace(6)* %f11, align 4
  %f12 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 12
  store <2 x i16> %out0_c, <2 x i16> addrspace(6)* %f12, align 4
  %f13 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 13
  store <2 x i16> %out1_c, <2 x i16> addrspace(6)* %f13, align 4
  %f14 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 14
  store i32 %inner_factor_c, i32 addrspace(6)* %f14, align 4
  %f15 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 15
  store i32 %outer_factor_c, i32 addrspace(6)* %f15, align 4
  %f16 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 16
  store i8 %inner_c_i, i8 addrspace(6)* %f16, align 4
  %f17 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 17
  store i8 %outer_c_i, i8 addrspace(6)* %f17, align 1
  %f18 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %index.64, i32 18
  store i16 %patch_index, i16 addrspace(6)* %f18, align 2
  ret void
}

; "isnan(x) || x <= 0" negated: Metal's isnan is a bit test, so the test is
; (|bits(x)| <= 0x7f800000) && x > 0, with the fcmp masked by a select so a
; NaN never reaches a branch.
define internal i1 @factor_is_positive(float %x) #0 {
entry:
  %bits = bitcast float %x to i32
  %abs = and i32 %bits, 2147483647
  %not.nan = icmp ult i32 %abs, 2139095041
  %gt0 = fcmp fast ugt float %x, 0.000000e+00
  %r = select i1 %not.nan, i1 %gt0, i1 false
  ret i1 %r
}

; ---------------------------------------------------------------------------
; Hull side: split a triangle patch into ring workloads

define internal void @gen_workload_triangle_impl(i32 %part, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2) #1 {
entry:
  %ok0 = call i1 @factor_is_positive(float %out0)
  br i1 %ok0, label %check1, label %exit

check1:
  %ok1 = call i1 @factor_is_positive(float %out1)
  br i1 %ok1, label %check2, label %exit

check2:
  %ok2 = call i1 @factor_is_positive(float %out2)
  br i1 %ok2, label %body, label %exit

body:
  %workloads = bitcast i32 addrspace(6)* %out_buffer to %struct.TessMeshWorkload addrspace(6)*
  %in0f.raw = call i32 @regularize_factor(i32 %part, float %in)
  %out0f = call i32 @regularize_factor(i32 %part, float %out0)
  %out1f = call i32 @regularize_factor(i32 %part, float %out1)
  %out2f = call i32 @regularize_factor(i32 %part, float %out2)
  ; fractional_odd: if ((out0f | out1f | out2f | in0f) != fxp32_1) in0f = max(fxp32_1 + 1u, in0f);
  ; integer, pow2:  if ((out0f | out1f | out2f) != fxp32_1)        in0f = max(fxp32_2, in0f);
  ; fractional_even: unchanged
  %is.odd = icmp eq i32 %part, 2
  %is.even = icmp eq i32 %part, 3
  %or.out = or i32 %out0f, %out1f
  %or.out3 = or i32 %or.out, %out2f
  %or.all = or i32 %or.out3, %in0f.raw
  %any = select i1 %is.odd, i32 %or.all, i32 %or.out3
  %any.ne = icmp ne i32 %any, 65536
  %adjust = select i1 %is.even, i1 false, i1 %any.ne
  %floor = select i1 %is.odd, i32 65537, i32 131072
  %in0f.max = call i32 @air.max.u.i32(i32 %floor, i32 %in0f.raw) #20
  %in0f = select i1 %adjust, i32 %in0f.max, i32 %in0f.raw
  ; char in0 = get_int_factor<partition>(in0f); short rings = in0 / 2;
  %in0 = call i8 @get_int_factor(i32 %part, i32 %in0f)
  %in0.16 = sext i8 %in0 to i16
  %rings = sdiv i16 %in0.16, 2
  %in0.lsb = and i8 %in0, 1
  %in0.is.odd = icmp ne i8 %in0.lsb, 0
  %pi = trunc i32 %patch_index to i16
  br label %loop

loop:
  ; for (short r = 0; r < u; r++, u--)
  %r = phi i16 [ 0, %body ], [ %r1, %loop.next ]
  %u = phi i16 [ %rings, %body ], [ %u1, %loop.next ]
  %r.lt.u = icmp slt i16 %r, %u
  br i1 %r.lt.u, label %loop.body, label %after

loop.body:
  %r1 = add i16 %r, 1
  %outer.p = call i32 @place_in_1d(i32 %part, i16 %r, i32 %in0f)
  %outer = shl i32 %outer.p, 1
  %inner.p = call i32 @place_in_1d(i32 %part, i16 %r1, i32 %in0f)
  %inner = shl i32 %inner.p, 1
  %_001x = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %outer)
  %_001i = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %inner)
  %_100x = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %outer)
  %_100i = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %inner)
  %_010x = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %outer)
  %_010i = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %inner)
  %fo.r1 = call i32 @factor_offset(i32 %in0f, i16 %r1)
  %fo.r = call i32 @factor_offset(i32 %in0f, i16 %r)
  %r.is0 = icmp eq i16 %r, 0
  %edge1 = select i1 %r.is0, i32 %out1f, i32 %fo.r
  %edge2 = select i1 %r.is0, i32 %out2f, i32 %fo.r
  %edge0 = select i1 %r.is0, i32 %out0f, i32 %fo.r
  %last = icmp eq i16 %r1, %u
  br i1 %last, label %last.ring, label %mid.ring

last.ring:
  ; if (r + 1 == u) { ...; return; }
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_001i, <2 x i16> %_100i, <2 x i16> %_001x, <2 x i16> %_100x, i32 %fo.r1, i32 %edge1, <2 x i16> %_100i, <2 x i16> %_010i, <2 x i16> %_100x, <2 x i16> %_010x, i32 %fo.r1, i32 %edge2, i16 %pi, i1 true)
  br i1 %in0.is.odd, label %last.odd, label %last.even

last.odd:
  %lo.outer.p = call i32 @place_in_1d(i32 %part, i16 %rings, i32 %in0f)
  %lo.outer = shl i32 %lo.outer.p, 1
  %_001xp = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %lo.outer)
  %_100xp = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %lo.outer)
  %_010xp = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %lo.outer)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_010i, <2 x i16> %_001i, <2 x i16> %_010x, <2 x i16> %_001x, i32 %fo.r1, i32 %edge0, <2 x i16> %_010xp, <2 x i16> %_010xp, <2 x i16> %_001xp, <2 x i16> %_100xp, i32 0, i32 65536, i16 %pi, i1 true)
  br label %exit

last.even:
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_010i, <2 x i16> %_001i, <2 x i16> %_010x, <2 x i16> %_001x, i32 %fo.r1, i32 %edge0, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, i32 0, i32 0, i16 %pi, i1 false)
  br label %exit

mid.ring:
  %u1 = sub i16 %u, 1
  %outer_c.p = call i32 @place_in_1d(i32 %part, i16 %u1, i32 %in0f)
  %outer_c = shl i32 %outer_c.p, 1
  %inner_c.p = call i32 @place_in_1d(i32 %part, i16 %u, i32 %in0f)
  %inner_c = shl i32 %inner_c.p, 1
  %_001x_c = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %outer_c)
  %_001i_c = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %inner_c)
  %_100x_c = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %outer_c)
  %_100i_c = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %inner_c)
  %_010x_c = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %outer_c)
  %_010i_c = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %inner_c)
  %fo.u = call i32 @factor_offset(i32 %in0f, i16 %u)
  %fo.u1 = call i32 @factor_offset(i32 %in0f, i16 %u1)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_001i, <2 x i16> %_100i, <2 x i16> %_001x, <2 x i16> %_100x, i32 %fo.r1, i32 %edge1, <2 x i16> %_001i_c, <2 x i16> %_100i_c, <2 x i16> %_001x_c, <2 x i16> %_100x_c, i32 %fo.u, i32 %fo.u1, i16 %pi, i1 true)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_100i, <2 x i16> %_010i, <2 x i16> %_100x, <2 x i16> %_010x, i32 %fo.r1, i32 %edge2, <2 x i16> %_100i_c, <2 x i16> %_010i_c, <2 x i16> %_100x_c, <2 x i16> %_010x_c, i32 %fo.u, i32 %fo.u1, i16 %pi, i1 true)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_010i, <2 x i16> %_001i, <2 x i16> %_010x, <2 x i16> %_001x, i32 %fo.r1, i32 %edge0, <2 x i16> %_010i_c, <2 x i16> %_001i_c, <2 x i16> %_010x_c, <2 x i16> %_001x_c, i32 %fo.u, i32 %fo.u1, i16 %pi, i1 true)
  br label %loop.next

loop.next:
  br label %loop

after:
  ; if (in0 & 1) { centre point workload }
  br i1 %in0.is.odd, label %centre, label %exit

centre:
  %c.outer.p = call i32 @place_in_1d(i32 %part, i16 %rings, i32 %in0f)
  %c.outer = shl i32 %c.outer.p, 1
  %c_001x = call <2 x i16> @mix(<2 x i16> zeroinitializer, <2 x i16> <i16 10923, i16 10923>, i32 %c.outer)
  %c_100x = call <2 x i16> @mix(<2 x i16> <i16 -32768, i16 0>, <2 x i16> <i16 10923, i16 10923>, i32 %c.outer)
  %c_010x = call <2 x i16> @mix(<2 x i16> <i16 0, i16 -32768>, <2 x i16> <i16 10923, i16 10923>, i32 %c.outer)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %c_010x, <2 x i16> %c_010x, <2 x i16> %c_001x, <2 x i16> %c_100x, i32 0, i32 65536, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, <2 x i16> <i16 10923, i16 10923>, i32 0, i32 0, i16 %pi, i1 false)
  br label %exit

exit:
  ret void
}

define void @dxmt.generate_workload.triangle.integer(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2) #2 {
entry:
  call void @gen_workload_triangle_impl(i32 0, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2)
  ret void
}

define void @dxmt.generate_workload.triangle.pow2(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2) #2 {
entry:
  call void @gen_workload_triangle_impl(i32 1, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2)
  ret void
}

define void @dxmt.generate_workload.triangle.odd(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2) #2 {
entry:
  call void @gen_workload_triangle_impl(i32 2, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2)
  ret void
}

define void @dxmt.generate_workload.triangle.even(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2) #2 {
entry:
  call void @gen_workload_triangle_impl(i32 3, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in, float %out0, float %out1, float %out2)
  ret void
}

; ---------------------------------------------------------------------------
; Hull side: split a quad patch into ring workloads

; fxp16v2 pxmy(x, y) { return {x >> 1, fxp16_1 - (y >> 1)}; }  and friends
define internal <2 x i16> @fxp16v2_from(i32 %x, i32 %y, i1 %flip.x, i1 %flip.y) #0 {
entry:
  %xh = lshr i32 %x, 1
  %yh = lshr i32 %y, 1
  %xm = sub i32 32768, %xh
  %ym = sub i32 32768, %yh
  %xv = select i1 %flip.x, i32 %xm, i32 %xh
  %yv = select i1 %flip.y, i32 %ym, i32 %yh
  %x16 = trunc i32 %xv to i16
  %y16 = trunc i32 %yv to i16
  %v0 = insertelement <2 x i16> poison, i16 %x16, i64 0
  %v1 = insertelement <2 x i16> %v0, i16 %y16, i64 1
  ret <2 x i16> %v1
}

define internal void @gen_workload_quad_impl(i32 %part, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3) #1 {
entry:
  %ok0 = call i1 @factor_is_positive(float %out0)
  br i1 %ok0, label %check1, label %exit

check1:
  %ok1 = call i1 @factor_is_positive(float %out1)
  br i1 %ok1, label %check2, label %exit

check2:
  %ok2 = call i1 @factor_is_positive(float %out2)
  br i1 %ok2, label %check3, label %exit

check3:
  %ok3 = call i1 @factor_is_positive(float %out3)
  br i1 %ok3, label %body, label %exit

body:
  %workloads = bitcast i32 addrspace(6)* %out_buffer to %struct.TessMeshWorkload addrspace(6)*
  %in0f.raw = call i32 @regularize_factor(i32 %part, float %in0)
  %in1f.raw = call i32 @regularize_factor(i32 %part, float %in1)
  %out0f = call i32 @regularize_factor(i32 %part, float %out0)
  %out1f = call i32 @regularize_factor(i32 %part, float %out1)
  %out2f = call i32 @regularize_factor(i32 %part, float %out2)
  %out3f = call i32 @regularize_factor(i32 %part, float %out3)
  %is.odd = icmp eq i32 %part, 2
  %is.even = icmp eq i32 %part, 3
  %or.a = or i32 %out0f, %out1f
  %or.b = or i32 %or.a, %out2f
  %or.out4 = or i32 %or.b, %out3f
  %or.c = or i32 %or.out4, %in0f.raw
  %or.all = or i32 %or.c, %in1f.raw
  %any = select i1 %is.odd, i32 %or.all, i32 %or.out4
  %any.ne = icmp ne i32 %any, 65536
  %adjust = select i1 %is.even, i1 false, i1 %any.ne
  %floor = select i1 %is.odd, i32 65537, i32 131072
  %in0f.max = call i32 @air.max.u.i32(i32 %floor, i32 %in0f.raw) #20
  %in0f = select i1 %adjust, i32 %in0f.max, i32 %in0f.raw
  %in1f.max = call i32 @air.max.u.i32(i32 %floor, i32 %in1f.raw) #20
  %in1f = select i1 %adjust, i32 %in1f.max, i32 %in1f.raw
  ; char in0i, in1i; short min_in = min(in0i, in1i); short rings = min_in / 2;
  ; short u = max(in0i, in1i) / 2;
  %in0i = call i8 @get_int_factor(i32 %part, i32 %in0f)
  %in1i = call i8 @get_int_factor(i32 %part, i32 %in1f)
  %min8 = call i8 @air.min.s.i8(i8 %in0i, i8 %in1i) #20
  %max8 = call i8 @air.max.s.i8(i8 %in0i, i8 %in1i) #20
  %min_in = sext i8 %min8 to i16
  %rings = sdiv i16 %min_in, 2
  %max16 = sext i8 %max8 to i16
  %u0 = sdiv i16 %max16, 2
  %pi = trunc i32 %patch_index to i16
  br label %loop

loop:
  ; for (short r = 0; r < u && r < rings; r++, u--)
  %r = phi i16 [ 0, %body ], [ %r1, %mid.ring ]
  %u = phi i16 [ %u0, %body ], [ %u1, %mid.ring ]
  %r.lt.u = icmp slt i16 %r, %u
  %r.lt.rings = icmp slt i16 %r, %rings
  %cont = and i1 %r.lt.u, %r.lt.rings
  br i1 %cont, label %loop.body, label %after

loop.body:
  %r1 = add i16 %r, 1
  %x_coord = call i32 @place_in_1d(i32 %part, i16 %r, i32 %in0f)
  %y_coord = call i32 @place_in_1d(i32 %part, i16 %r, i32 %in1f)
  %x_coordi = call i32 @place_in_1d(i32 %part, i16 %r1, i32 %in0f)
  %y_coordi = call i32 @place_in_1d(i32 %part, i16 %r1, i32 %in1f)
  ; pxmy = (0,1); mxmy = (1,1); pxpy = (0,0); mxpy = (1,0)
  %_01x = call <2 x i16> @fxp16v2_from(i32 %x_coord, i32 %y_coord, i1 false, i1 true)
  %_11x = call <2 x i16> @fxp16v2_from(i32 %x_coord, i32 %y_coord, i1 true, i1 true)
  %_00x = call <2 x i16> @fxp16v2_from(i32 %x_coord, i32 %y_coord, i1 false, i1 false)
  %_10x = call <2 x i16> @fxp16v2_from(i32 %x_coord, i32 %y_coord, i1 true, i1 false)
  %_01i = call <2 x i16> @fxp16v2_from(i32 %x_coordi, i32 %y_coordi, i1 false, i1 true)
  %_11i = call <2 x i16> @fxp16v2_from(i32 %x_coordi, i32 %y_coordi, i1 true, i1 true)
  %_00i = call <2 x i16> @fxp16v2_from(i32 %x_coordi, i32 %y_coordi, i1 false, i1 false)
  %_10i = call <2 x i16> @fxp16v2_from(i32 %x_coordi, i32 %y_coordi, i1 true, i1 false)
  %fo0.r1 = call i32 @factor_offset(i32 %in0f, i16 %r1)
  %fo1.r1 = call i32 @factor_offset(i32 %in1f, i16 %r1)
  %fo0.r = call i32 @factor_offset(i32 %in0f, i16 %r)
  %fo1.r = call i32 @factor_offset(i32 %in1f, i16 %r)
  %r.is0 = icmp eq i16 %r, 0
  %edge3 = select i1 %r.is0, i32 %out3f, i32 %fo0.r
  %edge2 = select i1 %r.is0, i32 %out2f, i32 %fo1.r
  %edge1 = select i1 %r.is0, i32 %out1f, i32 %fo0.r
  %edge0 = select i1 %r.is0, i32 %out0f, i32 %fo1.r
  %last = icmp eq i16 %r1, %u
  br i1 %last, label %last.ring, label %mid.ring

last.ring:
  ; if (r + 1 == u) { two workloads; break; }
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_11i, <2 x i16> %_01i, <2 x i16> %_11x, <2 x i16> %_01x, i32 %fo0.r1, i32 %edge3, <2 x i16> %_10i, <2 x i16> %_11i, <2 x i16> %_10x, <2 x i16> %_11x, i32 %fo1.r1, i32 %edge2, i16 %pi, i1 true)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_00i, <2 x i16> %_10i, <2 x i16> %_00x, <2 x i16> %_10x, i32 %fo0.r1, i32 %edge1, <2 x i16> %_01i, <2 x i16> %_00i, <2 x i16> %_01x, <2 x i16> %_00x, i32 %fo1.r1, i32 %edge0, i16 %pi, i1 true)
  br label %after

mid.ring:
  %u1 = sub i16 %u, 1
  %x_coord_c = call i32 @place_in_1d(i32 %part, i16 %u1, i32 %in0f)
  %y_coord_c = call i32 @place_in_1d(i32 %part, i16 %u1, i32 %in1f)
  %x_coordi_c = call i32 @place_in_1d(i32 %part, i16 %u, i32 %in0f)
  %y_coordi_c = call i32 @place_in_1d(i32 %part, i16 %u, i32 %in1f)
  %_01x_c = call <2 x i16> @fxp16v2_from(i32 %x_coord_c, i32 %y_coord_c, i1 false, i1 true)
  %_11x_c = call <2 x i16> @fxp16v2_from(i32 %x_coord_c, i32 %y_coord_c, i1 true, i1 true)
  %_00x_c = call <2 x i16> @fxp16v2_from(i32 %x_coord_c, i32 %y_coord_c, i1 false, i1 false)
  %_10x_c = call <2 x i16> @fxp16v2_from(i32 %x_coord_c, i32 %y_coord_c, i1 true, i1 false)
  %_01i_c = call <2 x i16> @fxp16v2_from(i32 %x_coordi_c, i32 %y_coordi_c, i1 false, i1 true)
  %_11i_c = call <2 x i16> @fxp16v2_from(i32 %x_coordi_c, i32 %y_coordi_c, i1 true, i1 true)
  %_00i_c = call <2 x i16> @fxp16v2_from(i32 %x_coordi_c, i32 %y_coordi_c, i1 false, i1 false)
  %_10i_c = call <2 x i16> @fxp16v2_from(i32 %x_coordi_c, i32 %y_coordi_c, i1 true, i1 false)
  %fo0.u = call i32 @factor_offset(i32 %in0f, i16 %u)
  %fo0.u1 = call i32 @factor_offset(i32 %in0f, i16 %u1)
  %fo1.u = call i32 @factor_offset(i32 %in1f, i16 %u)
  %fo1.u1 = call i32 @factor_offset(i32 %in1f, i16 %u1)
  ; has_complement = u - 1 < rings
  %hc = icmp slt i16 %u1, %rings
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_11i, <2 x i16> %_01i, <2 x i16> %_11x, <2 x i16> %_01x, i32 %fo0.r1, i32 %edge3, <2 x i16> %_11i_c, <2 x i16> %_01i_c, <2 x i16> %_11x_c, <2 x i16> %_01x_c, i32 %fo0.u, i32 %fo0.u1, i16 %pi, i1 %hc)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_10i, <2 x i16> %_11i, <2 x i16> %_10x, <2 x i16> %_11x, i32 %fo1.r1, i32 %edge2, <2 x i16> %_10i_c, <2 x i16> %_11i_c, <2 x i16> %_10x_c, <2 x i16> %_11x_c, i32 %fo1.u, i32 %fo1.u1, i16 %pi, i1 %hc)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_00i, <2 x i16> %_10i, <2 x i16> %_00x, <2 x i16> %_10x, i32 %fo0.r1, i32 %edge1, <2 x i16> %_00i_c, <2 x i16> %_10i_c, <2 x i16> %_00x_c, <2 x i16> %_10x_c, i32 %fo0.u, i32 %fo0.u1, i16 %pi, i1 %hc)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %_01i, <2 x i16> %_00i, <2 x i16> %_01x, <2 x i16> %_00x, i32 %fo1.r1, i32 %edge0, <2 x i16> %_01i_c, <2 x i16> %_00i_c, <2 x i16> %_01x_c, <2 x i16> %_00x_c, i32 %fo1.u, i32 %fo1.u1, i16 %pi, i1 %hc)
  br label %loop

after:
  ; if (min_in & 1) { centre strip workload }
  %min.lsb = and i16 %min_in, 1
  %min.odd = icmp ne i16 %min.lsb, 0
  br i1 %min.odd, label %centre, label %exit

centre:
  %cx = call i32 @place_in_1d(i32 %part, i16 %rings, i32 %in0f)
  %cy = call i32 @place_in_1d(i32 %part, i16 %rings, i32 %in1f)
  %c_01x = call <2 x i16> @fxp16v2_from(i32 %cx, i32 %cy, i1 false, i1 true)
  %c_11x = call <2 x i16> @fxp16v2_from(i32 %cx, i32 %cy, i1 true, i1 true)
  %c_00x = call <2 x i16> @fxp16v2_from(i32 %cx, i32 %cy, i1 false, i1 false)
  %c_10x = call <2 x i16> @fxp16v2_from(i32 %cx, i32 %cy, i1 true, i1 false)
  ; `in0 > in1` compares the float parameters, not the char factors
  %in0.gt.in1 = fcmp fast ogt float %in0, %in1
  br i1 %in0.gt.in1, label %centre.x, label %centre.y

centre.x:
  %fo0.rings = call i32 @factor_offset(i32 %in0f, i16 %rings)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %c_01x, <2 x i16> %c_11x, <2 x i16> %c_00x, <2 x i16> %c_10x, i32 %fo0.rings, i32 %fo0.rings, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, i32 0, i32 0, i16 %pi, i1 false)
  br label %exit

centre.y:
  %fo1.rings = call i32 @factor_offset(i32 %in1f, i16 %rings)
  call void @emit_tess_mesh_workload(i32 %part, %struct.TessMeshWorkload addrspace(6)* %workloads, i32 addrspace(3)* %out_count, <2 x i16> %c_11x, <2 x i16> %c_10x, <2 x i16> %c_01x, <2 x i16> %c_00x, i32 %fo1.rings, i32 %fo1.rings, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, <2 x i16> zeroinitializer, i32 0, i32 0, i16 %pi, i1 false)
  br label %exit

exit:
  ret void
}

define void @dxmt.generate_workload.quad.integer(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3) #2 {
entry:
  call void @gen_workload_quad_impl(i32 0, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3)
  ret void
}

define void @dxmt.generate_workload.quad.pow2(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3) #2 {
entry:
  call void @gen_workload_quad_impl(i32 1, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3)
  ret void
}

define void @dxmt.generate_workload.quad.odd(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3) #2 {
entry:
  call void @gen_workload_quad_impl(i32 2, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3)
  ret void
}

define void @dxmt.generate_workload.quad.even(i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3) #2 {
entry:
  call void @gen_workload_quad_impl(i32 3, i32 %patch_index, i32 addrspace(3)* %out_count, i32 addrspace(6)* %out_buffer, float %in0, float %in1, float %out0, float %out1, float %out2, float %out3)
  ret void
}

; ---------------------------------------------------------------------------
; Domain side: locate a thread's point inside a workload

; float2 get_domain_point<partition>(object_data TessMeshWorkload &workload, ushort tid)
define internal <2 x float> @get_domain_point(i32 %part, %struct.TessMeshWorkload addrspace(6)* %w, i16 %tid.in) #0 {
entry:
  %p.inner0 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 0
  %p.inner1 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 1
  %p.outer0 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 2
  %p.outer1 = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 3
  %p.inner_factor = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 4
  %p.outer_factor = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 5
  %p.inner_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 6
  %p.outer_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 7
  %p.inner0_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 10
  %p.inner1_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 11
  %p.outer0_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 12
  %p.outer1_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 13
  %p.inner_factor_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 14
  %p.outer_factor_c = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 15
  %p.inner_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 16
  %p.outer_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 17
  %inner_i = load i8, i8 addrspace(6)* %p.inner_i, align 4
  %outer_i = load i8, i8 addrspace(6)* %p.outer_i, align 1
  %inner_c_i = load i8, i8 addrspace(6)* %p.inner_c_i, align 4
  %outer_c_i = load i8, i8 addrspace(6)* %p.outer_c_i, align 1
  %a = sext i8 %inner_i to i32
  %b = sext i8 %outer_i to i32
  %c = sext i8 %inner_c_i to i32
  %d = sext i8 %outer_c_i to i32
  %tid0 = zext i16 %tid.in to i32
  ; bool point_at_out    = tid > inner_factor_i;
  ; bool point_at_in_c   = tid > inner_factor_i + outer_factor_i + 1;
  ; bool point_at_out_c  = tid > inner_factor_i + outer_factor_i + inner_factor_c_i + 2;
  %point_at_out = icmp sgt i32 %tid0, %a
  %ab = add i32 %a, %b
  %ab1 = add i32 %ab, 1
  %point_at_in_c = icmp sgt i32 %tid0, %ab1
  %abc = add i32 %ab, %c
  %abc2 = add i32 %abc, 2
  %point_at_out_c = icmp sgt i32 %tid0, %abc2
  ; char real_factor = select(...)
  %rf.1 = select i1 %point_at_out, i8 %outer_i, i8 %inner_i
  %rf.2 = select i1 %point_at_in_c, i8 %inner_c_i, i8 %rf.1
  %real_factor = select i1 %point_at_out_c, i8 %outer_c_i, i8 %rf.2
  ; tid = select(tid, (ushort)(tid - (inner_factor_i + 1)), point_at_out); etc.
  %a1 = add i32 %a, 1
  %t1.v = sub i32 %tid0, %a1
  %t1.s = trunc i32 %t1.v to i16
  %tid1 = select i1 %point_at_out, i16 %t1.s, i16 %tid.in
  %tid1.32 = zext i16 %tid1 to i32
  %b1 = add i32 %b, 1
  %t2.v = sub i32 %tid1.32, %b1
  %t2.s = trunc i32 %t2.v to i16
  %tid2 = select i1 %point_at_in_c, i16 %t2.s, i16 %tid1
  %tid2.32 = zext i16 %tid2 to i32
  %c1 = add i32 %c, 1
  %t3.v = sub i32 %tid2.32, %c1
  %t3.s = trunc i32 %t3.v to i16
  %tid = select i1 %point_at_out_c, i16 %t3.s, i16 %tid2
  ; left / right / factor
  %inner0 = load <2 x i16>, <2 x i16> addrspace(6)* %p.inner0, align 4
  %outer0 = load <2 x i16>, <2 x i16> addrspace(6)* %p.outer0, align 4
  %inner0_c = load <2 x i16>, <2 x i16> addrspace(6)* %p.inner0_c, align 4
  %outer0_c = load <2 x i16>, <2 x i16> addrspace(6)* %p.outer0_c, align 4
  %l.1 = select i1 %point_at_out, <2 x i16> %outer0, <2 x i16> %inner0
  %l.2 = select i1 %point_at_in_c, <2 x i16> %inner0_c, <2 x i16> %l.1
  %left = select i1 %point_at_out_c, <2 x i16> %outer0_c, <2 x i16> %l.2
  %inner1 = load <2 x i16>, <2 x i16> addrspace(6)* %p.inner1, align 4
  %outer1 = load <2 x i16>, <2 x i16> addrspace(6)* %p.outer1, align 4
  %inner1_c = load <2 x i16>, <2 x i16> addrspace(6)* %p.inner1_c, align 4
  %outer1_c = load <2 x i16>, <2 x i16> addrspace(6)* %p.outer1_c, align 4
  %r.1 = select i1 %point_at_out, <2 x i16> %outer1, <2 x i16> %inner1
  %r.2 = select i1 %point_at_in_c, <2 x i16> %inner1_c, <2 x i16> %r.1
  %right = select i1 %point_at_out_c, <2 x i16> %outer1_c, <2 x i16> %r.2
  %inner_factor = load i32, i32 addrspace(6)* %p.inner_factor, align 4
  %outer_factor = load i32, i32 addrspace(6)* %p.outer_factor, align 4
  %inner_factor_c = load i32, i32 addrspace(6)* %p.inner_factor_c, align 4
  %outer_factor_c = load i32, i32 addrspace(6)* %p.outer_factor_c, align 4
  %fa.1 = select i1 %point_at_out, i32 %outer_factor, i32 %inner_factor
  %fa.2 = select i1 %point_at_in_c, i32 %inner_factor_c, i32 %fa.1
  %factor = select i1 %point_at_out_c, i32 %outer_factor_c, i32 %fa.2
  ; if (real_factor == 0) return to_float(min(left, right));
  %rf.zero = icmp eq i8 %real_factor, 0
  br i1 %rf.zero, label %edge.case, label %regular

edge.case:
  %lr.min = call <2 x i16> @air.min.u.v2i16(<2 x i16> %left, <2 x i16> %right) #20
  %e.r = call <2 x float> @to_float(<2 x i16> %lr.min)
  ret <2 x float> %e.r

regular:
  ; ushort tid_ref = real_factor - tid;
  %rf.32 = sext i8 %real_factor to i32
  %tid.32 = zext i16 %tid to i32
  %tr.v = sub i32 %rf.32, %tid.32
  %tid_ref = trunc i32 %tr.v to i16
  ; fxp32 ratio = place_in_1d<partition>(min(tid, tid_ref), factor);
  %t.min = call i16 @air.min.u.i16(i16 %tid, i16 %tid_ref) #20
  %ratio.0 = call i32 @place_in_1d(i32 %part, i16 %t.min, i32 %factor)
  ; ratio = select(ratio, fxp32_1 - ratio, tid_ref < tid);
  %flip = icmp ult i16 %tid_ref, %tid
  %ratio.inv = sub i32 65536, %ratio.0
  %ratio = select i1 %flip, i32 %ratio.inv, i32 %ratio.0
  %mixed = call <2 x i16> @mix(<2 x i16> %left, <2 x i16> %right, i32 %ratio)
  %r.r = call <2 x float> @to_float(<2 x i16> %mixed)
  ret <2 x float> %r.r
}

define i32 @dxmt.get_domain_patch_index(i32 %workload_index, i32 addrspace(6)* nocapture readonly %data) #3 {
entry:
  %workloads = bitcast i32 addrspace(6)* %data to %struct.TessMeshWorkload addrspace(6)*
  %wi = sext i32 %workload_index to i64
  %p = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 18
  %v = load i16, i16 addrspace(6)* %p, align 2
  %r = sext i16 %v to i32
  ret i32 %r
}

; domain_location get_domain_location_impl<partition>(workload_index, thread_index, data)
define internal %struct.domain_location @get_domain_location_impl(i32 %part, i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #4 {
entry:
  ; simdgroup_barrier(mem_flags::mem_none);
  call void @air.simdgroup.barrier(i32 0, i32 1) #22
  %workloads = bitcast i32 addrspace(6)* %data to %struct.TessMeshWorkload addrspace(6)*
  %wi = sext i32 %workload_index to i64
  %w = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi
  ; int count = inner_factor_i + outer_factor_i + 2;
  ; if (has_complement) count += inner_factor_c_i + outer_factor_c_i + 2;
  %p.inner_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 6
  %p.outer_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 7
  %p.hc = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 8
  %p.inner_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 16
  %p.outer_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %w, i64 0, i32 17
  %inner_i = load i8, i8 addrspace(6)* %p.inner_i, align 4
  %outer_i = load i8, i8 addrspace(6)* %p.outer_i, align 1
  %a = sext i8 %inner_i to i32
  %b = sext i8 %outer_i to i32
  %ab = add i32 %a, %b
  %count0 = add i32 %ab, 2
  %hc = load i8, i8 addrspace(6)* %p.hc, align 2
  %has_complement = icmp ne i8 %hc, 0
  br i1 %has_complement, label %complement, label %counted

complement:
  %inner_c_i = load i8, i8 addrspace(6)* %p.inner_c_i, align 4
  %outer_c_i = load i8, i8 addrspace(6)* %p.outer_c_i, align 1
  %c = sext i8 %inner_c_i to i32
  %d = sext i8 %outer_c_i to i32
  %cd = add i32 %c, %d
  %cd2 = add i32 %cd, 2
  %count1 = add i32 %count0, %cd2
  br label %counted

counted:
  %count = phi i32 [ %count0, %entry ], [ %count1, %complement ]
  ; if (thread_index < count) { ret.active = true; ret.uv = get_domain_point(...); }
  %active = icmp slt i32 %thread_index, %count
  br i1 %active, label %point, label %join

point:
  %tid = trunc i32 %thread_index to i16
  %uv.p = call <2 x float> @get_domain_point(i32 %part, %struct.TessMeshWorkload addrspace(6)* %w, i16 %tid)
  br label %join

join:
  %uv = phi <2 x float> [ zeroinitializer, %counted ], [ %uv.p, %point ]
  %active.8 = zext i1 %active to i8
  ; simdgroup_barrier(mem_flags::mem_none); ret.iterate = simd_all(ret.active);
  call void @air.simdgroup.barrier(i32 0, i32 1) #22
  %all = call i1 @air.simd_all(i1 %active) #22
  %iterate.8 = zext i1 %all to i8
  %ret.0 = insertvalue %struct.domain_location poison, <2 x float> %uv, 0
  %ret.1 = insertvalue %struct.domain_location %ret.0, i8 %active.8, 1
  %ret.2 = insertvalue %struct.domain_location %ret.1, i8 %iterate.8, 2
  ret %struct.domain_location %ret.2
}

define %struct.domain_location @dxmt.get_domain_location.integer(i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #4 {
entry:
  %r = call %struct.domain_location @get_domain_location_impl(i32 0, i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #23
  ret %struct.domain_location %r
}

define %struct.domain_location @dxmt.get_domain_location.pow2(i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #4 {
entry:
  %r = call %struct.domain_location @get_domain_location_impl(i32 1, i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #23
  ret %struct.domain_location %r
}

define %struct.domain_location @dxmt.get_domain_location.odd(i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #4 {
entry:
  %r = call %struct.domain_location @get_domain_location_impl(i32 2, i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #23
  ret %struct.domain_location %r
}

define %struct.domain_location @dxmt.get_domain_location.even(i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #4 {
entry:
  %r = call %struct.domain_location @get_domain_location_impl(i32 3, i32 %workload_index, i32 %thread_index, i32 addrspace(6)* %data) #23
  ret %struct.domain_location %r
}

; ---------------------------------------------------------------------------
; Domain side: emit the primitives of a workload into the mesh
; (metal::mesh<dummy_vertex, void, 130, 128, topology::triangle>; indices are uchar)

; void generate_triangle_for_edges(MeshTri mesh, short base_inner, short base_outer,
;                                  short inner, short outer, short provoke_offset, short ccw_xor)
define internal void @generate_triangle_for_edges(%struct._mesh_t addrspace(7)* %mesh, i16 %base_inner, i16 %base_outer, i16 %inner, i16 %outer, i16 %provoke_offset, i16 %ccw_xor) #1 {
entry:
  %bi = sext i16 %base_inner to i32
  %bo = sext i16 %base_outer to i32
  %po = sext i16 %provoke_offset to i32
  %ccw = sext i16 %ccw_xor to i32
  %slot1 = xor i32 %ccw, 1
  %slot2 = xor i32 %ccw, 2
  %inner.32 = sext i16 %inner to i32
  ; for (short i = 0; i <= inner; i++)
  %any = icmp sle i16 0, %inner
  br i1 %any, label %pre, label %exit

pre:
  ; half(i) / half(inner + 1) is computed the way Metal compiles it under fast
  ; math: one reciprocal 1.0h / half(inner + 1), hoisted out of the loop, then
  ; a multiply. Metal emits the reciprocal separately for frac_left and
  ; frac_right, and so does this port.
  %n = add i32 %inner.32, 1
  %n.h = call fast half @air.convert.f.f16.s.i32(i32 %n) #20
  %rcp.l = fdiv fast half 0xH3C00, %n.h
  %rcp.r = fdiv fast half 0xH3C00, %n.h
  %outer.h.l = call fast half @air.convert.f.f16.s.i16(i16 %outer) #20
  %outer.h.r = call fast half @air.convert.f.f16.s.i16(i16 %outer) #20
  br label %loop

loop:
  %i = phi i16 [ 0, %pre ], [ %i.next, %strip.tri ]
  %i.32 = sext i16 %i to i32
  ; half frac_left = half(i) / half(inner + 1);
  %i.h = call fast half @air.convert.f.f16.s.i16(i16 %i) #20
  %frac_left = fmul fast half %i.h, %rcp.l
  ; half frac_right = half(i + 1) / half(inner + 1);
  %i1.32 = add i32 %i.32, 1
  %i1.h = call fast half @air.convert.f.f16.s.i32(i32 %i1.32) #20
  %frac_right = fmul fast half %i1.h, %rcp.r
  ; short left = frac_left <= 0.5 ? floor(frac_left * half(outer)) : ceil(frac_left * half(outer));
  %l.gt = fcmp fast ugt half %frac_left, 0xH3800
  %l.x = fmul fast half %outer.h.l, %frac_left
  br i1 %l.gt, label %l.ceil, label %l.floor

l.floor:
  %l.f = call fast half @air.floor.f16(half %l.x) #20
  br label %l.done

l.ceil:
  %l.c = call fast half @air.ceil.f16(half %l.x) #20
  br label %l.done

l.done:
  %l.h = phi fast half [ %l.f, %l.floor ], [ %l.c, %l.ceil ]
  %left = call i16 @air.convert.s.i16.f.f16(half %l.h) #20
  ; short right = frac_right <= 0.5 ? floor(frac_right * half(outer)) : ceil(frac_right * half(outer));
  %r.gt = fcmp fast ugt half %frac_right, 0xH3800
  %r.x = fmul fast half %outer.h.r, %frac_right
  br i1 %r.gt, label %r.ceil, label %r.floor

r.floor:
  %r.f = call fast half @air.floor.f16(half %r.x) #20
  br label %r.done

r.ceil:
  %r.c = call fast half @air.ceil.f16(half %r.x) #20
  br label %r.done

r.done:
  %r.h = phi fast half [ %r.f, %r.floor ], [ %r.c, %r.ceil ]
  %right = call i16 @air.convert.s.i16.f.f16(half %r.h) #20
  ; short count = right - left;
  %left.32 = sext i16 %left to i32
  %right.32 = sext i16 %right to i32
  %cnt.32 = sub i32 %right.32, %left.32
  %count = trunc i32 %cnt.32 to i16
  %bol = add i32 %bo, %left.32
  %bi.i = add i32 %bi, %i.32
  %bi.i.8 = trunc i32 %bi.i to i8
  ; if (count) for (short j = 0; j < count; j++) { ... }
  %has = icmp sgt i16 %count, 0
  br i1 %has, label %fan, label %fan.done

fan:
  %j = phi i16 [ 0, %r.done ], [ %j.next, %fan ]
  %j.32 = sext i16 %j to i32
  ; short primitive_index = base_outer + left + j - provoke_offset - 1;
  %v0 = add i32 %bol, %j.32
  %pi.a = sub i32 %v0, %po
  %pi.b = sub i32 %pi.a, 1
  %pi.s = trunc i32 %pi.b to i16
  %pi.32 = sext i16 %pi.s to i32
  %base3 = mul i32 %pi.32, 3
  %v0.8 = trunc i32 %v0 to i8
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %base3, i8 %v0.8) #24
  %idx1 = add i32 %base3, %slot1
  %v1 = add i32 %v0, 1
  %v1.8 = trunc i32 %v1 to i8
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %idx1, i8 %v1.8) #24
  %idx2 = add i32 %base3, %slot2
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %idx2, i8 %bi.i.8) #24
  %j.next = add i16 %j, 1
  %j.more = icmp slt i16 %j.next, %count
  br i1 %j.more, label %fan, label %fan.done

fan.done:
  ; if (i == inner) break;
  %is.last = icmp eq i16 %i, %inner
  br i1 %is.last, label %exit, label %strip.tri

strip.tri:
  ; short primitive_index = base_inner + i - provoke_offset;
  %q.a = sub i32 %bi.i, %po
  %q.s = trunc i32 %q.a to i16
  %q.32 = sext i16 %q.s to i32
  %qbase3 = mul i32 %q.32, 3
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %qbase3, i8 %bi.i.8) #24
  %qidx1 = add i32 %qbase3, %slot1
  %bor = add i32 %bo, %right.32
  %bor.8 = trunc i32 %bor to i8
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %qidx1, i8 %bor.8) #24
  %qidx2 = add i32 %qbase3, %slot2
  %bi.i1 = add i32 %bi.i, 1
  %bi.i1.8 = trunc i32 %bi.i1 to i8
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %qidx2, i8 %bi.i1.8) #24
  %i.next = add i16 %i, 1
  %i.more = icmp sle i16 %i.next, %inner
  br i1 %i.more, label %loop, label %exit

exit:
  ret void
}

; generatePrimitiveTriangle / generatePrimitiveTriangleCCW (ccw_xor 0 / 3)
define internal void @generate_primitive_triangle(i16 %ccw_xor, i32 %workload_index, i32 addrspace(6)* %data, %struct._mesh_t addrspace(7)* %mesh) #1 {
entry:
  %workloads = bitcast i32 addrspace(6)* %data to %struct.TessMeshWorkload addrspace(6)*
  %wi = sext i32 %workload_index to i64
  %p.inner_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 6
  %p.outer_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 7
  %p.hc = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 8
  %p.inner_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 16
  %p.outer_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 17
  ; short max_in = inner_factor_i, max_out = outer_factor_i, base_outer = max_in + 1;
  %inner_i = load i8, i8 addrspace(6)* %p.inner_i, align 4
  %outer_i = load i8, i8 addrspace(6)* %p.outer_i, align 1
  %max_in = sext i8 %inner_i to i16
  %max_out = sext i8 %outer_i to i16
  %base_outer = add i16 %max_in, 1
  ; primitive_count += max_in + max_out;
  %pc0 = add i16 %max_in, %max_out
  call void @generate_triangle_for_edges(%struct._mesh_t addrspace(7)* %mesh, i16 0, i16 %base_outer, i16 %max_in, i16 %max_out, i16 0, i16 %ccw_xor)
  %hc = load i8, i8 addrspace(6)* %p.hc, align 2
  %has_complement = icmp ne i8 %hc, 0
  br i1 %has_complement, label %complement, label %done

complement:
  %inner_c_i = load i8, i8 addrspace(6)* %p.inner_c_i, align 4
  %outer_c_i = load i8, i8 addrspace(6)* %p.outer_c_i, align 1
  %max_in_c = sext i8 %inner_c_i to i16
  %max_out_c = sext i8 %outer_c_i to i16
  ; short base_inner = 2 + inner_factor_i + outer_factor_i; base_outer = base_inner + max_in + 1;
  %s = add i16 %max_in, %max_out
  %base_inner_c = add i16 %s, 2
  %bo.a = add i16 %base_inner_c, %max_in_c
  %base_outer_c = add i16 %bo.a, 1
  %pc.a = add i16 %pc0, %max_in_c
  %pc1 = add i16 %pc.a, %max_out_c
  call void @generate_triangle_for_edges(%struct._mesh_t addrspace(7)* %mesh, i16 %base_inner_c, i16 %base_outer_c, i16 %max_in_c, i16 %max_out_c, i16 2, i16 %ccw_xor)
  br label %done

done:
  %pc = phi i16 [ %pc0, %entry ], [ %pc1, %complement ]
  %pc.32 = sext i16 %pc to i32
  call void @air.set_primitive_count_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %pc.32) #24
  ret void
}

define void @dxmt.domain_generate_primitives.triangle(i32 %workload_index, i32 addrspace(6)* nocapture readonly %data, %struct._mesh_t addrspace(7)* %mesh) #2 {
entry:
  call void @generate_primitive_triangle(i16 0, i32 %workload_index, i32 addrspace(6)* %data, %struct._mesh_t addrspace(7)* %mesh)
  ret void
}

define void @dxmt.domain_generate_primitives.triangle_ccw(i32 %workload_index, i32 addrspace(6)* nocapture readonly %data, %struct._mesh_t addrspace(7)* %mesh) #2 {
entry:
  call void @generate_primitive_triangle(i16 3, i32 %workload_index, i32 addrspace(6)* %data, %struct._mesh_t addrspace(7)* %mesh)
  ret void
}

; for (short i = 0; i < n + 1; i++) mesh.set_index(index_count++, i + base);
; returns the new index_count
define internal i16 @emit_point_run(%struct._mesh_t addrspace(7)* %mesh, i16 %index_count, i16 %n, i32 %base) #1 {
entry:
  %n.32 = sext i16 %n to i32
  %limit = add i32 %n.32, 1
  %any = icmp sgt i32 %limit, 0
  br i1 %any, label %loop, label %exit

loop:
  %i = phi i16 [ 0, %entry ], [ %i.next, %loop ]
  %ic = phi i16 [ %index_count, %entry ], [ %ic.next, %loop ]
  %ic.32 = sext i16 %ic to i32
  %i.32 = sext i16 %i to i32
  %v = add i32 %i.32, %base
  %v.8 = trunc i32 %v to i8
  call void @air.set_index_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %ic.32, i8 %v.8) #24
  %ic.next = add i16 %ic, 1
  %i.next = add i16 %i, 1
  %i.next.32 = sext i16 %i.next to i32
  %more = icmp slt i32 %i.next.32, %limit
  br i1 %more, label %loop, label %exit

exit:
  %r = phi i16 [ %index_count, %entry ], [ %ic.next, %loop ]
  ret i16 %r
}

define void @dxmt.domain_generate_primitives.point(i32 %workload_index, i32 addrspace(6)* nocapture readonly %data, %struct._mesh_t addrspace(7)* %mesh) #1 {
entry:
  %workloads = bitcast i32 addrspace(6)* %data to %struct.TessMeshWorkload addrspace(6)*
  %wi = sext i32 %workload_index to i64
  %p.inner_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 6
  %p.outer_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 7
  %p.hc = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 8
  %p.inner_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 16
  %p.outer_c_i = getelementptr inbounds %struct.TessMeshWorkload, %struct.TessMeshWorkload addrspace(6)* %workloads, i64 %wi, i32 17
  %inner_i = load i8, i8 addrspace(6)* %p.inner_i, align 4
  %outer_i = load i8, i8 addrspace(6)* %p.outer_i, align 1
  %max_in = sext i8 %inner_i to i16
  %max_out = sext i8 %outer_i to i16
  %max_in.32 = sext i16 %max_in to i32
  %base_outer = add i32 %max_in.32, 1
  %ic1 = call i16 @emit_point_run(%struct._mesh_t addrspace(7)* %mesh, i16 0, i16 %max_in, i32 0)
  %ic2 = call i16 @emit_point_run(%struct._mesh_t addrspace(7)* %mesh, i16 %ic1, i16 %max_out, i32 %base_outer)
  %hc = load i8, i8 addrspace(6)* %p.hc, align 2
  %has_complement = icmp ne i8 %hc, 0
  br i1 %has_complement, label %complement, label %done

complement:
  %inner_c_i = load i8, i8 addrspace(6)* %p.inner_c_i, align 4
  %outer_c_i = load i8, i8 addrspace(6)* %p.outer_c_i, align 1
  %max_in_c = sext i8 %inner_c_i to i16
  %max_out_c = sext i8 %outer_c_i to i16
  ; short base_inner = 2 + inner_factor_i + outer_factor_i; base_outer = base_inner + max_in + 1;
  %a = sext i8 %inner_i to i32
  %b = sext i8 %outer_i to i32
  %ab = add i32 %a, %b
  %bi.32 = add i32 %ab, 2
  %bi.s = trunc i32 %bi.32 to i16
  %base_inner_c = sext i16 %bi.s to i32
  %max_in_c.32 = sext i16 %max_in_c to i32
  %bo.a = add i32 %base_inner_c, %max_in_c.32
  %bo.b = add i32 %bo.a, 1
  %bo.s = trunc i32 %bo.b to i16
  %base_outer_c = sext i16 %bo.s to i32
  %ic3 = call i16 @emit_point_run(%struct._mesh_t addrspace(7)* %mesh, i16 %ic2, i16 %max_in_c, i32 %base_inner_c)
  %ic4 = call i16 @emit_point_run(%struct._mesh_t addrspace(7)* %mesh, i16 %ic3, i16 %max_out_c, i32 %base_outer_c)
  br label %done

done:
  %ic = phi i16 [ %ic2, %entry ], [ %ic4, %complement ]
  %ic.32 = sext i16 %ic to i32
  call void @air.set_primitive_count_mesh(%struct._mesh_t addrspace(7)* %mesh, i32 %ic.32) #24
  ret void
}

; ---------------------------------------------------------------------------
; AIR intrinsics (declarations as Metal's front end emits them)

declare <2 x float> @air.convert.f.v2f32.u.v2i16(<2 x i16>) #10
declare <2 x i32> @air.convert.u.v2i32.u.v2i16(<2 x i16>) #10
declare <2 x i16> @air.convert.u.v2i16.u.v2i32(<2 x i32>) #10
declare float @air.fast_ceil.f32(float) #10
declare float @air.fast_clamp.f32(float, float, float) #10
declare i32 @air.convert.u.i32.f.f32(float) #10
declare i32 @air.clz.i32(i32, i1) #10
declare i32 @air.min.u.i32(i32, i32) #10
declare <2 x i32> @air.min.u.v2i32(<2 x i32>, <2 x i32>) #10
declare i32 @air.max.u.i32(i32, i32) #10
declare i8 @air.min.s.i8(i8, i8) #10
declare i8 @air.max.s.i8(i8, i8) #10
declare <2 x i16> @air.min.u.v2i16(<2 x i16>, <2 x i16>) #10
declare i16 @air.min.u.i16(i16, i16) #10
declare half @air.convert.f.f16.s.i16(i16) #10
declare half @air.convert.f.f16.s.i32(i32) #10
declare i16 @air.convert.s.i16.f.f16(half) #10
declare half @air.floor.f16(half) #10
declare half @air.ceil.f16(half) #10
declare i32 @air.atomic.local.add.s.i32(i32 addrspace(3)* nocapture, i32, i32, i32, i1) #11
declare void @air.simdgroup.barrier(i32, i32) #12
declare i1 @air.simd_all(i1) #12
declare void @air.set_index_mesh(%struct._mesh_t addrspace(7)* nocapture, i32, i8) #13
declare void @air.set_primitive_count_mesh(%struct._mesh_t addrspace(7)* nocapture, i32) #13

; Function attributes carry Metal's fast-math settings. Everything that
; reaches a simdgroup barrier or simd_all is convergent.
attributes #0 = { mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nounwind "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #2 = { convergent mustprogress nounwind "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #3 = { argmemonly mustprogress nofree norecurse nosync nounwind readonly willreturn "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #4 = { convergent mustprogress nounwind "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #10 = { mustprogress nofree nosync nounwind readnone willreturn }
attributes #11 = { mustprogress nounwind willreturn }
attributes #12 = { convergent mustprogress nounwind willreturn }
attributes #13 = { argmemonly mustprogress nounwind willreturn }
attributes #20 = { nounwind readnone willreturn }
attributes #21 = { nounwind willreturn }
attributes #22 = { convergent nounwind willreturn }
attributes #23 = { convergent }
attributes #24 = { argmemonly nounwind willreturn }
