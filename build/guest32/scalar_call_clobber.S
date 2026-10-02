// SPDX-License-Identifier: GPL-3.0-or-later
// Adversarial ordinary AAPCS64 callee. Real helper executes first; no simulated
// values/accesses. Clobber ALL permitted live FEX registers, including the high
// half of v8-v15, to avoid a compiler-specific preservation false positive.
.text
.global audit_clobber
.type audit_clobber, %function
audit_clobber:
  stp x29, x30, [sp, #-16]!
  bl g32_scalar_access
  .irp reg, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18
    mov x\reg, #0xdead
  .endr
  .irp reg, 0,1,2,3,4,5,6,7,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    movi v\reg\().16b, #0xa5
  .endr
  .irp reg, 8,9,10,11,12,13,14,15
    ins v\reg\().d[1], x1
  .endr
  cmp x1, x1
  ldp x29, x30, [sp], #16
  ret
.size audit_clobber, .-audit_clobber
