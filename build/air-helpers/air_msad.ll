; SPDX-License-Identifier: GPL-3.0-or-later
; A port of DXMT code from before its LGPL relicensing: MIT, DXMT's LICENSE.OLD
; (collected by pp notices as DXMT-LICENSE.OLD.txt).
; air_msad.ll: hand-written LLVM 15 IR (AIR dialect) port of DXMT's
; src/airconv/shaders/air_msad.metal (willfaust/dxmt @ b4b89f0a, identical to
; 3Shain/dxmt v0.74). Assemble with LLVM 15.0.7 llvm-as; airconv_context.cpp
; linkMSAD() links it into converted shaders that use DXBC msad.
;
; msad(ref, src, accum): for each byte lane k in 0..3 of each component,
;   accum += (ref_k != 0) ? |ref_k - src_k| : 0      (all arithmetic mod 2^32)
; Integer-only; no floating point, so no precision question arises.
; absdiff() is the AIR intrinsic Metal emits for it, as in the other helpers.
source_filename = "air_msad.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx14.0.0"

define i32 @dxmt.msad.i32(i32 %ref, i32 %src, i32 %accum) #0 {
entry:
  ; byte lane 0 (bits 0..7)
  %r0 = and i32 %ref, 255
  %s0 = and i32 %src, 255
  %ad0 = call i32 @air.abs_diff.u.i32(i32 %r0, i32 %s0) #1
  %nz0 = icmp ne i32 %r0, 0
  %c0 = select i1 %nz0, i32 %ad0, i32 0
  %acc0 = add i32 %accum, %c0
  ; byte lane 1 (bits 8..15)
  %r1.sh = lshr i32 %ref, 8
  %s1.sh = lshr i32 %src, 8
  %r1 = and i32 %r1.sh, 255
  %s1 = and i32 %s1.sh, 255
  %ad1 = call i32 @air.abs_diff.u.i32(i32 %r1, i32 %s1) #1
  %nz1 = icmp ne i32 %r1, 0
  %c1 = select i1 %nz1, i32 %ad1, i32 0
  %acc1 = add i32 %acc0, %c1
  ; byte lane 2 (bits 16..23)
  %r2.sh = lshr i32 %ref, 16
  %s2.sh = lshr i32 %src, 16
  %r2 = and i32 %r2.sh, 255
  %s2 = and i32 %s2.sh, 255
  %ad2 = call i32 @air.abs_diff.u.i32(i32 %r2, i32 %s2) #1
  %nz2 = icmp ne i32 %r2, 0
  %c2 = select i1 %nz2, i32 %ad2, i32 0
  %acc2 = add i32 %acc1, %c2
  ; byte lane 3 (bits 24..31)
  %r3.sh = lshr i32 %ref, 24
  %s3.sh = lshr i32 %src, 24
  %r3 = and i32 %r3.sh, 255
  %s3 = and i32 %s3.sh, 255
  %ad3 = call i32 @air.abs_diff.u.i32(i32 %r3, i32 %s3) #1
  %nz3 = icmp ne i32 %r3, 0
  %c3 = select i1 %nz3, i32 %ad3, i32 0
  %acc3 = add i32 %acc2, %c3
  ret i32 %acc3
}

