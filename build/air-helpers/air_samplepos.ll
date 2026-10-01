; SPDX-License-Identifier: GPL-3.0-or-later
; A port of DXMT code from before its LGPL relicensing: MIT, DXMT's LICENSE.OLD
; (collected by pp notices as DXMT-LICENSE.OLD.txt).
; air_samplepos.ll: hand-written LLVM 15 IR (AIR dialect) port of DXMT's
; src/airconv/shaders/air_samplepos.metal (willfaust/dxmt @ b4b89f0a, identical
; to 3Shain/dxmt v0.74). Assemble with LLVM 15.0.7 llvm-as; airconv_context.cpp
; linkSamplePos() links it into converted shaders that use DXBC samplepos.
;
; sample_pos(sample_count, index) returns the D3D11.3 standard sample position
; (spec 19.2.4) for 2, 4 and 8 samples, in units of 1/16 pixel, and (0, 0) for
; every other sample count. index is masked to the table size.
; Each table byte packs (y & 0xf) << 4 | (x & 0xf); both nibbles are signed.
source_filename = "air_samplepos.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx14.0.0"

; (4,4) (-4,-4)
@sample_pos_2 = internal unnamed_addr addrspace(2) constant [2 x i8] [i8 u0x44, i8 u0xCC], align 1
; (-2,-6) (6,-2) (-6,2) (2,6)
@sample_pos_4 = internal unnamed_addr addrspace(2) constant [4 x i8] [i8 u0xAE, i8 u0xE6, i8 u0x2A, i8 u0x62], align 1
; (1,-3) (-1,3) (5,1) (-3,-5) (-5,5) (-7,-1) (3,7) (7,-7)
@sample_pos_8 = internal unnamed_addr addrspace(2) constant [8 x i8] [i8 u0xD1, i8 u0x3F, i8 u0x15, i8 u0xBD, i8 u0x5B, i8 u0xF9, i8 u0x73, i8 u0x97], align 1

define <2 x float> @dxmt.sample_pos.i32(i32 %sample_count, i32 %index) #0 {
entry:
  switch i32 %sample_count, label %decode [
    i32 2, label %count2
    i32 4, label %count4
    i32 8, label %count8
  ]

count2:
  %i2 = and i32 %index, 1
  %i2.64 = zext i32 %i2 to i64
  %p2.ptr = getelementptr inbounds [2 x i8], [2 x i8] addrspace(2)* @sample_pos_2, i64 0, i64 %i2.64
  %p2 = load i8, i8 addrspace(2)* %p2.ptr, align 1
  br label %decode

count4:
  %i4 = and i32 %index, 3
  %i4.64 = zext i32 %i4 to i64
  %p4.ptr = getelementptr inbounds [4 x i8], [4 x i8] addrspace(2)* @sample_pos_4, i64 0, i64 %i4.64
  %p4 = load i8, i8 addrspace(2)* %p4.ptr, align 1
  br label %decode

count8:
  %i8 = and i32 %index, 7
  %i8.64 = zext i32 %i8 to i64
  %p8.ptr = getelementptr inbounds [8 x i8], [8 x i8] addrspace(2)* @sample_pos_8, i64 0, i64 %i8.64
  %p8 = load i8, i8 addrspace(2)* %p8.ptr, align 1
  br label %decode

decode:
  %packed = phi i8 [ 0, %entry ], [ %p2, %count2 ], [ %p4, %count4 ], [ %p8, %count8 ]
  ; x = low nibble sign-extended: (char)((char)(p & 0xf) << 4) >> 4
  %x.hi = shl i8 %packed, 4
  %x.8 = ashr i8 %x.hi, 4
  %x = sext i8 %x.8 to i32
  ; y = high nibble sign-extended: ((char)(p & 0xf0)) >> 4
  %y.8 = ashr i8 %packed, 4
  %y = sext i8 %y.8 to i32
  ; x / 16.0 and y / 16.0. Both are exact for |x|, |y| <= 8; Metal's front end
  ; emits the conversion intrinsic and a multiply by 1/16, so this does too.
  %x.f = call fast float @air.convert.f.f32.s.i32(i32 %x) #2
  %x.s = fmul fast float %x.f, 6.250000e-02
  %y.f = call fast float @air.convert.f.f32.s.i32(i32 %y) #2
  %y.s = fmul fast float %y.f, 6.250000e-02
  %v0 = insertelement <2 x float> undef, float %x.s, i64 0
  %v1 = insertelement <2 x float> %v0, float %y.s, i64 1
  ret <2 x float> %v1
}

declare float @air.convert.f.f32.s.i32(i32) #1

attributes #0 = { mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "unsafe-fp-math"="true" }
attributes #1 = { mustprogress nofree nosync nounwind readnone willreturn }
attributes #2 = { nounwind readnone willreturn }