define <2 x i32> @dxmt.msad.v2i32(<2 x i32> %ref, <2 x i32> %src, <2 x i32> %accum) #0 {
entry:
  ; byte lane 0 (bits 0..7)
  %r0 = and <2 x i32> %ref, <i32 255, i32 255>
  %s0 = and <2 x i32> %src, <i32 255, i32 255>
  %ad0 = call <2 x i32> @air.abs_diff.u.v2i32(<2 x i32> %r0, <2 x i32> %s0) #1
  %nz0 = icmp ne <2 x i32> %r0, zeroinitializer
  %c0 = select <2 x i1> %nz0, <2 x i32> %ad0, <2 x i32> zeroinitializer
  %acc0 = add <2 x i32> %accum, %c0
  ; byte lane 1 (bits 8..15)
  %r1.sh = lshr <2 x i32> %ref, <i32 8, i32 8>
  %s1.sh = lshr <2 x i32> %src, <i32 8, i32 8>
  %r1 = and <2 x i32> %r1.sh, <i32 255, i32 255>
  %s1 = and <2 x i32> %s1.sh, <i32 255, i32 255>
  %ad1 = call <2 x i32> @air.abs_diff.u.v2i32(<2 x i32> %r1, <2 x i32> %s1) #1
  %nz1 = icmp ne <2 x i32> %r1, zeroinitializer
  %c1 = select <2 x i1> %nz1, <2 x i32> %ad1, <2 x i32> zeroinitializer
  %acc1 = add <2 x i32> %acc0, %c1
  ; byte lane 2 (bits 16..23)
  %r2.sh = lshr <2 x i32> %ref, <i32 16, i32 16>
  %s2.sh = lshr <2 x i32> %src, <i32 16, i32 16>
  %r2 = and <2 x i32> %r2.sh, <i32 255, i32 255>
  %s2 = and <2 x i32> %s2.sh, <i32 255, i32 255>
  %ad2 = call <2 x i32> @air.abs_diff.u.v2i32(<2 x i32> %r2, <2 x i32> %s2) #1
  %nz2 = icmp ne <2 x i32> %r2, zeroinitializer
  %c2 = select <2 x i1> %nz2, <2 x i32> %ad2, <2 x i32> zeroinitializer
  %acc2 = add <2 x i32> %acc1, %c2
  ; byte lane 3 (bits 24..31)
  %r3.sh = lshr <2 x i32> %ref, <i32 24, i32 24>
  %s3.sh = lshr <2 x i32> %src, <i32 24, i32 24>
  %r3 = and <2 x i32> %r3.sh, <i32 255, i32 255>
  %s3 = and <2 x i32> %s3.sh, <i32 255, i32 255>
  %ad3 = call <2 x i32> @air.abs_diff.u.v2i32(<2 x i32> %r3, <2 x i32> %s3) #1
  %nz3 = icmp ne <2 x i32> %r3, zeroinitializer
  %c3 = select <2 x i1> %nz3, <2 x i32> %ad3, <2 x i32> zeroinitializer
  %acc3 = add <2 x i32> %acc2, %c3
  ret <2 x i32> %acc3
}

define <3 x i32> @dxmt.msad.v3i32(<3 x i32> %ref, <3 x i32> %src, <3 x i32> %accum) #0 {
entry:
  ; byte lane 0 (bits 0..7)
  %r0 = and <3 x i32> %ref, <i32 255, i32 255, i32 255>
  %s0 = and <3 x i32> %src, <i32 255, i32 255, i32 255>
  %ad0 = call <3 x i32> @air.abs_diff.u.v3i32(<3 x i32> %r0, <3 x i32> %s0) #1
  %nz0 = icmp ne <3 x i32> %r0, zeroinitializer
  %c0 = select <3 x i1> %nz0, <3 x i32> %ad0, <3 x i32> zeroinitializer
  %acc0 = add <3 x i32> %accum, %c0
  ; byte lane 1 (bits 8..15)
  %r1.sh = lshr <3 x i32> %ref, <i32 8, i32 8, i32 8>
  %s1.sh = lshr <3 x i32> %src, <i32 8, i32 8, i32 8>
  %r1 = and <3 x i32> %r1.sh, <i32 255, i32 255, i32 255>
  %s1 = and <3 x i32> %s1.sh, <i32 255, i32 255, i32 255>
  %ad1 = call <3 x i32> @air.abs_diff.u.v3i32(<3 x i32> %r1, <3 x i32> %s1) #1
  %nz1 = icmp ne <3 x i32> %r1, zeroinitializer
  %c1 = select <3 x i1> %nz1, <3 x i32> %ad1, <3 x i32> zeroinitializer
  %acc1 = add <3 x i32> %acc0, %c1
  ; byte lane 2 (bits 16..23)
  %r2.sh = lshr <3 x i32> %ref, <i32 16, i32 16, i32 16>
  %s2.sh = lshr <3 x i32> %src, <i32 16, i32 16, i32 16>
  %r2 = and <3 x i32> %r2.sh, <i32 255, i32 255, i32 255>
  %s2 = and <3 x i32> %s2.sh, <i32 255, i32 255, i32 255>
  %ad2 = call <3 x i32> @air.abs_diff.u.v3i32(<3 x i32> %r2, <3 x i32> %s2) #1
  %nz2 = icmp ne <3 x i32> %r2, zeroinitializer
  %c2 = select <3 x i1> %nz2, <3 x i32> %ad2, <3 x i32> zeroinitializer
  %acc2 = add <3 x i32> %acc1, %c2
  ; byte lane 3 (bits 24..31)
  %r3.sh = lshr <3 x i32> %ref, <i32 24, i32 24, i32 24>
  %s3.sh = lshr <3 x i32> %src, <i32 24, i32 24, i32 24>
  %r3 = and <3 x i32> %r3.sh, <i32 255, i32 255, i32 255>
  %s3 = and <3 x i32> %s3.sh, <i32 255, i32 255, i32 255>
  %ad3 = call <3 x i32> @air.abs_diff.u.v3i32(<3 x i32> %r3, <3 x i32> %s3) #1
  %nz3 = icmp ne <3 x i32> %r3, zeroinitializer
  %c3 = select <3 x i1> %nz3, <3 x i32> %ad3, <3 x i32> zeroinitializer
  %acc3 = add <3 x i32> %acc2, %c3
  ret <3 x i32> %acc3
}

define <4 x i32> @dxmt.msad.v4i32(<4 x i32> %ref, <4 x i32> %src, <4 x i32> %accum) #0 {
entry:
  ; byte lane 0 (bits 0..7)
  %r0 = and <4 x i32> %ref, <i32 255, i32 255, i32 255, i32 255>
  %s0 = and <4 x i32> %src, <i32 255, i32 255, i32 255, i32 255>
  %ad0 = call <4 x i32> @air.abs_diff.u.v4i32(<4 x i32> %r0, <4 x i32> %s0) #1
  %nz0 = icmp ne <4 x i32> %r0, zeroinitializer
  %c0 = select <4 x i1> %nz0, <4 x i32> %ad0, <4 x i32> zeroinitializer
  %acc0 = add <4 x i32> %accum, %c0
  ; byte lane 1 (bits 8..15)
  %r1.sh = lshr <4 x i32> %ref, <i32 8, i32 8, i32 8, i32 8>
  %s1.sh = lshr <4 x i32> %src, <i32 8, i32 8, i32 8, i32 8>
  %r1 = and <4 x i32> %r1.sh, <i32 255, i32 255, i32 255, i32 255>
  %s1 = and <4 x i32> %s1.sh, <i32 255, i32 255, i32 255, i32 255>
  %ad1 = call <4 x i32> @air.abs_diff.u.v4i32(<4 x i32> %r1, <4 x i32> %s1) #1
  %nz1 = icmp ne <4 x i32> %r1, zeroinitializer
  %c1 = select <4 x i1> %nz1, <4 x i32> %ad1, <4 x i32> zeroinitializer
  %acc1 = add <4 x i32> %acc0, %c1
  ; byte lane 2 (bits 16..23)
  %r2.sh = lshr <4 x i32> %ref, <i32 16, i32 16, i32 16, i32 16>
  %s2.sh = lshr <4 x i32> %src, <i32 16, i32 16, i32 16, i32 16>
  %r2 = and <4 x i32> %r2.sh, <i32 255, i32 255, i32 255, i32 255>
  %s2 = and <4 x i32> %s2.sh, <i32 255, i32 255, i32 255, i32 255>
  %ad2 = call <4 x i32> @air.abs_diff.u.v4i32(<4 x i32> %r2, <4 x i32> %s2) #1
  %nz2 = icmp ne <4 x i32> %r2, zeroinitializer
  %c2 = select <4 x i1> %nz2, <4 x i32> %ad2, <4 x i32> zeroinitializer
  %acc2 = add <4 x i32> %acc1, %c2
  ; byte lane 3 (bits 24..31)
  %r3.sh = lshr <4 x i32> %ref, <i32 24, i32 24, i32 24, i32 24>
  %s3.sh = lshr <4 x i32> %src, <i32 24, i32 24, i32 24, i32 24>
  %r3 = and <4 x i32> %r3.sh, <i32 255, i32 255, i32 255, i32 255>
  %s3 = and <4 x i32> %s3.sh, <i32 255, i32 255, i32 255, i32 255>
  %ad3 = call <4 x i32> @air.abs_diff.u.v4i32(<4 x i32> %r3, <4 x i32> %s3) #1
  %nz3 = icmp ne <4 x i32> %r3, zeroinitializer
  %c3 = select <4 x i1> %nz3, <4 x i32> %ad3, <4 x i32> zeroinitializer
  %acc3 = add <4 x i32> %acc2, %c3
  ret <4 x i32> %acc3
}

declare i32 @air.abs_diff.u.i32(i32, i32) #2
declare <2 x i32> @air.abs_diff.u.v2i32(<2 x i32>, <2 x i32>) #2
declare <3 x i32> @air.abs_diff.u.v3i32(<3 x i32>, <3 x i32>) #2
declare <4 x i32> @air.abs_diff.u.v4i32(<4 x i32>, <4 x i32>) #2

attributes #0 = { mustprogress nofree norecurse nosync nounwind readnone willreturn "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #1 = { nounwind readnone willreturn }
attributes #2 = { mustprogress nofree nosync nounwind readnone willreturn }
